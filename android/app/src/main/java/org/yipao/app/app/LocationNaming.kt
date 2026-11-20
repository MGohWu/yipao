package org.yipao.app.app

import com.amap.api.services.core.LatLonPoint
import com.amap.api.services.core.PoiItem
import com.amap.api.services.geocoder.AoiItem
import com.amap.api.services.geocoder.GeocodeSearch
import com.amap.api.services.geocoder.RegeocodeAddress
import com.amap.api.services.geocoder.RegeocodeQuery
import com.amap.api.services.geocoder.RegeocodeResult
import com.amap.api.services.geocoder.RegeocodeRoad
import com.amap.api.services.geocoder.GeocodeResult
import org.yipao.app.core.AppEnv
import org.yipao.app.core.Coordinate
import org.yipao.app.core.DiagLog
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.math.abs

/// 把车辆坐标换成「月亮岛小区」「桃花坞路」这类地名。
///
/// 走高德的逆地理编码，**不申请任何定位权限**：这里解析的是车报上来的坐标，
/// 和手机自己在哪没有关系。
///
/// 车端坐标本来就是 GCJ-02，高德收的也是 GCJ-02，所以一律原样传，不做任何转换
/// （iOS 那边转是因为 MapKit 只认 WGS-84）。
///
/// 解不出来时返回 null，界面按「读不到就隐藏」处理，绝不回退成经纬度数字。
object LocationNaming {

    /// 上一次解析成功的坐标和结果。十秒一次的轮询里车没动就不重复打接口。
    private var cachedCoordinate: Coordinate? = null
    private var cachedName: String? = null

    /// 大约 11 米。小于这个位移当作没动——车停着时坐标末位本来就会跳。
    private const val SAME_PLACE_DEGREES = 0.0001

    /// 门牌离得再远也会被返回，超过这个距离就不能拿来说「车在这」。
    private const val STREET_NUMBER_LIMIT = 50f

    /// 地名超过这个字数就开始剥行政区划前缀。首页那行和卡片上都只有一行的位置。
    private const val NAME_LIMIT = 12

    suspend fun name(coordinate: Coordinate): String? {
        cachedName?.let { cached ->
            val previous = cachedCoordinate
            if (previous != null && isSamePlace(previous, coordinate)) return cached
        }
        val resolved = reverseGeocode(coordinate) ?: return cachedName
        cachedCoordinate = coordinate
        cachedName = resolved
        return resolved
    }

    fun clear() {
        cachedCoordinate = null
        cachedName = null
    }

    private fun isSamePlace(lhs: Coordinate, rhs: Coordinate): Boolean =
        abs(lhs.latitude - rhs.latitude) < SAME_PLACE_DEGREES &&
            abs(lhs.longitude - rhs.longitude) < SAME_PLACE_DEGREES

    private suspend fun reverseGeocode(coordinate: Coordinate): String? =
        suspendCancellableCoroutine { continuation ->
            try {
                val search = GeocodeSearch(AppEnv.context)
                search.setOnGeocodeSearchListener(object : GeocodeSearch.OnGeocodeSearchListener {
                    override fun onRegeocodeSearched(result: RegeocodeResult?, code: Int) {
                        if (!continuation.isActive) return
                        if (code != 1000) {
                            DiagLog.note("[geocode] 逆地理编码失败 code=$code")
                            continuation.resume(null)
                            return
                        }
                        continuation.resume(shortName(result))
                    }

                    /// 正向编码这里用不到，接口要求实现。
                    override fun onGeocodeSearched(result: GeocodeResult?, code: Int) = Unit
                })
                // 200 米半径、`autonavi` 坐标系——车端给的就是 GCJ-02。
                val query = RegeocodeQuery(
                    LatLonPoint(coordinate.latitude, coordinate.longitude),
                    200f,
                    GeocodeSearch.AMAP,
                )
                // 不开 `all` 就只有行政区划和一条格式化全地址，POI / AOI / 道路 / 门牌
                // 全是空列表。[shortName] 那几档挑选逻辑因此一直是空转，每次都退到最后
                // 那条兜底的整串地址上——「芜湖市弋江区龙湖街道王奎内科诊所昌建融创枫丹壹号」
                // 就是这么来的。
                query.extensions = "all"
                search.getFromLocationAsyn(query)
            } catch (e: Throwable) {
                DiagLog.note("[geocode] 逆地理编码异常：${e.message}")
                if (continuation.isActive) continuation.resume(null)
            }
        }

    /// 挑一个最像「车停在哪」的名字，口径和鸿蒙 `LocationNaming.nameOf` 逐档对齐。
    ///
    /// 小区/园区（AOI）排最前：车停在院子里时，「昌建融创枫丹壹号」比任何路名都说明问题。
    /// AOI 取**面积最小**的那个——同一个点会同时命中大景区、大学校园和其中的小区，
    /// 服务按距离排序，范围大的反而排前面，只有面积能分出谁更具体。
    private fun shortName(result: RegeocodeResult?): String? {
        val address = result?.regeocodeAddress ?: return null

        smallestAoi(address.aois)?.let { return capped(it, address) }

        // 门牌比裸路名精确，但离得再远也会被返回，所以要卡距离。
        address.streetNumber?.takeIf { it.distance <= STREET_NUMBER_LIMIT }?.let { street ->
            street.street?.takeIf { it.isNotEmpty() }?.let { name ->
                val number = street.number?.takeIf { it.isNotEmpty() }
                return capped(if (number == null) name else "$name$number", address)
            }
        }

        nearestRoad(address.roads)?.let { return capped(it, address) }
        nearestPoi(address.pois)?.let { return capped(it, address) }

        // 一档都没命中：区 + 街道就是这时候能说的最具体的话。
        val fallback = (address.district.orEmpty() + address.township.orEmpty()).takeIf { it.isNotEmpty() }
        if (fallback != null) return fallback

        val formatted = address.formatAddress.orEmpty()
        if (formatted.isEmpty()) return null
        return capped(formatted, address)
    }

    /// 名字超过 [NAME_LIMIT] 个字时，从头上一层层剥掉行政区划（省、市、区、街道）。
    ///
    /// 只剥前缀、不硬截断：截断会把「枫丹壹号」切成「枫丹壹」，读起来像另一个地方；
    /// 剥掉的省市区则本来就是这台车的主人最不需要被告知的部分。剥完还是长，那就让它长——
    /// 说不完整的地名不如说完。
    private fun capped(name: String, address: RegeocodeAddress): String {
        if (name.length <= NAME_LIMIT) return name
        var trimmed = name
        for (part in listOf(address.province, address.city, address.district, address.township)) {
            if (part.isNullOrEmpty()) continue
            if (!trimmed.startsWith(part)) continue
            if (trimmed.length <= part.length) continue
            trimmed = trimmed.removePrefix(part)
            if (trimmed.length <= NAME_LIMIT) break
        }
        return trimmed
    }

    private fun smallestAoi(aois: List<AoiItem>?): String? {
        var best: String? = null
        var bestArea = Float.MAX_VALUE
        aois?.forEach { aoi ->
            val name = aoi.aoiName?.takeIf { it.isNotEmpty() } ?: return@forEach
            // 没给面积的排在所有给了面积的后面，但仍好过一个都不选。
            val area = aoi.aoiArea ?: Float.MAX_VALUE
            if (best == null || area < bestArea) {
                best = name
                bestArea = area
            }
        }
        return best
    }

    private fun nearestRoad(roads: List<RegeocodeRoad>?): String? =
        roads?.filter { !it.name.isNullOrEmpty() }?.minByOrNull { it.distance }?.name

    private fun nearestPoi(pois: List<PoiItem>?): String? =
        pois?.filter { !it.title.isNullOrEmpty() }?.minByOrNull { it.distance }?.title
}
