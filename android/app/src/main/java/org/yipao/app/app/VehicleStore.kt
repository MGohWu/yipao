package org.yipao.app.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.yipao.app.core.AppEnv
import org.yipao.app.core.AuthAuditLog
import org.yipao.app.core.BLEKeyCertificateStore
import org.yipao.app.core.BLEPairingHistory
import org.yipao.app.core.BLEReconnectTokenStore
import org.yipao.app.core.BLEVehicleBindingStore
import org.yipao.app.core.CarImageCache
import org.yipao.app.core.CarLayerComposer
import org.yipao.app.core.CarModel
import org.yipao.app.core.CabinCommands
import org.yipao.app.core.CarModelAssets
import org.yipao.app.core.ClimateAppointment
import org.yipao.app.core.ClimateMode
import org.yipao.app.core.ControlDiagnostic
import org.yipao.app.core.ControlReceipt
import org.yipao.app.core.Coordinate
import org.yipao.app.core.DiagLog
import org.yipao.app.core.DrivingStats
import org.yipao.app.core.DrivingStatsRange
import org.yipao.app.core.ExpectationKind
import org.yipao.app.core.FridgeSetting
import org.yipao.app.core.SeatComfortChannel
import org.yipao.app.core.SeatPosition
import org.yipao.app.core.fridgeState
import org.yipao.app.core.hasCabinComfort
import org.yipao.app.core.mirrorHeatingOn
import org.yipao.app.core.seatLevel
import org.yipao.app.core.steeringWheelHeatLevel
import org.yipao.app.core.steeringWheelHeatMinutes
import org.yipao.app.core.LeapBLEKeyCertificate
import org.yipao.app.core.LeapClient
import org.yipao.app.core.LeapCommand
import org.yipao.app.core.LeapError
import org.yipao.app.core.LeapErrorKind
import org.yipao.app.core.LeapSession
import org.yipao.app.core.LearnedSignals
import org.yipao.app.core.OperationPasswordStore
import org.yipao.app.core.ParkingPhoto
import org.yipao.app.core.SnapshotStore
import org.yipao.app.core.Vehicle
import org.yipao.app.core.VehicleSignal
import org.yipao.app.core.VehicleSnapshot
import org.yipao.app.core.VehicleState
import org.yipao.app.core.WidgetSettings
import org.yipao.app.widget.LeapSurfaces
import org.yipao.app.ui.theme.AppearanceMode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

/// 一次控车请求在 UI 上要走的确认流程。
sealed class AuthChallenge {
    /// 需要用户输入操作密码（首次使用、或生物识别不可用/失败）。
    data class OperationPassword(val prompt: String) : AuthChallenge()
}

/// 空调设定草稿存本机。空调没开的时候车端不保存这几项（上报的是上次运行的残留值），
/// 不自己存一份的话，每次冷启动都会回到默认值而不是用户上次选的。
object ClimateDraft {

    private const val PREFIX = "climate.draft."

    private val prefs get() = AppEnv.prefs(AppPrefs.NAME)

    var temperature: Int
        get() = prefs.getInt(PREFIX + "temperature", 24)
        set(value) = prefs.edit().putInt(PREFIX + "temperature", value).apply()

    var fanLevel: Int
        get() = prefs.getInt(PREFIX + "fanLevel", 3)
        set(value) = prefs.edit().putInt(PREFIX + "fanLevel", value).apply()

    var mode: ClimateMode
        get() = prefs.getString(PREFIX + "mode", null)
            ?.let { raw -> ClimateMode.entries.firstOrNull { it.name == raw } }
            ?: ClimateMode.Cold
        set(value) = prefs.edit().putString(PREFIX + "mode", value.name).apply()

    var circleIn: Boolean
        get() = prefs.getBoolean(PREFIX + "circleIn", true)
        set(value) = prefs.edit().putBoolean(PREFIX + "circleIn", value).apply()
}

/// 普通偏好的落脚点。敏感项（会话、操作密码）一律走 `SecureVault`，不进这里。
object AppPrefs {
    const val NAME = "leap-app"
}

/// 最近一次控车经过，存本机——排查时 App 往往已经被杀过一次了。
/// 里面只有回执响应和时序，没有 token 也没有操作密码。
///
/// 手搓 JSON 而不是引序列化库：这个项目没有 kotlinx.serialization，
/// 为一条诊断记录引一整套编译期插件不划算。
object ControlDiagnosticStore {

    private const val KEY = "control.diagnostic.last"

    fun save(diagnostic: ControlDiagnostic?) {
        val prefs = AppEnv.prefs(AppPrefs.NAME)
        if (diagnostic == null) {
            prefs.edit().remove(KEY).apply()
            return
        }
        val samples = JSONArray()
        diagnostic.receiptResponses.forEach {
            samples.put(JSONObject().put("at", it.at).put("body", it.body))
        }
        val json = JSONObject()
            .put("label", diagnostic.label)
            .put("cmdid", diagnostic.cmdid)
            .put("msgID", diagnostic.msgID)
            .put("sentAt", diagnostic.sentAt)
            .put("outcome", diagnostic.outcome.name)
            .put("elapsed", diagnostic.elapsed)
            .put("pollCount", diagnostic.pollCount)
            .put("receiptResponses", samples)
            .put("errorMessage", diagnostic.errorMessage ?: JSONObject.NULL)
        prefs.edit().putString(KEY, json.toString()).apply()
    }

    fun load(): ControlDiagnostic? {
        val text = AppEnv.prefs(AppPrefs.NAME).getString(KEY, null) ?: return null
        return try {
            val json = JSONObject(text)
            val samples = json.optJSONArray("receiptResponses")
            val responses = buildList {
                for (index in 0 until (samples?.length() ?: 0)) {
                    val item = samples!!.optJSONObject(index) ?: continue
                    add(
                        ControlDiagnostic.ReceiptSample(
                            at = item.optDouble("at", 0.0),
                            body = item.optString("body"),
                        ),
                    )
                }
            }
            val outcome = ControlDiagnostic.Outcome.entries
                .firstOrNull { it.name == json.optString("outcome") }
                ?: return null
            ControlDiagnostic(
                label = json.optString("label"),
                cmdid = json.optString("cmdid"),
                msgID = json.optString("msgID"),
                sentAt = json.optLong("sentAt"),
                outcome = outcome,
                elapsed = json.optDouble("elapsed", 0.0),
                pollCount = json.optInt("pollCount"),
                receiptResponses = responses,
                errorMessage = json.optString("errorMessage").takeIf {
                    it.isNotEmpty() && !json.isNull("errorMessage")
                },
            )
        } catch (e: Exception) {
            null
        }
    }
}

data class ToastMessage(
    val id: Long,
    val text: String,
    val detail: String? = null,
    val isError: Boolean = false,
    /// 带重试按钮的提示要停久一点，否则用户还没来得及点就消失了。
    val showsRetry: Boolean = false,
    val seconds: Double = 3.0,
)

/// 界面和后端之间唯一的那层。iOS 那份是 `@Observable` 的 `VehicleStore`，
/// 这里用 Compose 的 `mutableStateOf` 达到同样效果：写属性即触发重组。
///
/// **进程级单例**，不是 `ViewModel`：车况轮询、登录态、控车确认窗口都要活得比任何一个
/// Activity 长（转屏、从通知返回都不该打断一次正在等车确认的控车），
/// 这正是 iOS 那边 `@State` 挂在 App 上的语义。轮询的起停由 Activity 生命周期驱动
/// （对应 iOS 的 `scenePhase`）。
class VehicleStore private constructor(
    private val client: LeapClient = LeapClient(),
) {

    companion object {
        val shared: VehicleStore by lazy { VehicleStore() }

        /// 车况没有推送，只能轮询。前台每 10 秒一次，进后台立刻停——
        /// 后台既刷新不了界面，也只是白白耗电和打服务端。
        const val POLL_INTERVAL_MS = 10_000L

        /// 实测车辆 5–10 秒响应，休眠时更久。20 秒是覆盖正常情况又不至于干等太久的折中。
        /// 已知一次真实样本：空调开启 11.8 秒确认。
        const val CONFIRM_TIMEOUT_MS = 20_000L

        /// 每 2 秒查一次。这个值同时决定了确认的时间分辨率——
        /// 间隔多长，「车实际什么时候动的」就有多大误差。
        const val POLL_STEP_MS = 2_000L

        /// 用户刚动过空调的这几秒内，车况说什么都不改草稿。
        private const val CLIMATE_EDIT_GRACE_MS = 3_000L

        /// 松手到下发之间的防抖窗口。和空调页调温度那条是同一个值、同一个理由：
        /// 连点三下档位只该发最后那一档，不该打出一串远控请求。
        const val CABIN_PUSH_DELAY_MS = 800L

        private const val STEERING_WHEEL_KEY = "steeringWheel"
        private const val FRIDGE_KEY = "fridge"

        /// 行驶中禁发的命令：尾门（130）和前备箱（131）。行驶中弹开箱盖挡视线是物理危险，
        /// 天窗/遮阳帘（300/240）不在列——那是乘员本来就会在行驶中动的东西。
        private val DRIVING_BLOCKED_CONTROLS = mapOf("130" to "尾门", "131" to "前备箱")
    }

    private val passwordStore = OperationPasswordStore()
    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
    private val carModelLoadMutex = Mutex()
    private val prefs get() = AppEnv.prefs(AppPrefs.NAME)

    // MARK: - 对外状态

    var session by mutableStateOf(LeapSession.fresh())
        private set

    /// 每退出一次登录递增。界面拿它当首页的 key，强制重建整棵视图树，
    /// 重登后一定从首页开始，不会把上一段会话推着的页面带回来。
    var loginEpoch by mutableStateOf(0)
        private set

    var state by mutableStateOf<VehicleState?>(null)
        private set

    var isRefreshing by mutableStateOf(false)
        private set

    var isSendingCommand by mutableStateOf(false)
        private set

    var lastUpdated by mutableStateOf<Long?>(null)
        private set

    /// 车端采集这份车况的时刻。读不到（某些车型不报 `collectTime`）时是 null。
    /// 不单独存一份：它完全由 `state` 决定，存下来只会多一处忘记清空的地方。
    val reportedAt: Long? get() = state?.reportedAt

    var lastReceipt by mutableStateOf<ControlReceipt?>(null)
        private set

    /// 指令下发后正在等车动作。和 `isSendingCommand` 分开：
    /// 前者是「网络请求在飞」，这个是「车还没确认」，界面上要提示的是后者。
    var confirmingLabel by mutableStateOf<String?>(null)
        private set

    /// 超时后可以原样重发的指令。不自动重发——尾门和鸣笛重发是会真的再动一次车的。
    var retryableCommand by mutableStateOf<LeapCommand?>(null)
        private set

    var lastDiagnostic by mutableStateOf<ControlDiagnostic?>(null)
        private set

    /// 车辆位置反解析出的地址名，比经纬度对用户有意义得多。
    var locationName by mutableStateOf<String?>(null)
        private set

    /// 坐标存在，但逆地理编码已经明确失败。和“请求还没回来”分开，避免界面永久显示解析中。
    var locationResolveFailed by mutableStateOf(false)
        private set

    var toast by mutableStateOf<ToastMessage?>(null)

    var challenge by mutableStateOf<AuthChallenge?>(null)
        private set

    /// 生物识别开关（用户可关，关掉后每次控车都手输操作密码）。
    var biometricEnabled by mutableStateOf(true)
        private set

    /// 记住操作密码后才能用生物识别代替输入。
    var hasSavedPassword by mutableStateOf(false)
        private set

    /// 深浅外观，默认跟随系统。
    var appearance by mutableStateOf(AppearanceMode.System)
        private set

    /// 首页是否画官方车模型图层（关掉走轮廓剪影，也不再下载图片）。
    var showCarModel by mutableStateOf(true)
        private set

    // MARK: - 车模图层

    /// 爱车图。演示态为 null（回退剪影）。3D 车也有这张静态图，用作 3D 加载前的占位。
    ///
    /// 冷启动时是上次缓存的成品，图层叠好之后换成 `carComposition.base`。
    var carImage by mutableStateOf<Bitmap?>(null)
        private set

    /// 按车况叠好的分层车图。充电时中间那段是多帧的，界面自己播。
    var carComposition by mutableStateOf<CarLayerComposer.ComposedCar?>(null)
        private set

    var carModel by mutableStateOf<CarModel?>(null)
        private set

    /// 3D 资源解压目录。有值才渲染 3D。
    var carModelRoot by mutableStateOf<File?>(null)
        private set

    /// 手动刷新后目录路径不变，用这个版本号强制首页重建 3D 渲染器。
    var carModelRevision by mutableStateOf(0)
        private set

    /// 从解压目录反推的车型别名（`Lafa5` 这种）。渲染器按它拼资源路径，
    /// 接口不返回，只能等资源落地后现推——见 `CarModelAssets.assetAlias`。
    var carAssetAlias by mutableStateOf<String?>(null)
        private set

    var is3DDownloading by mutableStateOf(false)
        private set

    var isCarModelRefreshing by mutableStateOf(false)
        private set

    /// 2D 分层贴图目录。有值说明这台车走叠图那条路。
    private var carLayerRoot: File? = null

    /// 上次叠出来的图层组合，用来跳过没变化的重绘。
    private var composedLayerSignature: String? = null

    val biometricKind: BiometricGate.Kind get() = BiometricGate.available

    // MARK: - 本地草稿（控件即时反馈，指令下发后再由车况纠正）

    var climateTemperature by mutableStateOf(24)
        private set
    var climateFanLevel by mutableStateOf(3)
        private set
    var climateMode by mutableStateOf(ClimateMode.Cold)
        private set
    var climateCircleIn by mutableStateOf(true)
        private set
    var climateOn by mutableStateOf(false)
        private set
    var chargeLimitDraft by mutableStateOf(90)
        private set

    fun updateClimateTemperature(value: Int) {
        climateTemperature = value
        ClimateDraft.temperature = value
        noteClimateEdit()
    }

    fun updateClimateFanLevel(value: Int) {
        climateFanLevel = value
        ClimateDraft.fanLevel = value
        noteClimateEdit()
    }

    fun updateClimateMode(value: ClimateMode) {
        climateMode = value
        ClimateDraft.mode = value
        noteClimateEdit()
    }

    fun updateClimateCircleIn(value: Boolean) {
        climateCircleIn = value
        ClimateDraft.circleIn = value
        noteClimateEdit()
    }

    fun updateChargeLimitDraft(value: Int) {
        chargeLimitDraft = value
    }

    /// 用户最后一次在界面上动空调的时间。
    ///
    /// 这段时间里的车况不许回冲草稿：从按下到指令真正发出去有一段防抖延迟，
    /// 期间十秒一次的轮询要是插进来，车报的还是旧值，用户刚调的数字会被弹回去——
    /// 看上去就是「这一下没生效，得再按一次」。
    private var climateEditedAt: Long? = null

    /// 正在用车况回填草稿，这期间不算用户操作。
    private var isSyncingClimateDrafts = false

    /// 指令还在路上时用户又调了。等这条走完补发一次最新的，别把用户的调整吞掉。
    private var climatePushQueued = false

    private fun noteClimateEdit() {
        if (isSyncingClimateDrafts) return
        climateEditedAt = System.currentTimeMillis()
    }

    private val isClimateDraftFresh: Boolean
        get() {
            val editedAt = climateEditedAt ?: return false
            return System.currentTimeMillis() - editedAt < CLIMATE_EDIT_GRACE_MS
        }

    /// 等待用户确认后要发送的指令。
    private var pendingCommand: LeapCommand? = null

    /// 充电计划保存要一次连发多条（健康充电 480 + 充电计划 190），
    /// 一次操作密码验证覆盖整批。等待手输密码时把整批指令暂存在这里。
    private var pendingChargeBatch: List<LeapCommand>? = null

    /// 最近一次车真的知道的空调设定。
    ///
    /// 界面上改模式、温度、风量是立刻生效的（要的就是这个即时反馈），但指令还得过操作密码。
    /// 用户取消掉密码、或者指令下发失败，车压根没收到，界面却已经显示成新设定了——
    /// 这时必须退回这份，否则就是在骗人。C11 不上报空调模式，靠车况纠正是等不到的。
    private var confirmedClimate: ClimateSettings? = null

    private data class ClimateSettings(
        val on: Boolean,
        val temperature: Int,
        val fanLevel: Int,
        val mode: ClimateMode,
        val circleIn: Boolean,
    )

    private val currentClimate: ClimateSettings
        get() = ClimateSettings(climateOn, climateTemperature, climateFanLevel, climateMode, climateCircleIn)

    private fun rollbackClimateDraft() {
        val settings = confirmedClimate ?: return
        if (settings == currentClimate) return
        isSyncingClimateDrafts = true
        climateOn = settings.on
        climateTemperature = settings.temperature
        climateFanLevel = settings.fanLevel
        climateMode = settings.mode
        climateCircleIn = settings.circleIn
        isSyncingClimateDrafts = false
    }

    /// 本次前台使用期间已经验证过身份，后续指令直接下发。
    ///
    /// 退到后台就作废：手机放在桌上被别人拿起来时，不该还能一路点到底。
    /// 密码只留在内存里，不额外落盘——落盘的那份始终只有勾了「记住」的那个。
    private var verifiedPassword: String? = null

    private var toastSequence = 0L

    init {
        // 首帧就得知道登没登录。真正的会话是 `SecureVault` 同步读出来的，没有理由等到
        // `bootstrap()`——中间那几帧按「没登录」渲染，每次冷启动都会闪一下登录页。
        session = if (ReviewDemo.isActive) ReviewDemo.session else client.initialSession
        biometricEnabled = prefs.getBoolean("biometricEnabled", true)
        hasSavedPassword = passwordStore.hasPassword
        appearance = prefs.getString("appearanceMode", null)
            ?.let { raw -> AppearanceMode.entries.firstOrNull { it.name == raw } }
            ?: AppearanceMode.System
        showCarModel = prefs.getBoolean("showCarModel", true)
        climateTemperature = ClimateDraft.temperature
        climateFanLevel = ClimateDraft.fanLevel
        climateMode = ClimateDraft.mode
        climateCircleIn = ClimateDraft.circleIn
        lastDiagnostic = ControlDiagnosticStore.load()
        DiagLog.note("[store] VehicleStore 就绪 loggedIn=${session.isLoggedIn} demo=$isDemo")
    }

    // MARK: - 设置项

    fun updateBiometricEnabled(enabled: Boolean) {
        biometricEnabled = enabled
        prefs.edit().putBoolean("biometricEnabled", enabled).apply()
    }

    fun updateAppearance(mode: AppearanceMode) {
        appearance = mode
        prefs.edit().putString("appearanceMode", mode.name).apply()
    }

    fun updateShowCarModel(enabled: Boolean) {
        if (showCarModel == enabled) return
        showCarModel = enabled
        prefs.edit().putBoolean("showCarModel", enabled).apply()
        // 开关不只是显示与否：关掉之后连下载、解压、叠图都不再发生。
        if (enabled) scope.launch { loadCarModel() } else unloadCarModel()
    }

    // MARK: - 派生状态

    val isLoggedIn: Boolean get() = session.isLoggedIn

    val vehicleName: String get() = session.displayVehicleName

    /// 演示态不发任何网络请求，控车只回一条提示。
    val isDemo: Boolean get() = ReviewDemo.isActive

    /// 这台车能不能远程控车窗，见 `VehicleState.windowsRemoteSupported`。
    ///
    /// **读不到车况时按「能」算**：不知道不等于不能。冷启动那一下车况还是空的，
    /// 按「不能」算会让车窗按钮先消失、读到车况再冒出来，比多摆一个按钮更难看。
    val windowsControllable: Boolean get() = state?.windowsRemoteSupported ?: true

    /// 当前选中车支不支持哨兵模式。来源是 vehicle/list 的 `permission`（含 "400" 且非 S01/T03），
    /// 随车走、不看车况。
    val sentinelSupported: Boolean get() = session.selectedVehicle?.isSentinelSupported ?: false

    /// 哨兵当前是否开启。直接透传车况的 `sentinelOn`（信号 3636），不做本地草稿。
    val sentinelOn: Boolean get() = state?.sentinelOn ?: false

    val sunshadeSupported: Boolean
        get() = session.selectedVehicle?.let { Vehicle.supportsSunshade(it.permission) } ?: false

    val sunroofSupported: Boolean
        get() = session.selectedVehicle?.let { Vehicle.supportsSunroof(it.carType, it.permission) } ?: false

    val frunkSupported: Boolean
        get() = session.selectedVehicle?.let { Vehicle.supportsFrunk(it.carType, it.permission) } ?: false

    /// 舒适座舱页要不要给入口。
    ///
    /// 和上面那几项反过来：**车况信号说话，能力码只是兜底**。信号比能力码更贴车端
    /// （八个座椅信号在车主 C16 上逐个在场），而方向盘加热那条指令（cmdid 320）压根没有
    /// 已知的 `abilities` 原始码，只能靠信号 `1816`。两路都没有才隐藏。
    val cabinComfortSupported: Boolean
        get() {
            if (state?.hasCabinComfort == true) return true
            val vehicle = session.selectedVehicle ?: return false
            return Vehicle.supportsCabinComfort(vehicle.carType, vehicle.permission)
        }

    /// 车载冰箱要不要给入口。同上，信号优先。
    ///
    /// 车主那台 C16 两路都没有（`abilities` 不含 `76`、signalMap 里冰箱信号全无），
    /// 所以这个入口在他车上整个不出现——这是「读不到就别显示」，不是功能缺失。
    val fridgeSupported: Boolean
        get() {
            if (state?.fridgeState != null) return true
            val vehicle = session.selectedVehicle ?: return false
            return Vehicle.supportsFridge(vehicle.carType, vehicle.permission)
        }

    /// 车辆坐标，**车端原样的 GCJ-02**，隐私模式下拿不到。
    /// 高德收的就是 GCJ-02，直接用；安卓这条链路上没有任何需要转换的落点。
    val coordinate: Coordinate? get() = state?.shareableCoordinate

    // MARK: - 蓝牙钥匙

    /// 蓝牙运行时。界面直接读它的 `runtimeState` / `pairingState`。
    val ble: BLEVehicleController get() = BLEVehicleController.shared

    /// 演示模式不碰真车，也就不该有蓝牙钥匙。
    val bluetoothKeyEligible: Boolean
        get() = !isDemo

    /// 本机已缓存的证书。没有就是没有——不联网、不抛错，调用方自己决定要不要去同步。
    fun cachedBLECredential(): Triple<LeapBLEKeyCertificate, String, String>? {
        if (isDemo) return null
        val accountId = session.oldAuth?.accountId.orEmpty()
        if (accountId.isEmpty() || session.selectedVin.isEmpty()) return null
        val certificate = BLEKeyCertificateStore.load(accountId, session.selectedVin) ?: return null
        return Triple(certificate, accountId, session.selectedVin)
    }

    /// 拉一次证书并落盘，然后把运行时装配起来。
    suspend fun syncBLECredential(): LeapBLEKeyCertificate {
        if (!bluetoothKeyEligible) throw LeapError.server("当前环境不能使用蓝牙钥匙")
        val certificate = client.fetchBLEKeyCertificate()
        if (!certificate.isSupportedKeyType) {
            throw LeapError.server("当前蓝牙证书类型不受支持（keyType=${certificate.keyType}）")
        }
        if (!certificate.hasValidPasswordCard) {
            throw LeapError.server("当前蓝牙证书的 passwordCard 无效，请重新同步")
        }
        session = client.currentSession()
        val accountId = session.oldAuth?.accountId.orEmpty()
        if (accountId.isEmpty() || session.selectedVin.isEmpty()) throw LeapError.notLoggedIn()
        if (!BLEKeyCertificateStore.save(certificate, accountId, session.selectedVin)) {
            throw LeapError.server("蓝牙证书写入本机加密存储失败")
        }
        refreshBluetoothRuntime()
        return certificate
    }

    /// 把当前账号/车辆/缓存证书交给运行时。登录、切车、拿到新证书之后都要调一次。
    fun refreshBluetoothRuntime() {
        val accountId = session.oldAuth?.accountId.orEmpty()
        if (!bluetoothKeyEligible || accountId.isEmpty() || session.selectedVin.isEmpty()) {
            ble.deactivate(clearBinding = false)
            return
        }
        // 设备号还没就位（开机后加密存储还读不到的那段窗口）：证书就算在手里也签不出认证包
        // （`BLEProtocol` 会挡空 deviceId），拿空值去 configure 只会得到一次静默失败的连接。
        // 不清绑定，等下一次 refresh（切车、进钥匙页、前台服务重建都会调）自己接上。
        if (session.deviceId.isEmpty()) {
            AuthAuditLog.note("[ble:arm] deviceId 尚未就绪，先不武装")
            ble.deactivate(clearBinding = false)
            return
        }
        ble.configure(
            accountId = accountId,
            deviceId = session.deviceId,
            vin = session.selectedVin,
            certificate = BLEKeyCertificateStore.load(accountId, session.selectedVin),
        )
    }

    /// 没有界面时把会话接回来。前台服务被系统重建、小组件/磁贴/通知按下即发都走它。
    ///
    /// 刻意不探活、不拉车况、不起轮询——那些都要网络，而这条路上的调用方要么根本不联网
    /// （无感钥匙），要么自己紧接着就会发请求（直接控车）。多探一次只是白等一个来回。
    fun restoreSessionInBackground() {
        if (isDemo) return
        session = client.currentSession()
        if (!session.isLoggedIn && client.restoreSessionFromStore()) {
            session = client.currentSession()
        }
    }

    /// 前台服务被系统重建时的最小恢复路径：只把会话和蓝牙运行时接回来。
    ///
    /// 证书和绑定全在本机加密存储里，手机在地库没信号时，
    /// 恰恰是最需要蓝牙钥匙照常工作的时候。
    fun restoreBluetoothRuntimeInBackground() {
        restoreSessionInBackground()
        if (!session.isLoggedIn) return
        refreshBluetoothRuntime()
    }

    /// 退登会连坐清掉蓝牙钥匙（证书、绑定、重连凭证都跟账号走）。重新登录后静默补同步一次，
    /// 让「打开 App 就能用」而不是让用户自己去点一下同步。补不上不打扰——
    /// 没资格、离线、服务端拒绝都可能走到这，蓝牙钥匙页会如实说明。
    private suspend fun recoverBluetoothCredentialIfNeeded() {
        if (!bluetoothKeyEligible) return
        if (cachedBLECredential() != null) {
            refreshBluetoothRuntime()
            return
        }
        val accountId = session.oldAuth?.accountId.orEmpty()
        if (accountId.isEmpty() || session.selectedVin.isEmpty()) return
        try {
            syncBLECredential()
            DiagLog.note("[ble:recover] 登录后证书缺失，已自动补同步")
            // 「需要重新配对」只对**确实配过**的车说。第二辆车、换新手机首登同样停在 unbound，
            // 但那不是谁清了配对，弹这条只会让用户以为丢了什么。
            if (ble.runtimeState is BLERuntimeState.Unbound &&
                BLEPairingHistory.hasPaired(accountId, session.selectedVin)
            ) {
                show(
                    "蓝牙钥匙需要重新配对",
                    detail = "退出登录会清除配对信息，请在车旁打开 功能中心 → 蓝牙钥匙 完成配对",
                    seconds = 6.0,
                )
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            DiagLog.note("[ble:recover] 登录后补同步蓝牙证书失败：${LeapError.messageOf(e)}")
        }
    }

    /// 蓝牙钥匙页点「开始配对」。证书没有就先同步，再交给运行时开扫描。
    suspend fun prepareBLEPairing() {
        if (!bluetoothKeyEligible) {
            show("当前环境不能使用蓝牙钥匙", isError = true)
            return
        }
        try {
            if (cachedBLECredential() == null) syncBLECredential() else refreshBluetoothRuntime()
            ble.beginPairing()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            show(e)
        }
    }

    fun setBluetoothControlEnabled(enabled: Boolean) = ble.setBluetoothControlEnabled(enabled)

    fun setPassiveAutoUnlock(enabled: Boolean) = ble.updatePassiveEntry(
        autoUnlock = enabled,
        autoLock = ble.binding?.configuration?.autoLockEnabled ?: false,
    )

    fun setPassiveAutoLock(enabled: Boolean) = ble.updatePassiveEntry(
        autoUnlock = ble.binding?.configuration?.autoUnlockEnabled ?: false,
        autoLock = enabled,
    )

    fun removeBluetoothBinding() = ble.removeBinding()

    // MARK: - 前台轮询

    private var pollJob: Job? = null

    fun startPolling() {
        stopPolling()
        if (!session.isLoggedIn || isDemo) return
        pollJob = scope.launch {
            while (isActive) {
                delay(POLL_INTERVAL_MS)
                refresh()
            }
        }
    }

    fun stopPolling() {
        pollJob?.cancel()
        pollJob = null
    }

    // MARK: - 生命周期

    suspend fun bootstrap() {
        // 审核员可能会杀掉 App 重进，演示态要能恢复，否则会掉回登录页。
        if (isDemo) {
            session = ReviewDemo.session
            val demoState = demoVehicleState
            state = demoState
            lastUpdated = System.currentTimeMillis()
            syncDraftsFromState(demoState)
            resolveLocationName()
            // 杀进程重进这条路也要落快照：`enterDemo` 只在「用演示账号登录」那一次跑，
            // 之后每次冷启动都走这里。少了它，桌面卡片在第二次启动之后就再没内容了。
            publishSnapshot()
            return
        }
        session = client.currentSession()
        // 启动那帧钥匙串可能是「读不到」而不是「没有」。跑到这里设备多半已解锁，
        // 先给一次自愈机会再下未登录的结论。
        if (!session.isLoggedIn && client.restoreSessionFromStore()) {
            session = client.currentSession()
        }
        if (!session.isLoggedIn) return
        startLoggedInSession()
    }

    /// 登录态确认在手之后的启动流程。冷启动和前台自愈共用一份，
    /// 免得自愈出来的会话少走了哪一步。
    private suspend fun startLoggedInSession() {
        // 上次缓存的车图先顶上，首页就不会先闪一下剪影再换图。
        if (showCarModel && carImage == null) {
            carImage = withContext(Dispatchers.IO) { CarImageCache.cached(session.selectedVin) }
        }
        // 开 App 先探一次登录态：被挤下线后车况仍能刷出来，只有主动探控车 token 才发现。
        // 失效就直接回登录页，不再往下拉车况和轮询。
        if (!validateSession(force = true)) return
        refresh(showSpinner = true)
        startPolling()
        refreshBluetoothRuntime()
        scope.launch { recoverBluetoothCredentialIfNeeded() }
        // 车模型是静态的，拉一次即可；放最后不挡车况刷新。
        loadCarModel()
    }

    /// 前台激活时停在登录页的自愈入口：启动那帧读失败的话，这里重读一次，
    /// 恢复出登录态就直接进首页。只有那种情况会真的动手，其余时候什么都不做。
    suspend fun restoreSessionIfNeeded() {
        if (session.isLoggedIn || isDemo) return
        if (!client.restoreSessionFromStore()) return
        session = client.currentSession()
        startLoggedInSession()
    }

    /// 轮询和用户手动刷新会撞在一起，同一时刻只允许一个请求在飞。
    private var fetchInFlight = false

    /// 本次运行内是否已成功拉过一次 `vehicle/list`。用来「首启强制刷新一次能力码」。
    private var didLoadVehiclesThisLaunch = false

    suspend fun refreshChargePlan(): Boolean {
        if (isDemo) return true
        val vin = session.selectedVin
        val account = session.oldAuth?.accountId
        return try {
            val plan = client.refreshChargePlan()
            if (vin != session.selectedVin || account != session.oldAuth?.accountId) return false
            state = (state ?: VehicleState()).copy(chargePlan = plan, chargePlanLimit = plan?.percent)
            true
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            if (vin == session.selectedVin && account == session.oldAuth?.accountId) {
                show("充电计划读取失败", detail = "请稍后重试，暂未取得最新设置")
            }
            false
        }
    }

    /// @param refreshConfig 是否重拉 commonConfig（充电上限/充电计划）。
    ///   下拉/手动刷新传 `true`；轮询保持默认 `false`，走客户端按 VIN 的缓存。
    suspend fun refresh(showSpinner: Boolean = false, refreshConfig: Boolean = false) {
        if (!session.isLoggedIn || isDemo || fetchInFlight) return
        fetchInFlight = true
        if (showSpinner) isRefreshing = true
        try {
            // 本会话首次、或车辆列表为空、或任一车能力码是老会话兜出来的默认值（abilitiesStale
            // 判增程 / sentinelStale 判哨兵），都强制重拉一次 vehicle/list 把 abilities→isExtendRange、
            // permission→isSentinelSupported 一并刷到最新。否则升级用户持久化的旧车列表非空、又缺
            // 这些字段，增程会被永久误判成纯电（油量整块消失）、哨兵支持位会被永久误判成不支持，
            // 且永不自愈。
            val capabilitiesStale = session.vehicles.any { it.abilitiesStale || it.sentinelStale }
            if (session.vehicles.isEmpty() || !didLoadVehiclesThisLaunch || capabilitiesStale) {
                client.loadVehicles()
                didLoadVehiclesThisLaunch = true
                session = client.currentSession()
            }
            val fresh = client.fetchVehicleState(refreshConfig = refreshConfig)
            state = fresh
            lastUpdated = System.currentTimeMillis()
            syncDraftsFromState(fresh)
            session = client.currentSession()
            resolveLocationName()
            // 车况变了图层就得重叠一次，门窗开合、充电动画才跟得上。
            composeCarImage()
            // 反查完地名再写快照，卡片上那句 headline 才有地名可说。
            publishSnapshot()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            show(e)
        } finally {
            isRefreshing = false
            fetchInFlight = false
        }
    }

    /// 卡片 / 磁贴上那个刷新按钮走的路。
    ///
    /// 和 [refresh] 只差一件事：**失败要抛出去**。[refresh] 把异常收进 App 内的 toast，
    /// 而按下卡片刷新的人根本看不到 toast，得由调用方记进 `WidgetSettings.recordControlError`
    /// 顶到卡片上——否则按一下什么都不发生，连「是不是没按到」都判断不了。
    suspend fun refreshForSurfaces() {
        if (isDemo) throw LeapError.server("演示模式没有真实车况")
        // 系统可能只为了这一下按键把进程拉起来，会话得先接回来。
        restoreSessionInBackground()
        if (!session.isLoggedIn) throw LeapError.notLoggedIn()
        val fresh = client.fetchVehicleState()
        state = fresh
        lastUpdated = System.currentTimeMillis()
        syncDraftsFromState(fresh)
        session = client.currentSession()
        resolveLocationName()
        // 桌面刷新只更新车况。车模资源和卡片车图由设置页的“刷新车模型”单独管理，
        // 不能因为一次车况刷新就改写甚至短暂清空车模文件。
        publishSnapshot()
    }

    /// 把当前车况写进共享快照，并让小组件、磁贴、常驻通知跟着重画。
    ///
    /// 这三处表面各自都读不到 `VehicleStore`（系统随时可能只为画一张卡把进程拉起来），
    /// 所以刷新车况的唯一入口这里必须落一份盘。
    private fun publishSnapshot() {
        val fresh = state ?: return
        SnapshotStore.write(
            VehicleSnapshot.make(
                state = fresh,
                vehicleName = vehicleName,
                locationName = locationName,
                updatedAt = lastUpdated ?: System.currentTimeMillis(),
            ),
        )
        scope.launch { LeapSurfaces.reloadAll() }
    }

    // MARK: - 车模图层

    /// 拉车模型。两条路：3D 车（modelType 3）下模型 + 渲染器两个包走 WebGL；
    /// 其余车型下的是一套分层贴图，按车况叠出官方那张会动的车图。
    /// 两条都走不通就留着剪影。
    ///
    /// 演示态不拉；用户关掉「显示车模型」时也不拉——那时下载下来也不会显示。
    suspend fun loadCarModel() {
        if (!session.isLoggedIn || isDemo || !showCarModel) return
        try {
            carModelLoadMutex.withLock { loadCarModelContent(forceRefresh = false) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            // 拿不到就保持剪影，不打扰用户。
            DiagLog.note("[carmodel] 失败：${LeapError.messageOf(e)}")
        }
    }

    /// 设置页的显式刷新入口。只有这里强制重新下载；下载和校验全部成功后才替换旧资源。
    suspend fun refreshCarModel() {
        if (isCarModelRefreshing) return
        if (!session.isLoggedIn || isDemo) {
            show("当前没有可刷新的车模型", isError = true)
            return
        }
        if (!showCarModel) {
            show("请先打开“显示车模型”", isError = true)
            return
        }
        isCarModelRefreshing = true
        try {
            val loaded = carModelLoadMutex.withLock {
                loadCarModelContent(forceRefresh = true)
            }
            if (loaded) {
                carModelRevision += 1
                show("车模型下载成功")
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            val message = LeapError.messageOf(e)
            DiagLog.note("[carmodel] 手动刷新失败：$message")
            show("车模型下载失败", detail = message, isError = true)
        } finally {
            isCarModelRefreshing = false
        }
    }

    private suspend fun loadCarModelContent(forceRefresh: Boolean): Boolean {
        if (!session.isLoggedIn || isDemo || !showCarModel) return false
        val model = client.fetchCarModel()
        // 下载途中用户可能把「显示车模型」关掉了，每个挂起点回来都要再看一眼，
        // 否则关掉开关后车图还是会冒出来。
        if (!showCarModel) return false
        val vin = session.selectedVin
        carModel = model

        val param = model.modelParam
        if (model.has3DPackages && param != null) {
            val root = if (!forceRefresh && CarModelAssets.isReady(vin)) {
                CarModelAssets.directory(vin)
            } else {
                is3DDownloading = true
                try {
                    CarModelAssets.prepare(vin, model, forceRefresh) { key ->
                        client.fetchCarModelPackage(key)
                    }
                } finally {
                    is3DDownloading = false
                }
            }
            if (!showCarModel) return false
            // 别名要在设 root 之前推出来：root 一变 3D 视图就重建并立刻 newInit，
            // 那时 alias 还是 null 的话，第一帧仍然按 carType 拼路径。
            carAssetAlias = CarModelAssets.assetAlias(root, param.carTypeCode)
            client.rememberCarAlias(carAssetAlias)
            if (forceRefresh) {
                carLayerRoot = null
                composedLayerSignature = null
            }
            carModelRoot = root
            adoptLayers(root)
            return true
        }

        val root = if (!forceRefresh && CarModelAssets.areLayersReady(vin)) {
            CarModelAssets.directory(vin)
        } else {
            CarModelAssets.prepareLayers(vin, model, forceRefresh) { key ->
                client.fetchCarModelPackage(key)
            }
        }
        if (!showCarModel) return false
        if (forceRefresh) composedLayerSignature = null
        carLayerRoot = CarLayerComposer.layerDirectory(root)
        composeCarImage()
        return true
    }

    /// 清掉内存里的车图和 3D 资源引用，首页立刻回到剪影。
    /// 关开关、换车、退出登录、会话失效都要走这里——这些字段不清的话，
    /// 下一台车（或下一位用户）登录后首页渲的还是上一台。
    /// 磁盘上已下载的资源留着，按 VIN 分目录，回来时不用再下一遍。
    private fun unloadCarModel() {
        carImage = null
        carComposition = null
        carLayerRoot = null
        composedLayerSignature = null
        carModel = null
        carModelRoot = null
        carAssetAlias = null
        // 卡片那份也得清，否则桌面上会一直挂着上一台车（或上一位用户的车）。
        CarImageCache.clearShared()
        scope.launch { LeapSurfaces.reloadAll() }
    }

    /// 按当前车况把图层叠成车图。车况一变就重叠一次，门窗开合、充电会跟着显示。
    ///
    /// 十几张 1125×525 的 PNG 解码加叠图，在主线程上是几百毫秒的卡顿，
    /// 所以整段搬到 `Dispatchers.Default`——iOS 那边是在主 actor 上直接做的，
    /// 这一处安卓必须自己让开。
    private suspend fun composeCarImage() {
        val layerRoot = carLayerRoot ?: return
        val carType = session.selectedCarType
        val snapshot = state
        // 签名必须带上图层目录（按 VIN 分的）：图层名只反映车况，
        // 两台车碰巧都锁着不充电时签名会一模一样，只比图层名的话，
        // 换车/换账号后这里会因「没变化」直接返回，旧车图永远不被覆盖。
        val signature = layerRoot.path + "#" +
            CarLayerComposer.plan(snapshot, carType).signature
        if (signature == composedLayerSignature) return
        composedLayerSignature = signature
        val composed = withContext(Dispatchers.Default) {
            CarLayerComposer.compose(snapshot, carType, layerRoot)
        } ?: return
        carComposition = composed
        carImage = composed.base
        val vin = session.selectedVin
        // 缓存底图就够了：它是车身及以下那一整块，冷启动拿它顶第一帧不会露空白。
        // 卡片那份要拍平的整车（含充电口盖、开着的门）。两次写盘都别占着主线程。
        val sharedChanged = withContext(Dispatchers.IO) {
            CarImageCache.store(composed.base, vin)
            CarImageCache.storeShared(composed.still())
        }
        if (sharedChanged) scope.launch { LeapSurfaces.reloadAll() }
    }

    /// 3D 渲染器截来的车图，**只给桌面小组件用**。
    ///
    /// 3D 车的资源包里根本没有 2D 图层（真机实测：C11 2026、B10 2025 解出来只有渲染器
    /// 和模型，没有 `android/<density>/`），`composeCarImage()` 那条路一次都跑不了，
    /// 小组件上的车图因此一直是空的——桌面上只剩剪影。官方安卓也是这么绕过去的：
    /// 3D 车的爱车图就是渲染器截的图，2D 车才是分层贴图叠的。
    ///
    /// 首页不用这张：那儿有现渲的 3D，比截图新鲜。
    fun adoptRenderedCarImage(png: ByteArray) {
        if (!session.isLoggedIn || isDemo || !showCarModel) return
        scope.launch {
            val stored = withContext(Dispatchers.IO) {
                val bitmap = runCatching {
                    BitmapFactory.decodeByteArray(png, 0, png.size)
                }.getOrNull() ?: return@withContext false
                // 背景没抠干净的那种整块底图会被挡在这一步，写不进去就保持原样
                // （见 CarImageCache）。
                CarImageCache.storeSharedRendered(bitmap)
            }
            if (stored) LeapSurfaces.reloadAll()
        }
    }

    /// 3D 车型也把包里那套 2D 图层认下来。
    ///
    /// 资源包里两套都有，只是走 3D 那条分支时从没试过取图层。首页照旧渲 3D
    /// ——「三层回退：3D → 2D 车图 → 剪影」，补上这一层之后，3D 加载期间和
    /// WebGL 挂掉时垫的不再是剪影而是真车图，桌面小组件也才有车图可用。
    /// 包里没有图层目录就保持原样。
    private suspend fun adoptLayers(root: File) {
        if (carLayerRoot != null) return
        carLayerRoot = CarLayerComposer.layerDirectory(root) ?: return
        composeCarImage()
    }

    /// 把坐标换成「杭州市民中心」这类地址，失败时不显示任何回退坐标。
    /// 十秒一次的轮询里，车没动就不重复解析。
    suspend fun resolveLocationName() {
        val target = coordinate
        if (target == null) {
            locationName = null
            locationResolveFailed = false
            return
        }
        val resolved = LocationNaming.name(target)
        if (resolved == null) {
            locationResolveFailed = true
        } else {
            locationName = resolved
            locationResolveFailed = false
        }
    }

    /// 拉里程能耗统计。演示模式给演示数据；真机四个接口并发拉，失败的块置 null。
    suspend fun loadDrivingStats(): DrivingStats? {
        if (isDemo) return ReviewDemo.drivingStats
        return try {
            client.fetchDrivingStats()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            null
        }
    }

    /// 拉某一周的能耗构成（点周柱子时按周调）。
    /// 演示模式给一份跟着周变的假数据——六根柱子点下去数字纹丝不动，看着就像点坏了。
    suspend fun loadEnergyDistribution(range: DrivingStatsRange): DrivingStats.EnergyDistribution? {
        if (isDemo) return ReviewDemo.energyDistribution(range)
        return try {
            client.fetchEnergyDistribution(range)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            null
        }
    }

    /// 驻车照片只有最近一张；图片数据不写普通缓存，避免旧 URL 覆盖新照片。
    suspend fun loadParkingPhoto(): Pair<ParkingPhoto, ByteArray?> {
        if (isDemo) throw LeapError.server("演示模式没有驻车照片")
        val photo = client.fetchParkingPhoto()
        val url = photo.url ?: return photo to null
        return photo to client.downloadParkingPhoto(url)
    }

    /// 车况回来后把本地草稿对齐。
    ///
    /// 只在空调**开着**的时候对齐：这时车端是权威的，界面该显示车里真实在跑的设定。
    /// 空调关着时车端上报的模式/温度是上一次运行留下的残留值，拿它覆盖草稿，
    /// 界面就会每次都落回上一次的档位，而且十秒一次的轮询会把用户刚选好的设定反复冲掉。
    private fun syncDraftsFromState(fresh: VehicleState) {
        fresh.chargeLimit?.takeIf { it > 0 }?.let { chargeLimitDraft = it }
        clearCabinDraftsIfSettled()
        // 用户刚动过、或者指令还在路上时，车况里还是旧值，回冲草稿等于把刚调的弹回去。
        if (isClimateDraftFresh || isSendingCommand || climatePushQueued) return
        isSyncingClimateDrafts = true
        try {
            climateOn = fresh.acOn
            if (!fresh.acOn) return
            fresh.acSetting?.let { climateTemperature = it }
            fresh.acFanLevel?.takeIf { it > 0 }?.let { climateFanLevel = minOf(7, it) }
            // 车端没上报模式就别动草稿。硬对齐会把用户刚选的「制冷」冲成「自动」，
            // 而且十秒一次的轮询会反复冲。
            fresh.climateMode?.let { climateMode = it }
            fresh.acCircleIn?.let { climateCircleIn = it }
            // 车况是车自己报的，对齐完这份就是车确认知道的设定。
            confirmedClimate = currentClimate
        } finally {
            isSyncingClimateDrafts = false
        }
    }

    // MARK: - 登录

    suspend fun sendSMS(phone: String): Boolean {
        // 演示账号不走短信通道：这个号码在零跑那边并不存在，真发只会拿到一个错误。
        if (phone == ReviewDemo.PHONE) {
            show("演示账号无需验证码", detail = "验证码填 ${ReviewDemo.CODE}")
            return true
        }
        return try {
            client.sendSMS(phone)
            show("验证码已发送")
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            show(e)
            false
        }
    }

    suspend fun login(phone: String, code: String): Boolean {
        if (ReviewDemo.matches(phone, code)) {
            enterDemo()
            return true
        }
        return try {
            client.login(phone, code)
            session = client.currentSession()
            show("登录成功")
            // 会话启动的活儿一件都不能挂在调用方的协程上。上面这行一写进去 `isLoggedIn`
            // 就是 true，根导航的 Crossfade 立刻把登录页移出组合树，页面自己那个
            // `rememberCoroutineScope` 随之取消——车况刷新会在 `getCarRoute` 的响应回来时
            // 半路夭折（continuation 再没人接），`startPolling` 更是压根轮不到执行，
            // 于是首页永远停在「等待车况」，轮询也不会把它救回来，只能杀进程重开。
            // 整件事还是静默的：`CancellationException` 原样往上抛，一句提示都没有。
            // 换成 store 自己的长生命周期 scope，并与冷启动共用 [startLoggedInSession]。
            scope.launch {
                // 车图缓存按 VIN 取，得先有选中车，否则首页要先闪一下剪影再换图。
                runCatching { client.loadVehicles() }
                session = client.currentSession()
                startLoggedInSession()
            }
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            // 失败也要把 client 那边的会话同步过来。`client.login()` 失败时已经把自己退回
            // 干净态了，界面这份要是还停在旧值，两边就又不一致了。
            session = client.currentSession()
            show(e)
            false
        }
    }

    /// 演示态装载的车况。Release 下就是审核用的那份；Debug 包可以按 `DemoData.screen`
    /// 叠加本地核对用的信号（舒适座舱 / 冰箱…），审核那份不受影响。
    private val demoVehicleState: VehicleState
        get() = DemoData.overlay(ReviewDemo.vehicleState)

    /// 进入演示态：装载写死的车况，不建立任何会话，也不启动轮询
    /// （轮询本来就会被 `isDemo` 挡掉，这里不启动是为了不留一个空转的任务）。
    private fun enterDemo() {
        ReviewDemo.isActive = true
        session = ReviewDemo.session
        val demoState = demoVehicleState
        state = demoState
        lastUpdated = System.currentTimeMillis()
        syncDraftsFromState(demoState)
        // 反查完地名再落快照，桌面卡片上那句 headline 才有地名可说——和 [refresh]
        // 里的顺序一样。少了这句 `publishSnapshot`，演示模式下三处表面全是
        // 「还没有车况」：它们各自读的是磁盘上那份快照，而演示态从不写盘。
        scope.launch {
            resolveLocationName()
            publishSnapshot()
        }
        show("已进入演示模式", detail = "数据为模拟，不会控制真实车辆")
    }

    suspend fun logout() {
        AuthAuditLog.note("用户主动退出登录")
        ReviewDemo.isActive = false
        loginEpoch += 1
        stopPolling()
        endForegroundVerification()
        client.logout()
        ble.deactivate(clearBinding = true)
        clearAllBluetoothKeys()
        passwordStore.clear()
        hasSavedPassword = false
        session = client.currentSession()
        clearVehicleState()
        LocationNaming.clear()
    }

    suspend fun resetSession() {
        loginEpoch += 1
        stopPolling()
        endForegroundVerification()
        client.resetSession()
        ble.deactivate(clearBinding = true)
        clearAllBluetoothKeys()
        passwordStore.clear()
        hasSavedPassword = false
        session = client.currentSession()
        clearVehicleState()
        LocationNaming.clear()
        show("会话已重置")
    }

    /// 清空车况相关的一切派生显示。写成一个方法是为了别在退登、重置、失效三处各漏一项。
    private fun clearVehicleState() {
        state = null
        lastUpdated = null
        forgetPerVehicleDrafts()
        locationName = null
        locationResolveFailed = false
        didLoadVehiclesThisLaunch = false
        unloadCarModel()
        // 快照也得清。留着的话退登后桌面上那张卡还挂着上一个账号的车名和电量，
        // 而且点下去会一路走到「请先登录」——不如直接变回未同步的样子。
        SnapshotStore.clear()
        WidgetSettings.recordControlError(null)
        scope.launch { LeapSurfaces.reloadAll() }
    }

    /// 换车 / 退登时丢掉只属于上一台车的草稿和回读：冰箱草稿、座舱档位、车上预约。
    /// 留着的话切到另一台车会先看见上一台的冰箱温度和预约时间。
    private fun forgetPerVehicleDrafts() {
        cancelPendingCabinPushes()
        cabinQueue.clear()
        cabinDrafts.clear()
        mirrorHeatingDraft = null
        fridgeDraft = null
        climateAppointmentReadback = null
    }

    /// 退登/重置时把**所有车**的蓝牙钥匙一起清掉。
    ///
    /// 只清当前那台不够：条目是按「账号|VIN」分开存的，退登这一刻手里未必还有完整车辆列表，
    /// 漏掉的那台会在下次登录时留着一把对不上号的旧钥匙。
    private fun clearAllBluetoothKeys() {
        BLEKeyCertificateStore.clearAll()
        BLEVehicleBindingStore.clearAll()
        BLEReconnectTokenStore.clearAll()
    }

    suspend fun selectVehicle(vehicle: Vehicle) {
        // 先把上一台车的连接放掉再切，否则运行时会拿新 VIN 去认旧车。绑定不清——
        // 切回来还要用。
        ble.deactivate(clearBinding = false)
        client.selectVehicle(vehicle.vin, vehicle.carType)
        session = client.currentSession()
        refreshBluetoothRuntime()
        scope.launch { recoverBluetoothCredentialIfNeeded() }
        state = null
        forgetPerVehicleDrafts()
        LocationNaming.clear()
        locationName = null
        locationResolveFailed = false
        // 换车了，上一台的车图 / 3D 资源不能再用。
        unloadCarModel()
        refresh(showSpinner = true)
        loadCarModel()
    }

    fun forgetPassword() {
        passwordStore.clear()
        hasSavedPassword = false
        show("已忘记操作密码")
    }

    // MARK: - 车型标定

    /// 标定用：绕开轮询和 `fetchInFlight` 直接取一份最新车况。
    ///
    /// 标定要自己控制采样节奏——用户点「我做好了」之后得连着刷几次等车上报，
    /// 走 `refresh()` 会被十秒一次的轮询占住。
    suspend fun captureSignalMap(): Map<String, String>? {
        if (isDemo) return null
        return try {
            client.fetchVehicleState().signalMap
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            null
        }
    }

    /// 标定结果落地，并立刻用新映射重解析一次——用户做完就该看见自己车的门窗锁。
    suspend fun applyCalibration(learned: Map<VehicleSignal, String>) {
        if (learned.isEmpty()) return
        LearnedSignals.save(learned, session.selectedCarType)
        state = null
        refresh(showSpinner = true)
        show("已适配 ${learned.size} 项车况")
    }

    /// 忘掉本机标定结果，回到内置映射表。
    suspend fun resetCalibration() {
        LearnedSignals.clear(session.selectedCarType)
        state = null
        refresh(showSpinner = true)
        show("已清除本机标定结果")
    }

    // MARK: - 控车

    /// 统一入口：所有会真正动车的指令都从这里走确认流程。
    fun perform(command: LeapCommand) {
        if (isSendingCommand) return
        DRIVING_BLOCKED_CONTROLS[command.cmdid]?.let { noun ->
            if (state?.isDriving == true) {
                show("行驶中不能操作$noun", isError = true)
                return
            }
        }
        if (isDemo) {
            show("${command.label}指令已发送", detail = "演示模式")
            return
        }
        pendingCommand = command

        if (!command.requiresOperationPassword) {
            scope.launch { dispatch(command, "") }
            return
        }

        // 这次前台已经验证过了，不再打断。回到后台会作废。
        verifiedPassword?.let { verified ->
            scope.launch { dispatch(command, verified) }
            return
        }

        // 已保存密码 + 生物识别可用：用指纹/人脸解锁本地密码，不打断操作。
        val saved = passwordStore.read()
        if (biometricEnabled && biometricKind != BiometricGate.Kind.None && !saved.isNullOrEmpty()) {
            scope.launch {
                if (BiometricGate.authenticate("验证身份以${command.label}")) {
                    verifiedPassword = saved
                    dispatch(command, saved)
                } else {
                    // 识别失败不静默丢弃指令，回退到手输密码。
                    challenge = AuthChallenge.OperationPassword(command.label)
                }
            }
            return
        }

        challenge = AuthChallenge.OperationPassword(command.label)
    }

    /// 充电计划保存：一次连发一批指令（健康充电 480 + 充电计划 190），共用一次操作密码验证。
    ///
    /// 复用 `perform` 的密码流程（前台已验证 / 生物识别 / 手输），只是把「单条」换成「整批」。
    fun performCharge(commands: List<LeapCommand>) {
        if (isSendingCommand || commands.isEmpty()) return
        if (isDemo) {
            show("充电计划已发送", detail = "演示模式")
            return
        }
        // 充电类指令不在行驶禁操作清单里，无需 driving 检查。
        val reason = "保存充电计划"
        verifiedPassword?.let { verified ->
            scope.launch { dispatchBatch(commands, verified) }
            return
        }
        val saved = passwordStore.read()
        if (biometricEnabled && biometricKind != BiometricGate.Kind.None && !saved.isNullOrEmpty()) {
            scope.launch {
                if (BiometricGate.authenticate("验证身份以$reason")) {
                    verifiedPassword = saved
                    dispatchBatch(commands, saved)
                } else {
                    pendingCommand = null
                    pendingChargeBatch = commands
                    challenge = AuthChallenge.OperationPassword(reason)
                }
            }
            return
        }
        pendingCommand = null
        pendingChargeBatch = commands
        challenge = AuthChallenge.OperationPassword(reason)
    }

    /// 顺序下发一批指令，逐条走完整的 `dispatch`（错误提示、诊断、刷新都在里面）。
    private suspend fun dispatchBatch(commands: List<LeapCommand>, password: String) {
        commands.forEach { dispatch(it, password) }
    }

    /// 退到后台时作废本次验证，下次控车要重新过生物识别或密码。
    fun endForegroundVerification() {
        verifiedPassword = null
    }

    /// 用户在密码键盘上输满后调用。
    fun submitOperationPassword(password: String, remember: Boolean) {
        challenge = null
        // 充电计划保存的批量指令优先——一次密码覆盖整批。
        val batch = pendingChargeBatch
        val command = pendingCommand
        if (batch == null && command == null) return
        if (remember) {
            // commit 成功后立刻解密读回。部分 ROM/旧加固包迁移异常时可能出现“文件写了，
            // 但当前密钥读不回”的状态，只看 commit=true 会让界面误报已经记住。
            if (passwordStore.write(password) && passwordStore.read() == password) {
                hasSavedPassword = true
            } else {
                passwordStore.clear()
                hasSavedPassword = false
                // 存不进去就直说，别让用户以为记住了、下次又被要求手输。
                show("密码这次没能记住", detail = "安全存储写入失败")
            }
        }
        // 不管记不记，这次前台内不再重复问。
        verifiedPassword = password
        if (batch != null) {
            pendingChargeBatch = null
            scope.launch { dispatchBatch(batch, password) }
            return
        }
        scope.launch { dispatch(command!!, password) }
    }

    fun cancelChallenge() {
        val wasClimate = pendingCommand?.changesClimate ?: false
        challenge = null
        pendingCommand = null
        pendingChargeBatch = null
        // 用户中途反悔，车没收到任何东西，界面不能停在新设定上，
        // 排队等着补发的那条也一起作废。
        if (wasClimate) {
            climatePushQueued = false
            climateEditedAt = null
            rollbackClimateDraft()
        }
        // 座舱同理：用户在密码框上反悔，车什么都没收到，界面不能停在新档位上。
        // 连队列里排着的那几条（「全部关闭」一次压一批）一起作废。
        cancelPendingCabinPushes()
        cabinQueue.clear()
        cabinDrafts.clear()
        mirrorHeatingDraft = null
        fridgeDraft = null
    }

    private suspend fun dispatch(command: LeapCommand, password: String) {
        isSendingCommand = true
        retryableCommand = null
        try {
            val bleCommand = command.bleCommand
            // 首页控车不能为了“也许马上能连上”的 BLE 阻塞网络下发。蓝牙钥匙在
            // 离车、系统刚恢复进程或 GATT 正重连时可能要等满 6 秒才判定不可用，用户
            // 看起来就是按钮按下后几秒毫无动作。托管连接本来就在后台持续恢复：此刻
            // 已认证就立即走 BLE，否则直接走 HTTP；下次链路就绪后自然仍优先 BLE。
            if (bleCommand != null && bluetoothKeyEligible && ble.canControl) {
                val bleStarted = System.currentTimeMillis()
                fun bleDiagnostic(
                    outcome: ControlDiagnostic.Outcome,
                    body: String,
                    errorMessage: String? = null,
                ) = ControlDiagnostic(
                    label = command.label,
                    cmdid = command.cmdid,
                    msgID = "",
                    sentAt = bleStarted,
                    outcome = outcome,
                    elapsed = (System.currentTimeMillis() - bleStarted) / 1000.0,
                    pollCount = 0,
                    receiptResponses = listOf(ControlDiagnostic.ReceiptSample(0.0, body)),
                    errorMessage = errorMessage,
                )
                when (val result = ble.performControl(bleCommand)) {
                    BLEControlAttemptResult.Confirmed -> {
                        lastReceipt = null
                        if (command.changesClimate) confirmedClimate = currentClimate
                        setDiagnostic(
                            bleDiagnostic(
                                ControlDiagnostic.Outcome.Confirmed,
                                "transport=BLE confirmation=AA_AC",
                            ),
                        )
                        show(successText(command), detail = "蓝牙直连")
                        refresh()
                        // 蓝牙那条路确认在刷新之前，车窗这些得等刷新回来才知道，所以补一句。
                        lockReminder(command)?.let { showReminder(it) }
                        return
                    }

                    // 已经写进去了就不再改走网络——车多半已经动了，再发一遍就是重复下发。
                    BLEControlAttemptResult.SentWithoutConfirmation -> {
                        lastReceipt = null
                        setDiagnostic(
                            bleDiagnostic(
                                ControlDiagnostic.Outcome.SentOnly,
                                "transport=BLE confirmation=timeout",
                            ),
                        )
                        show(
                            "${command.label}已通过蓝牙发送",
                            detail = "未收到车辆动作确认，不会自动重复发送",
                            seconds = 5.0,
                        )
                        refresh()
                        return
                    }

                    is BLEControlAttemptResult.FailedAfterWrite -> {
                        lastReceipt = null
                        setDiagnostic(
                            bleDiagnostic(
                                ControlDiagnostic.Outcome.Failed,
                                "transport=BLE controlFrameStarted=true",
                                result.message,
                            ),
                        )
                        show(
                            "${command.label}结果不确定",
                            detail = "蓝牙指令已经开始写入，未自动改走网络：${result.message}",
                            isError = true,
                            seconds = 6.0,
                        )
                        return
                    }

                    // 只有「根本没发出去」才回退网络远控。
                    is BLEControlAttemptResult.UnavailableBeforeWrite ->
                        DiagLog.note("[ble:route] 控制帧写入前不可用，回退 HTTP：${result.message}")
                }
            }

            val receipt = client.sendControl(command, password)
            lastReceipt = receipt
            // 车已经收到了，这份设定就算数了。
            if (command.changesClimate) confirmedClimate = currentClimate
            confirm(command, receipt)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            // 指令根本没发出去，界面得退回车知道的那份设定。
            if (command.changesClimate) rollbackClimateDraft()
            val message = LeapError.messageOf(e)
            // 密码错误时清掉已保存的密码，否则会一直用错的重试。
            if (message.contains("密码")) {
                passwordStore.clear()
                hasSavedPassword = false
                verifiedPassword = null
            }
            setDiagnostic(
                ControlDiagnostic(
                    label = command.label,
                    cmdid = command.cmdid,
                    msgID = "",
                    sentAt = System.currentTimeMillis(),
                    outcome = ControlDiagnostic.Outcome.Failed,
                    elapsed = 0.0,
                    pollCount = 0,
                    receiptResponses = emptyList(),
                    errorMessage = message,
                ),
            )
            show(e)
        } finally {
            isSendingCommand = false
            pendingCommand = null
            flushQueuedClimatePush()
            flushCabinQueue()
        }
    }

    /// 下发后等车真的动作。
    ///
    /// 服务端是异步执行的，返回 200 只代表受理；实测车辆要 5–10 秒才响应，
    /// 休眠时更久。所以这里**以车况为判据**——车自己报的状态才是真的，
    /// 而回执接口的返回结构至今没有已验证样本。
    ///
    /// 回执照查，但只是攒样本存进诊断信息，不参与判定。
    private suspend fun confirm(command: LeapCommand, receipt: ControlReceipt) {
        val started = System.currentTimeMillis()
        val responses = mutableListOf<ControlDiagnostic.ReceiptSample>()
        var polls = 0

        /// 实测回执恒为 `{"code":0,"result":0,"data":1}`——两次空调指令、共 6 次采样，
        /// 跨越 11 秒、连车况都已经翻转之后，这三个字段一个都没变过。
        /// 也就是说**这个接口不上报执行结果**。继续采样只为一个目的：
        /// 万一指令失败时它会变值，那就是我们要找的失败标志。
        suspend fun sampleReceipt() {
            if (receipt.msgID.isEmpty()) return
            val result = try {
                client.queryControlResult(receipt.msgID)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                return
            }
            responses.add(
                ControlDiagnostic.ReceiptSample(
                    at = (System.currentTimeMillis() - started) / 1000.0,
                    body = result.prettyPrinted,
                ),
            )
        }

        fun finish(outcome: ControlDiagnostic.Outcome) {
            setDiagnostic(
                ControlDiagnostic(
                    label = command.label,
                    cmdid = command.cmdid,
                    msgID = receipt.msgID,
                    sentAt = started,
                    outcome = outcome,
                    elapsed = (System.currentTimeMillis() - started) / 1000.0,
                    pollCount = polls,
                    receiptResponses = responses.toList(),
                    errorMessage = null,
                ),
            )
        }

        if (!command.expectation.isObservable) {
            // 鸣笛这类动作车况里查不到，等一轮刷新就如实说「已发送」，不假称已生效。
            show("${command.label}指令已发送")
            delay(2000)
            refresh()
            if (command.cmdid == "190") refreshChargePlan()
            // 预约空调没有车况信号可确认，下发完回读一次预约表，界面上那行「车上当前预约」
            // 就是确认——读回来对上了才算真的设进去了。
            if (command.cmdid == "171") refreshClimateAppointment()
            sampleReceipt()
            polls = 1
            finish(ControlDiagnostic.Outcome.SentOnly)
            return
        }

        confirmingLabel = command.label
        show("${command.label}指令已发送", detail = "等待车辆响应…", seconds = CONFIRM_TIMEOUT_MS / 1000.0)
        // 后台那个 10 秒轮询会占住 fetchInFlight，把这里的刷新直接跳过，先停掉。
        stopPolling()
        try {
            val deadline = started + CONFIRM_TIMEOUT_MS
            while (System.currentTimeMillis() < deadline) {
                delay(POLL_STEP_MS)
                polls += 1
                refresh()
                sampleReceipt()
                val fresh = state
                if (fresh != null && command.expectation.isSatisfied(fresh)) {
                    val reminder = lockReminder(command)
                    if (reminder != null) showReminder(reminder) else show(successText(command))
                    // 车况已经翻转了，这时候的回执才可能是终态值——恰恰是最该留下的一份样本。
                    sampleReceipt()
                    finish(ControlDiagnostic.Outcome.Confirmed)
                    return
                }
            }

            // 窗口内没等到。不自动重发——尾门、鸣笛重发会真的再动一次车。
            retryableCommand = command
            show(
                "${command.label}未收到车辆确认",
                detail = "车可能仍在唤醒，可稍后重试",
                isError = true,
                showsRetry = true,
                seconds = 10.0,
            )
            finish(ControlDiagnostic.Outcome.TimedOut)
        } finally {
            confirmingLabel = null
            startPolling()
        }
    }

    private fun setDiagnostic(diagnostic: ControlDiagnostic?) {
        lastDiagnostic = diagnostic
        ControlDiagnosticStore.save(diagnostic)
    }

    private fun successText(command: LeapCommand): String {
        val expectation = command.expectation
        return when (expectation.kind) {
            ExpectationKind.Locked ->
                if (expectation.boolValue) "车辆已上锁" else "车辆已解锁"
            ExpectationKind.Climate ->
                if (expectation.climateOn) "空调已开启" else "空调已关闭"
            ExpectationKind.WindowPosition -> "车窗已调整"
            ExpectationKind.TrunkOpen ->
                if (expectation.boolValue) "尾门已打开" else "尾门已关闭"
            ExpectationKind.FrontTrunkOpen ->
                if (expectation.boolValue) "前备箱已打开" else "前备箱已关闭"
            ExpectationKind.Sentinel ->
                if (expectation.boolValue) "哨兵已开启" else "哨兵已关闭"
            ExpectationKind.SunshadeOpen ->
                if (expectation.boolValue) "遮阳帘已打开" else "遮阳帘已关闭"
            ExpectationKind.SunroofOpen ->
                if (expectation.boolValue) "天窗已打开" else "天窗已关闭"
            ExpectationKind.Charging ->
                if (expectation.boolValue) "已开始充电" else "已停止充电"
            // 这几条的 label 本身就把位置和档位说全了（「主驾加热 2 档」），再套一层话术反而更绕。
            ExpectationKind.SeatLevel, ExpectationKind.SteeringWheelLevel -> "${command.label}已生效"
            ExpectationKind.MirrorHeating ->
                if (expectation.boolValue) "后视镜加热已开启" else "后视镜加热已关闭"
            ExpectationKind.Fridge ->
                if (expectation.fridgeSetting?.enabled == true) "${command.label}已生效" else "车载冰箱已关闭"
            ExpectationKind.Unobservable -> "${command.label}已完成"
        }
    }

    /// 锁车成功但还有东西开着时，把成功提示换成一句提醒（leapauto 的「锁车后检查」，同 iOS）。
    ///
    /// 用的是确认轮询刚刷回来的那份车况，不额外发请求。只看读得到的项，见 `VehicleState.openItemsAfterLock`。
    /// 锁本身是成功的，所以文案先说「已上锁」；用告警色和多停几秒，是因为这句是要人回去处理的。
    private fun lockReminder(command: LeapCommand): Pair<String, String>? {
        val expectation = command.expectation
        if (expectation.kind != ExpectationKind.Locked || !expectation.boolValue) return null
        val items = state?.openItemsAfterLock.orEmpty()
        if (items.isEmpty()) return null
        return "车辆已上锁" to "${items.joinToString("、")}还开着"
    }

    private fun showReminder(reminder: Pair<String, String>) {
        show(reminder.first, detail = reminder.second, isError = true, seconds = 6.0)
    }

    /// 超时提示上的重试。走完整的 perform 流程，该验身份还是要验。
    fun retryLastCommand() {
        val command = retryableCommand ?: return
        retryableCommand = null
        toast = null
        perform(command)
    }

    // MARK: - 具体动作

    fun toggleLock() {
        val locked = state?.isLocked ?: true
        perform(if (locked) LeapCommand.unlock() else LeapCommand.lock())
    }

    fun setLocked(locked: Boolean) = perform(if (locked) LeapCommand.lock() else LeapCommand.unlock())

    /// 首页控车条的「上锁」「解锁」两格：方向写在按钮上，不看车况猜。
    fun lockCar() = perform(LeapCommand.lock())

    fun unlockCar() = perform(LeapCommand.unlock())

    /// 尾门开着就发关闭，否则发打开。读不到状态时按「开」走。
    ///
    /// 控车条上的尾门按钮已经改成先开弹窗、由用户挑开还是关，
    /// 这条只剩卡片/磁贴那条路径在用——那边没有界面可弹，只能替用户判一次方向。
    fun toggleTrunk() {
        // 关不了的车型（S01 / T03）只发得出「打开」。尾门开着时照着反转发一条关闭，
        // 车根本不会理，用户看到的是「按了什么都没发生」。
        if (!LeapCommand.trunkSupportsClose(session.selectedCarType)) {
            setTrunk(true)
            return
        }
        setTrunk(!(state?.trunkOpen ?: false))
    }

    fun setTrunk(open: Boolean) = perform(LeapCommand.trunk(open))

    /// 车报着开度就等信号翻转确认，不报就照旧只说「已发送」（见 `LeapCommand.sunshade` 的说明）。
    fun setSunshade(open: Boolean) =
        perform(LeapCommand.sunshade(open, observable = state?.sunshadeOpen != null))

    fun setSunroof(open: Boolean) =
        perform(LeapCommand.sunroof(open, observable = state?.sunroofOpen != null))

    /// 远程开始 / 停止充电。按钮只在插着枪时出现（见 `ChargeScreen`），这里不重复判。
    fun setCharging(start: Boolean) = perform(LeapCommand.charging(start))

    fun unlockChargingGun() = perform(LeapCommand.unlockChargingGun())

    fun setFrunk(open: Boolean) = perform(LeapCommand.frunk(open))

    fun honk() = perform(LeapCommand.horn())

    fun preheatBattery() = perform(LeapCommand.batteryPreheat(true))

    fun stopBatteryPreheat() = perform(LeapCommand.batteryPreheat(false))

    fun scheduleBatteryPreheat(startTime: Long, enabled: Boolean, days: List<Int> = listOf(1, 2, 3, 4, 5)) {
        // set_id 实测格式是「前缀_VIN_创建毫秒」，VIN 从当前选中车取。
        perform(LeapCommand.batteryPreheatAppointment(enabled, startTime, days, session.selectedVin))
    }

    /// 保存充电计划：充电上限 + 预约充电走 cmdid 190；若这次改了健康充电开关，再连发 cmdid 480。
    ///
    /// @param healthyChargeOn 传 null 表示这次没动健康充电开关，不下发 480。
    fun saveChargePlan(
        limitPercent: Int,
        scheduledEnabled: Boolean,
        startTime: String,
        endTime: String,
        cycles: List<Boolean>,
        circulation: Int,
        recharge: Int,
        healthyChargeOn: Boolean?,
    ) {
        val commands = buildList {
            // 先发健康充电：它决定上限封顶，先落定约束再发上限更稳妥。
            healthyChargeOn?.let { add(LeapCommand.healthyCharge(it)) }
            add(
                LeapCommand.chargePlan(
                    limitPercent = limitPercent,
                    scheduledEnabled = scheduledEnabled,
                    startTime = startTime,
                    endTime = endTime,
                    cycles = cycles,
                    circulation = circulation,
                    recharge = recharge,
                ),
            )
        }
        performCharge(commands)
    }

    /// `openness` 是开度百分比：0 关闭、100 全开。
    fun applyWindows(openness: Int) =
        perform(LeapCommand.window(openness, session.selectedCarType))

    /// 哨兵模式开关。没有本地草稿位——界面直接读车况的 `sentinelOn`，不做乐观翻转。
    fun applySentinel(on: Boolean) = perform(LeapCommand.sentinel(on))

    fun applyClimate(on: Boolean) {
        climateOn = on
        noteClimateEdit()
        perform(
            LeapCommand.climate(
                on = on,
                temperature = climateTemperature,
                fanLevel = climateFanLevel,
                mode = climateMode,
                circleIn = climateCircleIn,
                windshield = false,
            ),
        )
    }

    /// 空调已开时改参数才即时下发，关着的时候只改本地草稿。
    fun pushClimateIfRunning() {
        if (!climateOn) return
        // 上一条还在等车确认——那是个最长几十秒的窗口，`perform` 会把这条直接丢掉，
        // 用户就得再按一次，反馈出来正是「每次都要按两次」。记下来，等这条完事补发最新的。
        if (isSendingCommand) {
            climatePushQueued = true
            return
        }
        applyClimate(true)
    }

    /// 补发那条被压下的空调指令，用的是用户最后调到的值。
    private fun flushQueuedClimatePush() {
        if (!climatePushQueued) return
        climatePushQueued = false
        if (!climateOn || isDemo) return
        scope.launch { pushClimateIfRunning() }
    }

    fun quickCool() {
        updateClimateMode(ClimateMode.Cold)
        updateClimateTemperature(18)
        updateClimateFanLevel(7)
        climateOn = true
        perform(LeapCommand.quickCool())
    }

    fun quickHeat() {
        updateClimateMode(ClimateMode.Hot)
        updateClimateTemperature(32)
        updateClimateFanLevel(7)
        climateOn = true
        perform(LeapCommand.quickHeat())
    }

    fun defrost() {
        climateOn = true
        noteClimateEdit()
        perform(LeapCommand.defrost())
    }

    /// 快速除味：通风 + 外循环 + 7 档。草稿跟着改，免得页面上还停在原来的制冷 / 内循环。
    /// 温度草稿不动：通风模式下温度不起作用，车端会不会改设定温度也没验过，等车况回来再同步。
    fun deodorize() {
        updateClimateMode(ClimateMode.Vent)
        updateClimateFanLevel(7)
        updateClimateCircleIn(false)
        climateOn = true
        perform(LeapCommand.deodorize())
    }

    // MARK: - 预约空调

    /// 车上预约空调的回读结果。`null` 是还没读过。
    sealed class AppointmentReadback {
        data object Loading : AppointmentReadback()

        /// 车上没有预约（回读到空 `controls`，或者里面没有开着的项）。
        data object Empty : AppointmentReadback()

        data class Loaded(val appointment: ClimateAppointment) : AppointmentReadback()

        /// 读不到。和 [Empty] 必须分开说：读不到不等于没有。
        data class Failed(val message: String) : AppointmentReadback()
    }

    var climateAppointmentReadback by mutableStateOf<AppointmentReadback?>(null)
        private set

    suspend fun refreshClimateAppointment() {
        if (isDemo) {
            climateAppointmentReadback = AppointmentReadback.Empty
            return
        }
        // 已经有结果时不把界面闪回「读取中」，只在第一次读时给转圈。
        if (climateAppointmentReadback == null) climateAppointmentReadback = AppointmentReadback.Loading
        climateAppointmentReadback = try {
            val controls = client.fetchAppointmentControls("171")
            ClimateAppointment.parse(controls)?.let { AppointmentReadback.Loaded(it) } ?: AppointmentReadback.Empty
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            AppointmentReadback.Failed(LeapError.messageOf(e))
        }
    }

    /// 保存预约。改的是车上已有的那条时沿用它的 `set_id`（调用方从回读里带过来）。
    fun saveClimateAppointment(appointment: ClimateAppointment) =
        perform(ClimateAppointment.command(appointment, session.selectedVin))

    fun cancelClimateAppointment() = perform(ClimateAppointment.cancelCommand())

    // MARK: - 舒适座舱

    /// 座椅 / 方向盘档位的本机草稿。只活在「用户点了」到「这条指令跑完」之间：
    /// 跑完之后由 [clearCabinDraftsIfSettled] 清掉，界面落回车况报的真值——
    /// 成功就是新档位，失败就是原档位，不需要单独写一套回滚。
    private val cabinDrafts = mutableStateMapOf<String, Int>()

    private var mirrorHeatingDraft by mutableStateOf<Boolean?>(null)

    /// 冰箱草稿。进页面时从车况播种（见 [seedFridgeDraft]），之后由界面直接改。
    var fridgeDraft by mutableStateOf<FridgeSetting?>(null)

    /// 每个「座位 + 通道」各一个防抖任务。**不能共用一个**：共用的话
    /// 「主驾调到 3 档后马上点副驾」会把主驾那条取消掉，用户看到的是主驾白点一遍。
    private val cabinPushJobs = mutableMapOf<String, Job>()

    /// `perform` 是单航道的——上一条还在等车确认时它会把新指令直接丢掉。
    /// 座舱这页一次能点出好几条（四个座位，还有「全部关闭」一次发一批），
    /// 丢掉就等于用户点了没反应，所以压进队列，等上一条跑完再接着发。
    private val cabinQueue = ArrayDeque<LeapCommand>()

    private fun cabinKey(position: SeatPosition, channel: SeatComfortChannel) = "${channel.name}|${position.name}"

    /// 界面读的档位：草稿优先，没有草稿就读车况。车况也读不到返回 null——
    /// 那是「这车没这个座位」，界面该整块隐藏，不是显示 0 档。
    fun seatLevel(position: SeatPosition, channel: SeatComfortChannel): Int? =
        cabinDrafts[cabinKey(position, channel)] ?: state?.seatLevel(position, channel)

    val steeringWheelLevel: Int?
        get() = cabinDrafts[STEERING_WHEEL_KEY] ?: state?.steeringWheelHeatLevel

    val mirrorHeatingOn: Boolean? get() = mirrorHeatingDraft ?: state?.mirrorHeatingOn

    /// 方向盘加热剩余分钟。**只在车况报着加热开着时才有值**——草稿不参与，
    /// 因为剩余分钟是车端算的，本机刚点的那一档还没生效时没有对应的分钟数。
    val steeringWheelHeatMinutes: Int? get() = state?.steeringWheelHeatMinutes

    /// 轻点座位：`0 → 1 → 2 → 3 → 0` 循环。读不到档位的座位界面上本来就不画，点不到。
    fun cycleSeat(position: SeatPosition, channel: SeatComfortChannel) {
        val current = seatLevel(position, channel) ?: return
        setSeat(position, channel, (current + 1) % (channel.maxLevel + 1))
    }

    fun setSeat(position: SeatPosition, channel: SeatComfortChannel, level: Int) {
        val key = cabinKey(position, channel)
        cabinDrafts[key] = level.coerceIn(0, channel.maxLevel)
        scheduleCabinPush(key) {
            val target = cabinDrafts[key] ?: return@scheduleCabinPush
            enqueueCabin(CabinCommands.seatComfort(position, channel, target))
        }
    }

    /// 方向盘加热：`0 → 1 → 2 → 0`，**两档**，和座椅不是一套量程。
    fun setSteeringWheelHeat(level: Int) {
        cabinDrafts[STEERING_WHEEL_KEY] = level.coerceIn(0, 2)
        scheduleCabinPush(STEERING_WHEEL_KEY) {
            val target = cabinDrafts[STEERING_WHEEL_KEY] ?: return@scheduleCabinPush
            enqueueCabin(CabinCommands.steeringWheelHeating(target))
        }
    }

    /// 后视镜加热只有开 / 关两态，没有连点加档的场景，不走防抖，点了就发。
    fun toggleMirrorHeating() {
        val next = !(mirrorHeatingOn ?: false)
        mirrorHeatingDraft = next
        enqueueCabin(CabinCommands.mirrorHeating(next))
    }

    /// 「全部关闭」：把当前**确实不为 0** 的项逐条发 0。
    ///
    /// 只发不为 0 的那几条：读不到档位的项（这车没这个座位）不该发，已经是 0 的项
    /// 再发一遍纯粹是多一次远控请求和一次等车确认。
    fun closeAllCabinComfort() {
        val commands = mutableListOf<LeapCommand>()
        for (channel in SeatComfortChannel.entries) {
            for (position in SeatPosition.entries) {
                val level = seatLevel(position, channel) ?: continue
                if (level <= 0) continue
                cabinDrafts[cabinKey(position, channel)] = 0
                commands.add(CabinCommands.seatComfort(position, channel, 0))
            }
        }
        if ((steeringWheelLevel ?: 0) > 0) {
            cabinDrafts[STEERING_WHEEL_KEY] = 0
            commands.add(CabinCommands.steeringWheelHeating(0))
        }
        if (mirrorHeatingOn == true) {
            mirrorHeatingDraft = false
            commands.add(CabinCommands.mirrorHeating(false))
        }
        if (commands.isEmpty()) {
            show("座舱加热与通风都已关闭")
            return
        }
        commands.forEach { enqueueCabin(it) }
    }

    /// 冰箱：电源键点了就发；其余设定项改完走防抖，和空调页调温度一个节奏。
    fun setFridgePower(on: Boolean) {
        val setting = (fridgeDraft ?: state?.fridgeState?.asSetting ?: FridgeSetting()).copy(enabled = on)
        fridgeDraft = setting
        enqueueCabin(CabinCommands.fridge(setting))
    }

    fun pushFridgeDraft() {
        val setting = fridgeDraft ?: return
        if (!setting.enabled) return
        scheduleCabinPush(FRIDGE_KEY) {
            val latest = fridgeDraft ?: return@scheduleCabinPush
            enqueueCabin(CabinCommands.fridge(latest))
        }
    }

    /// 进冰箱页时把车况里的设定搬进草稿。已经有草稿就不动——
    /// 那是用户正在调的东西，被轮询回来的车况冲掉就是「调了弹回去」。
    fun seedFridgeDraft() {
        if (fridgeDraft != null) return
        fridgeDraft = state?.fridgeState?.asSetting
    }

    private fun scheduleCabinPush(key: String, send: () -> Unit) {
        cabinPushJobs.remove(key)?.cancel()
        cabinPushJobs[key] = scope.launch {
            delay(CABIN_PUSH_DELAY_MS)
            cabinPushJobs.remove(key)
            send()
        }
    }

    /// 单航道被占着就排队，空着就直接发。
    private fun enqueueCabin(command: LeapCommand) {
        if (isSendingCommand || pendingCommand != null) {
            cabinQueue.addLast(command)
            return
        }
        perform(command)
    }

    /// 上一条跑完后接着发队列里的下一条。
    private fun flushCabinQueue() {
        val next = cabinQueue.removeFirstOrNull() ?: return
        scope.launch { perform(next) }
    }

    /// 车况回来时清掉已经尘埃落定的草稿。
    ///
    /// 「尘埃落定」= 没有待发的防抖任务、队列空了、也没有指令在飞或在等密码。
    /// 清掉之后界面读的就是车报的真值：成功显示新档位，失败显示原档位。
    private fun clearCabinDraftsIfSettled() {
        if (cabinPushJobs.isNotEmpty() || cabinQueue.isNotEmpty() || isSendingCommand || pendingCommand != null) return
        if (cabinDrafts.isNotEmpty()) cabinDrafts.clear()
        mirrorHeatingDraft = null
    }

    /// 离开座舱页时取消还没发出去的那几条。空调页离开时同理。
    fun cancelPendingCabinPushes() {
        cabinPushJobs.values.forEach { it.cancel() }
        cabinPushJobs.clear()
    }

    // MARK: - 提示

    fun show(
        text: String,
        detail: String? = null,
        isError: Boolean = false,
        showsRetry: Boolean = false,
        seconds: Double = 3.0,
    ) {
        toastSequence += 1
        toast = ToastMessage(toastSequence, text, detail, isError, showsRetry, seconds)
    }

    fun show(error: Throwable) {
        val message = LeapError.messageOf(error)
        if ((error as? LeapError)?.kind == LeapErrorKind.NeedsRelogin) {
            // 故意**不**走 `expireSession`：那条路会把蓝牙钥匙证书和绑定一起清掉，
            // 而这个状态未必是登录态没了——多半是本机的设备号跟服务端记的那个对不上，
            // 车况照常刷新、新网关一切正常，只有老链路（远控/里程/位置）全废。
            //
            // 但也不能继续说「请稍后重试」——重试一万次都不会好。把话说明白，
            // 什么时候去重登由用户自己决定。停久一点，这条比普通失败重要。
            show(
                "控车授权已失效",
                detail = "重试无法恢复，请到「我的」退出登录后重新登录",
                isError = true,
                seconds = 8.0,
            )
            AuthAuditLog.note("已提示用户重新登录（老链路持续 result=39）")
            return
        }
        toastSequence += 1
        toast = ToastMessage(toastSequence, message, isError = true)
        if ((error as? LeapError)?.kind == LeapErrorKind.SessionExpired) {
            scope.launch { expireSession("某次请求判定登录失效：$message") }
        }
    }

    /// 最近一次主动校验登录态的时间。频繁切前后台时用它节流，别每次都打老链路。
    private var lastSessionValidation: Long? = null

    /// 主动确认登录态还在——开 App、回到前台时调用。
    ///
    /// 为什么要单独探：车况刷新走新网关读取 token，被挤下线后它仍活着，刷新永远发现
    /// 不了；真正会死的是老链路控车 token（详见 `LeapClient.validateSession`）。
    ///
    /// 两层节流：这里 30 秒内探过就跳过，挡住频繁切前后台；`LeapClient` 那边再看一次
    /// 老 token 有多新，刚换发过就直接认有效、连请求都不发。
    ///
    /// 返回 false 表示已判定失效并开始回登录页；true 表示有效或无法判定（按有效处理）。
    suspend fun validateSession(force: Boolean = false): Boolean {
        if (!session.isLoggedIn || isDemo) return true
        val last = lastSessionValidation
        if (!force && last != null && System.currentTimeMillis() - last < 30_000) return true
        lastSessionValidation = System.currentTimeMillis()
        return try {
            client.validateSession()
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            if ((e as? LeapError)?.kind == LeapErrorKind.SessionExpired) {
                // 直接 await 处理失效，让调用方拿到确定的登录状态，不留竞态。
                show("登录已过期", detail = "请重新登录", isError = true)
                expireSession("前台探活：老链路续期被服务端拒绝")
                false
            } else {
                // 网络等其它错误：判不了，按有效继续，别打扰也别误踢。
                true
            }
        }
    }

    /// 服务端明确说登录态失效时退回登录页。留在首页只会不停弹同一条错误，
    /// 而用户根本没有入口重新登录。
    ///
    /// 操作密码不清：同一个账号重新登录后还是那一个，重新走一遍短信验证已经够验证身份了。
    private suspend fun expireSession(reason: String) {
        // 守卫不能只看界面这份 session。它是 client 那份的拷贝，而且只在成功路径上同步：
        // `login()` 中途失败时界面这份还停在登录前的空态，client 内部却可能攥着半截凭证。
        // 只看 `isLoggedIn` 就会在这里直接 return，那份脏凭证于是永远清不掉。
        val live = client.currentSession()
        if (!session.isLoggedIn && !live.hasAnyCredential) return
        AuthAuditLog.note("清会话回登录页。$reason")
        stopPolling()
        endForegroundVerification()
        client.logout()
        session = client.currentSession()
        clearVehicleState()
        LocationNaming.clear()
        challenge = null
        pendingCommand = null
    }

    /// 诊断页要看的原始车况。演示态也给——审核员点进去不该是一片空白。
    fun diagnosticSignalMap(): Map<String, String> = state?.signalMap ?: emptyMap()
}
