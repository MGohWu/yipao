package org.yipao.app.ui

import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.kyant.backdrop.backdrops.layerBackdrop
import com.kyant.backdrop.backdrops.rememberLayerBackdrop
import org.yipao.app.ui.components.LocalAmbientSpec
import org.yipao.app.ui.components.LocalContentBackdrop
import org.yipao.app.ui.components.LocalOverlayHost
import org.yipao.app.ui.components.OverlayHost
import org.yipao.app.ui.components.drawAmbientBackground
import org.yipao.app.ui.components.rememberAmbientSpec
import org.yipao.app.ui.components.rememberOverlayHostState
import org.yipao.app.ui.components.PasswordSheetHost
import org.yipao.app.ui.components.ToastHost
import org.yipao.app.ui.screens.BatteryHeatScreen
import org.yipao.app.ui.screens.BleKeyPairingScreen
import org.yipao.app.ui.screens.BleKeyScreen
import org.yipao.app.ui.screens.BleKeySettingsScreen
import org.yipao.app.ui.screens.CarModelScreen
import org.yipao.app.ui.screens.ChargePlanScreen
import org.yipao.app.ui.screens.ChargeScreen
import org.yipao.app.ui.screens.ClimateAppointmentScreen
import org.yipao.app.ui.screens.ClimateScreen
import org.yipao.app.ui.screens.ComfortCabinScreen
import org.yipao.app.ui.screens.FridgeScreen
import org.yipao.app.ui.screens.LegalScreen
import org.yipao.app.ui.screens.LocationScreen
import org.yipao.app.ui.screens.MainScaffold
import org.yipao.app.ui.screens.TripsScreen
import org.yipao.app.ui.screens.NotificationControlScreen
import org.yipao.app.ui.screens.ParkPhotoScreen
import org.yipao.app.ui.screens.QuickTileScreen
import org.yipao.app.ui.screens.WidgetScreen
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest

/// 全部二级页路由。字符串就够用：带参数的页面（年款/颜色）拆成了两个独立路由。
object Routes {
    const val Main = "main"

    // P0 首页入口
    const val Charge = "charge"
    const val Climate = "climate"
    const val Location = "location"
    /// 行程页（零跑里程能耗）。
    const val Mileage = "mileage"

    // P1 设置入口
    const val Agreement = "agreement"
    const val Privacy = "privacy"

    // P2 功能磁贴
    const val QuickTile = "quickTile"
    const val NotificationControl = "notificationControl"
    const val Widget = "widget"
    const val BleKey = "bleKey"
    const val BleKeySettings = "bleKeySettings"
    const val BleKeyPairing = "bleKeyPairing"
    const val ParkPhoto = "parkPhoto"
    const val ComfortCabin = "comfortCabin"
    const val Fridge = "fridge"
    const val ClimateAppointment = "climateAppointment"
    const val BatteryHeat = "batteryHeat"
    const val ChargePlan = "chargePlan"
    const val CarModel = "carModel"
}

/// 登录后的导航根："main" 是三 Tab 主骨架，二级页全屏盖在上面（横滑进出）。
/// 控车运行时（Toast + 操作密码弹窗）挂在导航之上，所有页面共用。
@Composable
fun AppNav() {
    val nav = rememberNavController()
    val store = LocalStore.current
    // 锚点弹层宿主：跟页面同一个 window，玻璃才折射得到背景。
    val overlayHost = rememberOverlayHostState()
    // 弹层的取景层：把页面内容一起录进去。页面本身背景是透明的，
    // 得先补一遍氛围背景，折射出来才不是一块透明。
    // 取外层算好的那份，页面换了 tint 这里才跟着换。
    val fallbackAmbient = rememberAmbientSpec()
    val ambient = rememberUpdatedState(LocalAmbientSpec.current ?: fallbackAmbient)
    val contentBackdrop = rememberLayerBackdrop {
        drawAmbientBackground(ambient.value)
        drawContent()
    }
    // 只在真有弹层压着页面时才录。这一层录的是整页内容，首页里装着 WebGL 车模的
    // WebView 和高德地图的 TextureView，每帧拷进离屏层是最贵的一类操作；
    // 而它唯一的用处是给弹层折射，平时录了没人看。
    // 关的时候延一拍：弹层退场动画还在播（底部弹层 200ms、锚点 150ms），
    // 这时候停录，玻璃里会当场变成一片空。
    var overlayActive by remember { mutableStateOf(false) }
    LaunchedEffect(overlayHost) {
        snapshotFlow { overlayHost.hasVisibleOverlay }.collectLatest { visible ->
            if (visible) {
                overlayActive = true
            } else {
                delay(260)
                overlayActive = false
            }
        }
    }

    CompositionLocalProvider(
        LocalOverlayHost provides overlayHost,
        LocalContentBackdrop provides contentBackdrop,
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            NavHost(
                navController = nav,
                startDestination = Routes.Main,
                // iOS push 手感:新页从右滑入,旧页微退淡出。
                enterTransition = {
                    slideInHorizontally(tween(320)) { it } + fadeIn(tween(320))
                },
                exitTransition = {
                    slideOutHorizontally(tween(320)) { -it / 4 } + fadeOut(tween(320))
                },
                popEnterTransition = {
                    slideInHorizontally(tween(320)) { -it / 4 } + fadeIn(tween(320))
                },
                popExitTransition = {
                    slideOutHorizontally(tween(320)) { it } + fadeOut(tween(320))
                },
                // 弹层宿主在这之外，所以录得到页面、录不到自己，不会反馈成拖影。
                modifier = Modifier
                    .fillMaxSize()
                    .then(if (overlayActive) Modifier.layerBackdrop(contentBackdrop) else Modifier),
            ) {
                composable(Routes.Main) {
                    MainScaffold(onOpen = { route -> nav.navigate(route) })
                }

                val back: () -> Unit = { nav.popBackStack() }

                composable(Routes.Charge) { ChargeScreen(onBack = back) }
                composable(Routes.Climate) {
                    ClimateScreen(onBack = back, onOpenAppointment = { nav.navigate(Routes.ClimateAppointment) })
                }
                composable(Routes.ClimateAppointment) { ClimateAppointmentScreen(onBack = back) }
                composable(Routes.Location) { LocationScreen(onBack = back) }
                composable(Routes.Mileage) { TripsScreen(onBack = back) }

                composable(Routes.Agreement) { LegalScreen(onBack = back, privacy = false) }
                composable(Routes.Privacy) { LegalScreen(onBack = back, privacy = true) }

                composable(Routes.QuickTile) { QuickTileScreen(onBack = back) }
                composable(Routes.NotificationControl) { NotificationControlScreen(onBack = back) }
                composable(Routes.Widget) { WidgetScreen(onBack = back) }
                composable(Routes.BleKey) {
                    BleKeyScreen(onBack = back, onOpenSettings = { nav.navigate(Routes.BleKeySettings) })
                }
                composable(Routes.BleKeySettings) {
                    BleKeySettingsScreen(onBack = back, onOpenPairing = { nav.navigate(Routes.BleKeyPairing) })
                }
                composable(Routes.BleKeyPairing) { BleKeyPairingScreen(onBack = back) }
                composable(Routes.ParkPhoto) { ParkPhotoScreen(onBack = back) }
                composable(Routes.ComfortCabin) { ComfortCabinScreen(onBack = back) }
                composable(Routes.Fridge) { FridgeScreen(onBack = back) }
                composable(Routes.BatteryHeat) { BatteryHeatScreen(onBack = back) }
                composable(Routes.ChargePlan) { ChargePlanScreen(onBack = back) }
                // 年款车模的入口已从功能中心撤掉，路由和页面留着：设置页那个「显示车模」
                // 开关还在，哪天要把入口放回去，加回 FeatureCenter 里那张卡片就行。
                composable(Routes.CarModel) { CarModelScreen(onBack = back) }
            }

            ToastHost(store)
            // 密码弹窗现在也是走弹层宿主的，得在宿主的 CompositionLocal 范围内声明。
            PasswordSheetHost(store)
            OverlayHost(overlayHost)
        }
    }
}
