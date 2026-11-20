package org.yipao.app.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.CancellationSignal
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.amap.api.location.AMapLocationClient
import com.amap.api.location.AMapLocationClientOption
import com.amap.api.maps.CoordinateConverter as AMapCoordinateConverter
import com.amap.api.maps.AMapUtils
import com.amap.api.maps.model.LatLng
import com.amap.api.services.core.LatLonPoint
import com.amap.api.services.route.RouteSearchV2
import org.yipao.app.core.AppEnv
import org.yipao.app.core.Coordinate
import org.yipao.app.core.DiagLog
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume
import kotlin.math.roundToInt

/// 手机自己在哪，以及从这儿开车到车辆有多远。
///
/// 只服务车辆位置页那两格距离。**不做持续定位**：进页面要一次，页面关了就没了；
/// 也没有后台定位权限。
///
/// 坐标系：高德定位给的是 **GCJ-02**，车端上报的也是 GCJ-02，两边同一套，直接算，
/// 这条链路上没有任何需要转换的落点。混着算的话人站在车边上也会显示几百米。
///
/// iOS 端曾经在这儿转过一次 WGS-84（2026-08-18），依据是「MapKit 只认 WGS-84」——
/// 那个依据是错的，大陆的苹果地图和系统定位用的同样是 GCJ-02，转完所有用户的位置
/// 都偏了，第二天就回滚了。三端在这件事上口径一致：**原样传，谁都不转**。
object UserLocation {

    /// SDK 的网络请求先等 8 秒，协程再多留 4 秒给冷启动和回调调度。
    /// 两层如果设成同一个值，外层容易在 SDK 刚准备回调时先把定位取消。
    private const val LOCATION_HTTP_TIMEOUT_MS = 8_000L
    private const val LOCATION_TIMEOUT_MS = 12_000L
    private const val SYSTEM_LOCATION_TIMEOUT_MS = 10_000L
    private const val LAST_KNOWN_MAX_AGE_MS = 5 * 60_000L
    private const val ROUTE_TIMEOUT_MS = 12_000L

    fun isPermitted(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED

    /// 单次定位。没权限、超时、高德回错误码，一律返回 null。
    suspend fun current(): Coordinate? {
        if (!isPermitted(AppEnv.context)) return null
        withTimeoutOrNull(LOCATION_TIMEOUT_MS) { locateOnce() }?.let { return it }
        DiagLog.note("[locate] 高德定位未返回，尝试系统定位")
        val found = systemCurrent()
        if (found == null) DiagLog.note("[locate] 高德与系统定位均不可用")
        return found
    }

    private suspend fun locateOnce(): Coordinate? = suspendCancellableCoroutine { continuation ->
        var client: AMapLocationClient? = null
        try {
            client = AMapLocationClient(AppEnv.context)
            // 单次 + 取最近一次缓存里最好的那条：省电，也不用等 GPS 冷启动。
            // 只给了「大致位置」时 Hight_Accuracy 会自动退到网络定位，不会失败。
            client.setLocationOption(
                AMapLocationClientOption().apply {
                    locationMode = AMapLocationClientOption.AMapLocationMode.Hight_Accuracy
                    isOnceLocation = true
                    isOnceLocationLatest = true
                    isNeedAddress = false
                    httpTimeOut = LOCATION_HTTP_TIMEOUT_MS
                }
            )
            val finished = client
            client.setLocationListener { location ->
                if (!continuation.isActive) return@setLocationListener
                val code = location?.errorCode ?: -1
                if (code != 0) {
                    DiagLog.note("[locate] 定位失败 code=$code ${location?.errorInfo.orEmpty()}")
                    continuation.resume(null)
                } else {
                    continuation.resume(Coordinate(location.latitude, location.longitude))
                }
                // 单次定位回调完客户端就没用了，不销毁会一直占着服务。
                runCatching { finished.onDestroy() }
            }
            client.startLocation()
        } catch (e: Throwable) {
            DiagLog.note("[locate] 定位异常：${e.message}")
            if (continuation.isActive) continuation.resume(null)
        }
        // 超时被 withTimeoutOrNull 掐掉时回调不会来，这条路上也得销毁。
        val pending = client
        continuation.invokeOnCancellation { runCatching { pending?.onDestroy() } }
    }

    /// ColorOS 16 上高德定位服务可能报 `0402` 网络超时，但系统 network provider 已有
    /// 可用位置。这里作为第二条路并发询问 fused/network/GPS，谁先给有效结果就用谁。
    private suspend fun systemCurrent(): Coordinate? {
        val manager = AppEnv.context.getSystemService(LocationManager::class.java) ?: return null
        val enabled = runCatching { manager.getProviders(true) }.getOrDefault(emptyList())
        val providers = listOf(
            LocationManager.FUSED_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.GPS_PROVIDER,
        ).filter { it in enabled }
        if (providers.isEmpty()) return null

        // 先用五分钟内的系统缓存，通常能在高德超时后立刻出结果；更旧的位置会误导距离。
        val recent = providers
            .mapNotNull { provider -> runCatching { manager.getLastKnownLocation(provider) }.getOrNull() }
            .filter { location ->
                val ageMs = (SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos)
                    .coerceAtLeast(0L) / 1_000_000L
                ageMs <= LAST_KNOWN_MAX_AGE_MS && (!location.hasAccuracy() || location.accuracy <= 2_000f)
            }
            .maxByOrNull { it.elapsedRealtimeNanos }
        if (recent != null) {
            DiagLog.note("[locate] 使用系统近期位置 provider=${recent.provider}")
            return systemCoordinate(recent)
        }

        val current = withTimeoutOrNull(SYSTEM_LOCATION_TIMEOUT_MS) {
            requestSystemLocation(manager, providers)
        } ?: return null
        DiagLog.note("[locate] 系统定位成功 provider=${current.provider}")
        return systemCoordinate(current)
    }

    private suspend fun requestSystemLocation(
        manager: LocationManager,
        providers: List<String>,
    ): Location? = suspendCancellableCoroutine { continuation ->
        val pending = AtomicInteger(providers.size)
        val completed = AtomicBoolean(false)
        val signals = providers.map { CancellationSignal() }

        fun finish(location: Location?) {
            if (!continuation.isActive) return
            if (location != null) {
                if (!completed.compareAndSet(false, true)) return
                signals.forEach { it.cancel() }
                continuation.resume(location)
            } else if (pending.decrementAndGet() == 0) {
                if (!completed.compareAndSet(false, true)) return
                continuation.resume(null)
            }
        }

        providers.forEachIndexed { index, provider ->
            try {
                manager.getCurrentLocation(
                    provider,
                    signals[index],
                    AppEnv.context.mainExecutor,
                ) { finish(it) }
            } catch (e: Exception) {
                DiagLog.note("[locate] 系统 provider=$provider 异常：${e.message}")
                finish(null)
            }
        }
        continuation.invokeOnCancellation {
            completed.set(true)
            signals.forEach { it.cancel() }
        }
    }

    /// Android LocationManager 按 WGS-84 定义坐标；车端和高德地图用 GCJ-02。
    /// 只在高德覆盖区域转换，海外位置保持原样。
    private fun systemCoordinate(location: Location): Coordinate {
        val raw = LatLng(location.latitude, location.longitude)
        if (!AMapCoordinateConverter.isAMapDataAvailable(raw.latitude, raw.longitude)) {
            return Coordinate(raw.latitude, raw.longitude)
        }
        val converted = runCatching {
            AMapCoordinateConverter(AppEnv.context)
                .from(AMapCoordinateConverter.CoordType.GPS)
                .coord(raw)
                .convert()
        }.getOrNull()
        return Coordinate(
            converted?.latitude ?: raw.latitude,
            converted?.longitude ?: raw.longitude,
        )
    }

    /// 直线距离，米。
    fun straightDistance(from: Coordinate, to: Coordinate): Float =
        AMapUtils.calculateLineDistance(
            LatLng(from.latitude, from.longitude),
            LatLng(to.latitude, to.longitude),
        )

    /// 驾车路线：距离（米）+ 预计耗时（秒）。算不出返回 null，界面据此说「暂不可用」。
    suspend fun drivingRoute(from: Coordinate, to: Coordinate): DrivingRoute? {
        val found = withTimeoutOrNull(ROUTE_TIMEOUT_MS) { drivingRouteOnce(from, to) }
        if (found == null) DiagLog.note("[route] 未获得驾车路线或等待超时")
        return found
    }

    private suspend fun drivingRouteOnce(from: Coordinate, to: Coordinate): DrivingRoute? =
        suspendCancellableCoroutine { continuation ->
            try {
                val search = RouteSearchV2(AppEnv.context)
                search.setRouteSearchListener(object : RouteSearchV2.OnRouteSearchListener {
                    override fun onDriveRouteSearched(
                        result: com.amap.api.services.route.DriveRouteResultV2?,
                        code: Int,
                    ) {
                        if (!continuation.isActive) return
                        if (code != 1000) {
                            DiagLog.note("[route] 驾车路线失败 code=$code")
                            continuation.resume(null)
                            return
                        }
                        // 多条方案取最短的那条，同 iOS 的 `routes.min(by: distance)`。
                        val path = result?.paths?.minByOrNull { it.distance }
                        if (path == null) {
                            continuation.resume(null)
                            return
                        }
                        // V2 把耗时挪进了 cost，得显式要 COST 字段才有；
                        // 万一没给就退回 path 自己那份，两个都是 0 就当没耗时。
                        val seconds = path.cost?.duration?.takeIf { it > 0f }?.roundToInt()
                            ?: path.duration.toInt().takeIf { it > 0 }
                        continuation.resume(DrivingRoute(path.distance, seconds))
                    }

                    /// 剩下三种出行方式这里用不到，接口要求实现。
                    override fun onBusRouteSearched(
                        result: com.amap.api.services.route.BusRouteResultV2?,
                        code: Int,
                    ) = Unit

                    override fun onWalkRouteSearched(
                        result: com.amap.api.services.route.WalkRouteResultV2?,
                        code: Int,
                    ) = Unit

                    override fun onRideRouteSearched(
                        result: com.amap.api.services.route.RideRouteResultV2?,
                        code: Int,
                    ) = Unit
                })
                val query = RouteSearchV2.DriveRouteQuery(
                    RouteSearchV2.FromAndTo(
                        LatLonPoint(from.latitude, from.longitude),
                        LatLonPoint(to.latitude, to.longitude),
                    ),
                    RouteSearchV2.DrivingStrategy.DEFAULT,
                    null,
                    null,
                    "",
                ).apply { showFields = RouteSearchV2.ShowFields.COST }
                search.calculateDriveRouteAsyn(query)
            } catch (e: Throwable) {
                DiagLog.note("[route] 驾车路线异常：${e.message}")
                if (continuation.isActive) continuation.resume(null)
            }
        }
}

/// [distanceMeters] 米，[durationSeconds] 秒（高德没给就是 null）。
data class DrivingRoute(val distanceMeters: Float, val durationSeconds: Int?)
