package org.yipao.app.ui.components

import android.content.Context
import android.view.MotionEvent
import android.widget.FrameLayout
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.amap.api.location.AMapLocation
import com.amap.api.maps.AMap
import com.amap.api.maps.CameraUpdateFactory
import com.amap.api.maps.LocationSource
import com.amap.api.maps.TextureMapView
import com.amap.api.maps.model.CameraPosition
import com.amap.api.maps.model.LatLng
import com.amap.api.maps.model.MyLocationStyle
import org.yipao.app.core.Coordinate
import org.yipao.app.ui.theme.LeapColors

/// 高德地图。车辆标记不画在地图上，由调用方在正中央叠一个 Compose 图标——
/// 地图始终以车辆坐标居中，效果一样，还省掉一套 Marker/BitmapDescriptor 的生命周期。
///
/// interactive=false 给首页那张 120dp 的位置卡用：整张卡本身要能点进详情页，
/// 地图不能把手势吃掉。
///
/// centerOffsetY 是「车辆该落在视图中心上方多少」：详情页底部压着一张信息卡，
/// 标记按 iOS 的做法上移了一截，地图的对焦点得跟着上移，否则中心点和标记对不上。
///
/// [onVehicleAnchor] 是给详情页用的：镜头能被挪到别处（「回到我的位置」），车就不再
/// 一直待在正中央了，所以每次镜头动都把车辆坐标投影成屏幕像素报回去，让上层那个
/// Compose 图标跟着走。不接这个回调（首页那张卡）就还是老样子——镜头永远对着车，
/// 中间叠个图标就够。
///
/// [userLocation] 给蓝点。这里不自己定位，位置由上层取好了喂进来（见 `UserLocation`），
/// 所以走 `LocationSource` 手动喂而不是打开高德的定位链路，避免多起一路定位。
@Composable
fun AMapView(
    latitude: Double,
    longitude: Double,
    modifier: Modifier = Modifier,
    zoom: Float = 16f,
    interactive: Boolean = true,
    centerOffsetY: Dp = 0.dp,
    userLocation: Coordinate? = null,
    focus: FocusRequest? = null,
    onVehicleAnchor: ((Offset) -> Unit)? = null,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val dark = LeapColors.isDark
    val density = LocalDensity.current
    var viewSize by remember { mutableStateOf(IntSize.Zero) }
    // 上层每次重组都会新建这个 lambda，直接当 effect 的 key 会把监听反复拆了重挂。
    val anchorCallback by rememberUpdatedState(onVehicleAnchor)

    // 用 TextureMapView 而不是 MapView：MapView 是 SurfaceView，独立于视图层级合成，
    // 圆角裁不到它、haze/backdrop 也取样不到，塞进玻璃卡里会露出一块直角硬边。
    val mapView = remember { TextureMapView(context).apply { onCreate(null) } }
    // 地图外面套一层壳，专门用来在 interactive=false 时把触摸拦下来，见 [MapTouchGate]。
    val gate = remember {
        MapTouchGate(context).apply {
            addView(
                mapView,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                ),
            )
        }
    }

    DisposableEffect(lifecycleOwner, mapView) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> mapView.onResume()
                Lifecycle.Event.ON_PAUSE -> mapView.onPause()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            mapView.onDestroy()
        }
    }

    // 对焦点要在尺寸出来之后设，而且必须先于 moveCamera——它改的是「哪个屏幕点算中心」，
    // 设晚了镜头就是照着旧中心挪的。
    LaunchedEffect(mapView, viewSize, centerOffsetY) {
        if (viewSize == IntSize.Zero) return@LaunchedEffect
        val offsetPx = with(density) { centerOffsetY.roundToPx() }
        mapView.map.setPointToCenter(viewSize.width / 2, viewSize.height / 2 - offsetPx)
        mapView.map.moveCamera(CameraUpdateFactory.newLatLngZoom(LatLng(latitude, longitude), zoom))
    }

    // 镜头只在坐标/缩放真变了的时候动。放进 update 块会每次重组都拉回中心，
    // 详情页上用户刚拖开的视野就被弹回去了。
    LaunchedEffect(mapView, latitude, longitude, zoom) {
        mapView.map.moveCamera(CameraUpdateFactory.newLatLngZoom(LatLng(latitude, longitude), zoom))
    }

    // 「回到车辆 / 回到我的位置」。带序号是为了同一个目标点按第二次也能再飞一次——
    // 只比坐标的话，人拖开地图后再按同一个钮就没反应了。
    LaunchedEffect(mapView, focus?.seq) {
        val target = focus ?: return@LaunchedEffect
        mapView.map.animateCamera(
            CameraUpdateFactory.newLatLngZoom(LatLng(target.latitude, target.longitude), zoom)
        )
    }

    // 蓝点。位置不是高德自己定的，走 `LocationSource` 手动喂：
    // `isMyLocationEnabled = true` 之后 SDK 才会来 `activate`，把它那只监听器交给我们，
    // 之后每次位置变了都往那只监听器里灌。在 `activate` 里同步回灌是没用的——
    // 那会儿 SDK 这一侧还没接上，喂进去的第一帧会被丢掉，症状是蓝点根本不出现。
    var locationSink by remember { mutableStateOf<LocationSource.OnLocationChangedListener?>(null) }
    LaunchedEffect(mapView) {
        val map = mapView.map
        map.setLocationSource(object : LocationSource {
            override fun activate(listener: LocationSource.OnLocationChangedListener) {
                locationSink = listener
            }

            override fun deactivate() {
                locationSink = null
            }
        })
        // LOCATION_TYPE_SHOW = 只画点，不跟随、不改镜头——镜头归上面那两条管。
        map.myLocationStyle = MyLocationStyle()
            .myLocationType(MyLocationStyle.LOCATION_TYPE_SHOW)
            .showMyLocation(true)
    }
    LaunchedEffect(mapView, userLocation, locationSink) {
        val point = userLocation
        mapView.map.isMyLocationEnabled = point != null
        if (point == null) return@LaunchedEffect
        locationSink?.onLocationChanged(
            AMapLocation("leap").apply {
                setLatitude(point.latitude)
                setLongitude(point.longitude)
            }
        )
    }

    // 车辆图标的落点。镜头动画期间高德会连着回调，图标就跟着地图一起滑。
    // 还要在挂上监听时先算一次：镜头没动的时候（比如刚进页面）不会有任何回调。
    LaunchedEffect(mapView, latitude, longitude, viewSize) {
        if (anchorCallback == null || viewSize == IntSize.Zero) return@LaunchedEffect
        val map = mapView.map
        val emit = {
            val screen = map.projection.toScreenLocation(LatLng(latitude, longitude))
            anchorCallback?.invoke(Offset(screen.x.toFloat(), screen.y.toFloat()))
            Unit
        }
        map.setOnCameraChangeListener(object : AMap.OnCameraChangeListener {
            override fun onCameraChange(position: CameraPosition?) = emit()
            override fun onCameraChangeFinish(position: CameraPosition?) = emit()
        })
        emit()
    }

    // mapType 不能只写一次：首次组合时高德的渲染线程常常还没起来，这时候设进去的值
    // 会被 SDK 自己的默认值盖掉——症状是暗色下冷启动，首页那张小地图还是白天样式，
    // 而详情页（进去时地图早就加载完了）却是对的。加载完成后再补一次。
    LaunchedEffect(mapView, dark) {
        val map = mapView.map
        val type = if (dark) AMap.MAP_TYPE_NIGHT else AMap.MAP_TYPE_NORMAL
        map.mapType = type
        map.setOnMapLoadedListener { map.mapType = type }
    }

    AndroidView(
        factory = { gate },
        modifier = modifier.onSizeChanged { viewSize = it },
        update = { view ->
            view.blocking = !interactive
            val map = mapView.map
            map.uiSettings.apply {
                // 高德要求 logo 保持可见，其余控件一律关掉——卡片上没地方放，
                // 缩放/指南针/比例尺在这两个场景里也没用。
                isZoomControlsEnabled = false
                isScaleControlsEnabled = false
                isCompassEnabled = false
                isMyLocationButtonEnabled = false
                isScrollGesturesEnabled = interactive
                isZoomGesturesEnabled = interactive
                // 旋转和倾斜一律不给：车辆位置是看一眼就走的信息，斜过去只会看不懂。
                isRotateGesturesEnabled = false
                isTiltGesturesEnabled = false
            }
        },
    )
}

/// 地图的触摸闸门。
///
/// 高德那边把 `isScrollGesturesEnabled` 之类全关掉，`TextureMapView` 依旧会吃掉
/// `ACTION_DOWN`——事件停在地图这一层，外面那张卡片的点击就再也不触发。症状是首页
/// 位置卡点上半截地图没反应，只有点下半截那行字才进得去详情页。
///
/// [blocking] 打开时由这层壳把触摸截住、自己又不消费，事件原路退回 Compose，
/// 卡片上的 clickable 才收得到。
private class MapTouchGate(context: Context) : FrameLayout(context) {
    var blocking = false

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean = blocking

    override fun onTouchEvent(ev: MotionEvent): Boolean = false
}

/// 一次「把镜头挪到这儿」的请求。[seq] 每按一次加一，好让重复点同一个钮也能生效。
data class FocusRequest(val latitude: Double, val longitude: Double, val seq: Int)
