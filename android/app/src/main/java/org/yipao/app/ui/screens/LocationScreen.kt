package org.yipao.app.ui.screens

import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.LocationOff
import androidx.compose.material.icons.outlined.Navigation
import androidx.compose.material.icons.outlined.OpenInFull
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import org.yipao.app.app.DrivingRoute
import org.yipao.app.app.UserLocation
import org.yipao.app.core.Coordinate
import org.yipao.app.ui.LocalStore
import org.yipao.app.ui.components.SubPageTopPadding
import org.yipao.app.ui.components.AMapView
import org.yipao.app.ui.components.AnchoredMenu
import org.yipao.app.ui.components.AnchoredOverlayBox
import org.yipao.app.ui.components.FocusRequest
import org.yipao.app.ui.components.GlassCard
import org.yipao.app.ui.components.HairlineDivider
import org.yipao.app.ui.components.LiquidButton
import org.yipao.app.ui.components.PageTint
import org.yipao.app.ui.components.PressFeedback
import org.yipao.app.ui.components.liquidGlass
import org.yipao.app.ui.components.pressable
import org.yipao.app.ui.relativeText
import org.yipao.app.ui.theme.LeapColors
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

/// 「导航到车辆」能跳的地图。
///
/// 车端给的坐标是 **GCJ-02**（国测局／「火星坐标」），三家在大陆原生就吃 GCJ-02，
/// 所以传进去的必须是没转换过的车端原始坐标——安卓这端不做任何换算。
/// 每家声明坐标系的方式不一样，逐个写死，别照抄别处的模板：
/// - 高德 `dev`：0 = 我给的是高德坐标（GCJ-02），1 = GPS 原始坐标（WGS-84）。
/// - 百度 `coord_type`：百度内部用 BD-09，靠这个参数说清输入是什么，它再转一次。
///   填 `wgs84` 会让它在 GCJ-02 上又叠一次纠偏，落点偏出几百米。
/// - 腾讯 `tocoord`：默认就按 GCJ-02 收，不需要额外参数。
enum class MapApp(val title: String, val pkg: String) {
    Amap("高德地图", "com.autonavi.minimap"),
    Baidu("百度地图", "com.baidu.BaiduMap"),
    Tencent("腾讯地图", "com.tencent.map");

    fun uri(coordinate: Coordinate, name: String): Uri {
        val encoded = Uri.encode(name)
        val lat = coordinate.latitude
        val lon = coordinate.longitude
        return when (this) {
            Amap -> Uri.parse("androidamap://route?sourceApplication=壹跑&dlat=$lat&dlon=$lon&dname=$encoded&dev=0&t=0")
            Baidu -> Uri.parse(
                "baidumap://map/direction?destination=name:$encoded|latlng:$lat,$lon&mode=driving&coord_type=gcj02"
            )
            Tencent -> Uri.parse("qqmap://map/routeplan?type=drive&to=$encoded&tocoord=$lat,$lon")
        }
    }
}

/// 车辆位置页，对应 iOS VehicleLocationView：全屏地图 + 底部信息卡 +「直线距离 / 驾车距离」。
/// 不套 SubPageScaffold——地图要铺满整屏，返回钮和「回到车辆」浮在地图上。
///
/// 两格距离要先知道**手机**在哪，所以这一页会问定位权限；没给就不摆这两格，
/// 换成一行「开启定位…」，不摆两个永远「定位中」的空格子。权限只在这一页要，
/// 退出去就不再定位，也没有后台定位。
@Composable
fun LocationScreen(onBack: () -> Unit) {
    // 同 iOS VehicleLocationView。
    PageTint(LeapColors.cool)
    val store = LocalStore.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val coordinate = store.coordinate
    var showMapPicker by remember { mutableStateOf(false) }

    var permitted by remember { mutableStateOf(UserLocation.isPermitted(context)) }
    // 位置卡右边那张驻车照片。没解锁、演示模式、这台车没照片都只是不显示，
    // 不摆空占位也不摆上锁提示——位置页是附加信息，报错留给功能中心那页说。
    var parkingImage by remember { mutableStateOf<ImageBitmap?>(null) }
    var parkingUploadTime by remember { mutableStateOf<String?>(null) }
    var loadingParkingPhoto by remember { mutableStateOf(false) }
    var showingParkingPhoto by remember { mutableStateOf(false) }
    var userCoordinate by remember { mutableStateOf<Coordinate?>(null) }
    var phoneLocationFailed by remember { mutableStateOf(false) }
    var locatingPhone by remember { mutableStateOf(false) }
    var locationAttempt by rememberSaveable { mutableIntStateOf(0) }
    var route by remember { mutableStateOf<DrivingRoute?>(null) }
    // 「回到车辆 / 回到我的位置」按下去之后要飞的目标，以及车辆图标当前落在屏幕哪儿。
    var focus by remember { mutableStateOf<FocusRequest?>(null) }
    var focusSeq by remember { mutableIntStateOf(0) }
    var vehicleAnchor by remember { mutableStateOf<Offset?>(null) }
    // 路线算失败和还没算完是两回事：前者说「暂不可用」，后者说「计算中」。
    var routeFailed by remember { mutableStateOf(false) }
    // 权限被永久拒绝后再 launch 系统弹窗不会出现，只能引到应用详情页去开。
    var asked by rememberSaveable { mutableStateOf(false) }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { granted -> permitted = granted.values.any { it } }

    // 进页面要一次位置；有了位置再算路线。车挪了（坐标变了）重算路线，位置不用重取。
    LaunchedEffect(permitted, locationAttempt) {
        if (!permitted) {
            userCoordinate = null
            phoneLocationFailed = false
            locatingPhone = false
            route = null
            routeFailed = false
            return@LaunchedEffect
        }
        locatingPhone = true
        phoneLocationFailed = false
        val found = UserLocation.current()
        if (found != null) userCoordinate = found
        phoneLocationFailed = found == null && userCoordinate == null
        locatingPhone = false
    }
    LaunchedEffect(userCoordinate, coordinate?.latitude, coordinate?.longitude, locationAttempt) {
        val user = userCoordinate
        val vehicle = coordinate
        if (user == null || vehicle == null) {
            route = null
            routeFailed = false
            return@LaunchedEffect
        }
        route = null
        routeFailed = false
        val found = UserLocation.drivingRoute(user, vehicle)
        route = found
        routeFailed = found == null
    }
    // 地图选择只列真装了的那几家。装没装是启动时的事实，重组之间不会变。
    val installed = remember {
        MapApp.entries.filter { app ->
            runCatching { context.packageManager.getPackageInfo(app.pkg, 0) }.isSuccess
        }
    }

    // 切车要重拉：上一辆的照片留在屏幕上比空着更糟。同 iOS / 鸿蒙的 `loadParkingPhoto`。
    LaunchedEffect(store.session.selectedVin) {
        parkingImage = null
        parkingUploadTime = null
        if (store.isDemo) {
            return@LaunchedEffect
        }
        loadingParkingPhoto = true
        try {
            val (photo, bytes) = store.loadParkingPhoto()
            parkingImage = bytes?.let {
                BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap()
            }
            parkingUploadTime = photo.displayUploadTime
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            parkingImage = null
            parkingUploadTime = null
        } finally {
            loadingParkingPhoto = false
        }
    }

    // 有坐标但还没解析出地名时补一次。同 iOS 的 `.task(id: coordinate?.latitude)`。
    LaunchedEffect(coordinate?.latitude, coordinate?.longitude) {
        if (coordinate != null && store.locationName == null) store.resolveLocationName()
    }

    Box(modifier = Modifier.fillMaxSize()) {
        if (coordinate != null) {
            // 标记那个 Box 是「40dp 内容 + 180dp 下内边距」整体居中，实际圆心比屏幕中心高 90dp
            //（(40+180)/2 - 40/2），地图对焦点跟着抬 90dp 才和它对得上。
            AMapView(
                latitude = coordinate.latitude,
                longitude = coordinate.longitude,
                centerOffsetY = 90.dp,
                userLocation = userCoordinate,
                focus = focus,
                onVehicleAnchor = { vehicleAnchor = it },
                modifier = Modifier.fillMaxSize(),
            )

            // 车辆标记。镜头能被挪到别处（「回到我的位置」），所以图标不能钉在屏幕中央——
            // 位置由地图把车辆坐标投影出来给（`onVehicleAnchor`），投影还没出来之前先
            // 照老样子摆在偏上居中，那正是进页面时镜头对准车的地方。
            val markerRadius = with(LocalDensity.current) { 20.dp.toPx() }
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .let { base ->
                        val anchor = vehicleAnchor
                        if (anchor == null) {
                            base.align(Alignment.Center).padding(bottom = 180.dp)
                        } else {
                            base.offset {
                                IntOffset(
                                    (anchor.x - markerRadius).roundToInt(),
                                    (anchor.y - markerRadius).roundToInt(),
                                )
                            }
                        }
                    }
                    .size(40.dp)
                    .background(MaterialTheme.colorScheme.secondary, CircleShape),
            ) {
                Icon(
                    Icons.Filled.DirectionsCar,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSecondary,
                    modifier = Modifier.size(20.dp),
                )
            }
        } else {
            // 没坐标就不画地图：一张定在默认位置的地图会被当成「车在这儿」。
            EmptyLocation(privacyOn = store.state?.privacyGPSAllowed == false)
        }

        // 顶部浮层:返回钮
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                // 顶栏和别的二级页留一样的空，见 [SubPageTopPadding]。
                .padding(horizontal = 12.dp)
                .padding(top = SubPageTopPadding, bottom = 8.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(40.dp)
                    .pressable(
                        onClick = onBack,
                        shape = CircleShape,
                        feedback = PressFeedback.Fade,
                    )
                    .liquidGlass(CircleShape, LeapColors.card),
            ) {
                Icon(
                    Icons.AutoMirrored.Outlined.ArrowBack,
                    contentDescription = "返回",
                    modifier = Modifier.size(20.dp),
                )
            }
            Spacer(Modifier.weight(1f))
            // 「回到车辆」和「回到我的位置」。跟 iOS、鸿蒙一样摆在标题栏这一行右侧：
            // 底下压着信息卡，右下角放不下，也会跟高德自己那个定位钮打架。
            if (coordinate != null) {
                MapFocusButton(icon = Icons.Filled.DirectionsCar, label = "回到车辆") {
                    focusSeq += 1
                    focus = FocusRequest(coordinate.latitude, coordinate.longitude, focusSeq)
                }
            }
            // 没定位到就不摆这个钮——按下去没地方可去。
            userCoordinate?.let { user ->
                Spacer(Modifier.size(8.dp))
                MapFocusButton(icon = Icons.Filled.MyLocation, label = "回到我的位置") {
                    focusSeq += 1
                    focus = FocusRequest(user.latitude, user.longitude, focusSeq)
                }
            }
        }

        // 底部玻璃信息卡
        GlassCard(
            shape = RoundedCornerShape(28.dp),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(14.dp),
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.padding(18.dp),
            ) {
                // 左文右图：地址、时间、两个距离在左边竖着排，右边一张竖着的驻车照片。
                // 车主拍驻车位置基本都是竖着拍的，铺满整卡宽度横切一刀就只剩中间一条，
                // 看不出停在哪个位置；竖图配竖图，占的宽度还更小。iOS / 鸿蒙同一个版式。
                Row(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.Top,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.weight(1f),
                    ) {
                        // 更新时间另起一行。左栏让出照片那 78dp 之后，地名要占两行，
                        // 时间再挤在同一行右边就会卡在地名换行处的空档里，看着像标题的一部分。
                        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(
                                Icons.Filled.Place,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.secondary,
                                modifier = Modifier
                                    .padding(top = 3.dp)
                                    .size(16.dp),
                            )
                            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(
                                    text = when {
                                        coordinate == null -> "暂无车辆位置"
                                        store.locationName != null -> store.locationName!!
                                        store.locationResolveFailed -> "位置解析暂不可用"
                                        else -> "正在解析位置"
                                    },
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                // 拉取时间读不到就整格不写，不猜一个「刚刚」。
                                store.lastUpdated?.let {
                                    Text(
                                        text = "更新于 ${relativeText(it)}",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }
                        }
                        // 车都没定位到就别谈「离我多远」。
                        if (coordinate != null) {
                            if (permitted) {
                                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                                    DistanceMetric(
                                        title = "直线距离",
                                        value = userCoordinate?.let {
                                            distanceText(UserLocation.straightDistance(it, coordinate))
                                        } ?: if (phoneLocationFailed) "暂不可用" else "定位中",
                                        modifier = Modifier.weight(1f),
                                    )
                                    DistanceMetric(
                                        title = "驾车距离",
                                        value = when {
                                            route != null -> drivingText(route!!)
                                            userCoordinate == null && phoneLocationFailed -> "暂不可用"
                                            userCoordinate == null || locatingPhone -> "定位中"
                                            routeFailed -> "暂不可用"
                                            else -> "计算中"
                                        },
                                        modifier = Modifier.weight(1f),
                                    )
                                }
                            } else {
                                Text(
                                    text = if (asked) "去系统设置开启定位，显示与车辆的距离" else "开启定位，显示与车辆的距离",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = LeapColors.cool,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .pressable(
                                            onClick = {
                                                // 第一次走系统弹窗；被拒过之后弹窗不会再出现，只能去详情页。
                                                if (asked) {
                                                    context.startActivity(
                                                        Intent(
                                                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                                            Uri.fromParts("package", context.packageName, null),
                                                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                                    )
                                                } else {
                                                    asked = true
                                                    permissionLauncher.launch(
                                                        arrayOf(
                                                            android.Manifest.permission.ACCESS_COARSE_LOCATION,
                                                            android.Manifest.permission.ACCESS_FINE_LOCATION,
                                                        )
                                                    )
                                                }
                                            },
                                            feedback = PressFeedback.Fade,
                                        )
                                        .padding(vertical = 2.dp),
                                )
                            }
                        }
                    }

                    ParkingPhotoThumb(
                        image = parkingImage,
                        loading = loadingParkingPhoto,
                        onClick = { showingParkingPhoto = true },
                    )
                }
                HairlineDivider()
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    // 地图选择从按钮本身弹出来（iOS 26 popover），不再是屏幕正中的对话框。
                    AnchoredOverlayBox(
                        expanded = showMapPicker,
                        onDismissRequest = { showMapPicker = false },
                        modifier = Modifier.weight(1f),
                        anchor = {
                            LiquidButton(
                                text = "导航到车辆",
                                onClick = {
                                    // 一家都没装就没得选，直说，不弹一个空菜单。
                                    if (installed.isEmpty()) {
                                        store.show(text = "没有找到可用的地图 App", isError = true)
                                    } else {
                                        showMapPicker = true
                                    }
                                },
                                tint = LeapColors.cool,
                                icon = Icons.Outlined.Navigation,
                                height = 46.dp,
                                enabled = coordinate != null,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        },
                    ) {
                        AnchoredMenu(
                            options = installed,
                            selected = null,
                            label = { it.title },
                            onSelect = { app ->
                                showMapPicker = false
                                val target = coordinate ?: return@AnchoredMenu
                                val intent = Intent(Intent.ACTION_VIEW, app.uri(target, store.vehicleName))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                try {
                                    context.startActivity(intent)
                                } catch (e: Exception) {
                                    store.show(text = "打不开${app.title}", isError = true)
                                }
                            },
                        )
                    }
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(46.dp)
                            .pressable(
                                onClick = {
                                    locationAttempt += 1
                                    scope.launch { store.refresh(showSpinner = true) }
                                },
                                enabled = !store.isRefreshing,
                                shape = CircleShape,
                                feedback = PressFeedback.Fade,
                            )
                            .background(MaterialTheme.colorScheme.surfaceVariant),
                    ) {
                        Icon(
                            Icons.Outlined.Refresh,
                            contentDescription = "刷新位置",
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }
            }
        }

        if (showingParkingPhoto) {
            parkingImage?.let { shot ->
                ParkingPhotoViewer(
                    image = shot,
                    caption = parkingUploadTime,
                    onDismiss = { showingParkingPhoto = false },
                )
            }
        }
    }
}

/// 位置卡右边那张驻车照片：车停在哪、当时长什么样，一眼看完。
///
/// 竖着放、按原比例装进 78×104 的框里，不裁。车主拍驻车位置基本都是竖着拍的，
/// 横切一刀就只剩中间一条，看不出停在哪个位置。上传时间不往这么小的图上压，
/// 挪到点开的大图里去说。尺寸和 iOS `parkingPhotoThumb`、鸿蒙同名 Builder 一致。
@Composable
private fun ParkingPhotoThumb(
    image: ImageBitmap?,
    loading: Boolean,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(12.dp)
    when {
        image != null -> Box(
            modifier = Modifier
                .width(ThumbWidth)
                .height(ThumbHeight)
                .pressable(onClick = onClick, shape = shape, feedback = PressFeedback.Fade)
                .background(MaterialTheme.colorScheme.surfaceVariant),
        ) {
            Image(
                bitmap = image,
                contentDescription = "驻车照片",
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize(),
            )
            Icon(
                Icons.Outlined.OpenInFull,
                contentDescription = null,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(5.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.72f))
                    .padding(5.dp)
                    .size(12.dp),
            )
        }
        // 拉取期间先占住这块，出图时左边那列的宽度不会跳一下。
        loading -> Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .width(ThumbWidth)
                .height(ThumbHeight)
                .clip(shape)
                .background(MaterialTheme.colorScheme.surfaceVariant),
        ) {
            CircularProgressIndicator(
                strokeWidth = 2.dp,
                color = MaterialTheme.colorScheme.outline,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

private val ThumbWidth = 78.dp
private val ThumbHeight = 104.dp

/// 点开缩略图后的大图：黑底、捏合缩放、放大后可拖动、双击在 1×/2× 之间切。
/// 对应 iOS 的 `ParkingPhotoViewer`。
@Composable
private fun ParkingPhotoViewer(
    image: ImageBitmap,
    caption: String?,
    onDismiss: () -> Unit,
) {
    var scale by remember { mutableStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }

    Dialog(
        onDismissRequest = onDismiss,
        // 不加 decorFitsSystemWindows = false 的话，Dialog 只铺到状态栏和手势条之间，
        // 黑底盖不住那两条，边上会透出底下的地图。
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
        ),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black),
        ) {
            Image(
                bitmap = image,
                contentDescription = "驻车照片",
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer(
                        scaleX = scale,
                        scaleY = scale,
                        translationX = offset.x,
                        translationY = offset.y,
                    )
                    // 两个探测器要跑在同一个 pointerInput 里各起一个协程。分别挂两个
                    // pointerInput 的话，先声明的那个会把手势整段吃掉，后面那个再也收不到，
                    // 表现就是双击没反应。
                    .pointerInput(Unit) {
                        coroutineScope {
                            launch {
                                detectTransformGestures { _, pan, zoom, _ ->
                                    // 缩到 1 倍以下就弹回贴边，同时把平移一并归零，
                                    // 否则松手后会停在一个既小又偏出屏幕的位置。
                                    scale = (scale * zoom).coerceIn(1f, 4f)
                                    offset = if (scale > 1f) offset + pan else Offset.Zero
                                }
                            }
                            launch {
                                detectTapGestures(
                                    onDoubleTap = {
                                        scale = if (scale > 1f) 1f else 2f
                                        offset = Offset.Zero
                                    },
                                )
                            }
                        }
                    },
            )

            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .statusBarsPadding()
                    .padding(16.dp)
                    .size(36.dp)
                    .pressable(onClick = onDismiss, shape = CircleShape, feedback = PressFeedback.Fade)
                    .background(Color.White.copy(alpha = 0.18f)),
            ) {
                Icon(
                    Icons.Outlined.Close,
                    contentDescription = "关闭",
                    tint = Color.White,
                    modifier = Modifier.size(18.dp),
                )
            }

            caption?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.labelMedium,
                    color = Color.White.copy(alpha = 0.85f),
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .navigationBarsPadding()
                        .padding(16.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(Color.White.copy(alpha = 0.18f))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
        }
    }
}

/// 「直线距离 / 约 1.2 公里」这样的一格。
/// 地图右上角那两个圆钮。跟返回钮同一套玻璃圆片，只是图标不同。
@Composable
private fun MapFocusButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(40.dp)
            .pressable(onClick = onClick, shape = CircleShape, feedback = PressFeedback.Fade)
            .liquidGlass(CircleShape, LeapColors.card),
    ) {
        Icon(icon, contentDescription = label, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun DistanceMetric(title: String, value: String, modifier: Modifier = Modifier) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp), modifier = modifier) {
        Text(
            text = title,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(text = value, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
    }
}

/// 一公里以内报米，超了报公里。同 iOS `formatDistance`。
private fun distanceText(meters: Float): String =
    if (meters < 1000f) "约 ${meters.roundToInt()} 米" else String.format("约 %.1f 公里", meters / 1000f)

/// 「约 3.4 公里 · 12 分钟」。高德没给耗时就只报距离，不编一个。
private fun drivingText(route: DrivingRoute): String {
    val distance = distanceText(route.distanceMeters)
    val minutes = route.durationSeconds?.let { (it / 60f).roundToInt() } ?: return distance
    return "$distance · $minutes 分钟"
}

/// 拿不到坐标时的整屏空态。隐私模式和「压根没报」是两回事，得分开说——
/// 前者用户自己去车机上关，后者等下一次上报就行。
@Composable
private fun EmptyLocation(privacyOn: Boolean) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterVertically),
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 40.dp, vertical = 120.dp),
    ) {
        Icon(
            Icons.Outlined.LocationOff,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.outline,
            modifier = Modifier.size(44.dp),
        )
        Text(
            text = "暂无车辆位置",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            text = if (privacyOn) {
                "车辆已开启位置隐私模式，App 无法获取坐标。"
            } else {
                "车况里还没有上报经纬度，稍后再试。"
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}
