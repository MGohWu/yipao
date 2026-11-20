package org.yipao.app

import android.app.Application
import com.amap.api.maps.MapsInitializer
import com.amap.api.location.AMapLocationClient
import com.amap.api.services.core.ServiceSettings
import org.yipao.app.core.AppEnv
import org.yipao.app.widget.VehicleRefreshScheduler

/// 进程级初始化：装 Context、跑高德的合规初始化。
///
/// 高德那段的由来——
/// 高德 SDK 从 9.x 起强制：MapView 构造之前必须先调过 updatePrivacyShow / updatePrivacyAgree，
/// 否则不发起鉴权，地图渲染成一整块黑的（还不报错，只在 logcat 里留一行提示）。
/// 放在 Application 里是因为它必须早于任何一个地图页面。
///
/// 传 true 的依据：地图只出现在登录之后的页面，而登录页要求勾选《用户协议》和《隐私政策》
/// 才能提交。之后若把地图挪到登录前，这里要改成读真实的同意状态。
class LeapApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // 数据层（SecureVault、AuthAuditLog、LearnedSignals）拿 Context 全走这里，
        // 必须早于任何一次会话读取。
        AppEnv.install(this)
        org.yipao.app.core.AuthAuditLog.note(
            "[widget-env] diagnostics=1 pid=${android.os.Process.myPid()} process=${getProcessName()} " +
                "app=${AppEnv.versionName}/${AppEnv.versionCode} sdk=${android.os.Build.VERSION.SDK_INT} " +
                "device=${android.os.Build.MANUFACTURER}/${android.os.Build.MODEL} build=${android.os.Build.DISPLAY}"
        )
        // 桌面上还摆着卡片的话，把后台那趟 15 分钟的车况刷新排上。
        // 卡片的 `onEnabled` 只在第一次添加时来一次，覆盖安装的用户等不到它。
        VehicleRefreshScheduler.syncOnLaunch()
        // 参数含义：(context, 隐私政策是否已展示, 用户是否已同意)
        MapsInitializer.updatePrivacyShow(this, true, true)
        MapsInitializer.updatePrivacyAgree(this, true)
        // 搜索 SDK（逆地理编码，见 LocationNaming）有自己的一套合规开关，
        // MapsInitializer 那两行管不到它：不调这两行，GeocodeSearch 一律回错误码，
        // 车辆位置永远只有坐标、出不来地名。
        ServiceSettings.updatePrivacyShow(this, true, true)
        ServiceSettings.updatePrivacyAgree(this, true)
        // 定位 SDK 又是第三套开关。三套互不相干，漏哪套哪套不工作。
        AMapLocationClient.updatePrivacyShow(this, true, true)
        AMapLocationClient.updatePrivacyAgree(this, true)
    }
}
