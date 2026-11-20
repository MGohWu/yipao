package org.yipao.app.app

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.core.content.ContextCompat
import org.yipao.app.core.AppEnv
import org.yipao.app.core.BLEConfigurationSyncState
import org.yipao.app.core.BLEKeyCertificateStore
import org.yipao.app.core.BLEPairingHistory
import org.yipao.app.core.BLEReconnectTokenStore
import org.yipao.app.core.BLETrace
import org.yipao.app.core.BLEVehicleBinding
import org.yipao.app.core.BLEVehicleBindingStore
import org.yipao.app.core.DiagLog
import org.yipao.app.core.LeapBLEConfiguration
import org.yipao.app.core.LeapBLEControlCommand
import org.yipao.app.core.LeapBLECryptoSession
import org.yipao.app.core.LeapBLEDecryptedResponse
import org.yipao.app.core.LeapBLEEvent
import org.yipao.app.core.LeapBLEFrame
import org.yipao.app.core.LeapBLEFrameKind
import org.yipao.app.core.LeapBLEFrameReassembler
import org.yipao.app.core.LeapBLEKeyCertificate
import org.yipao.app.core.LeapBLEProtocol
import org.yipao.app.core.LeapCrypto
import org.yipao.app.core.LeapError
import org.yipao.app.core.StraightMoveDirection
import org.yipao.app.core.StraightMoveOrder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import java.util.UUID

/// 蓝牙钥匙的运行时。对齐 iOS `BLEVehicleController`（那边叫 BLEDiagnosticManager）。
///
/// **和 iOS 的差异，都是平台决定的，不是漏做：**
/// - iOS 靠 `CBCentralManager` 的状态恢复在后台被系统拉起继续武装；安卓换成前台服务
///   （`BLEKeyForegroundService`）加常驻通知，效果一样但用户看得见那条通知。
/// - iOS 用不透明的 peripheral UUID 找车，安卓直接存 MAC，重连不用先扫描。
/// - 分片节奏：iOS 用 `canSendWriteWithoutResponse` 探流控，安卓的 GATT 队列本身是串行的，
///   一律等 `onCharacteristicWrite` 回来再发下一片，两种写类型都适用。
///
/// 线程：所有状态只在主线程改。GATT 回调来自 binder 线程，一律先 `scope.launch` 回主线程，
/// 否则 Compose 读到的状态会撕裂。
@SuppressLint("MissingPermission")
class BLEVehicleController private constructor() {

    companion object {
        val shared: BLEVehicleController by lazy { BLEVehicleController() }

        private val SERVICE_UUID: UUID = UUID.fromString(LeapBLEProtocol.SERVICE_UUID)
        private val CHARACTERISTIC_UUID: UUID = UUID.fromString(LeapBLEProtocol.CHARACTERISTIC_UUID)
        private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /// 官方安卓栈协商 MTU 200，单次 ATT 载荷 197。即使系统给出更大值也按实车值分片。
        private const val REQUESTED_MTU = 200
        private const val MAX_CHUNK = 197

        private const val PAIRING_SCAN_TIMEOUT_MS = 20_000L
        private const val PAIRING_CONNECT_TIMEOUT_MS = 20_000L
        private const val AUTH_TIMEOUT_MS = 10_000L
        private const val CONFIG_TIMEOUT_MS = 8_000L
        private const val CONTROL_TIMEOUT_MS = 8_000L

        /// MTU 协商回调迟到多久算不正常。实测几百毫秒内就回来，取 3 秒是把
        /// 「排在别的 GATT 操作后面」和「压根不会回来」分开——超过它就按后者兜底。
        private const val MTU_WATCHDOG_MS = 3_000L

        /// 补救性重连前等多久。`close()` 之后底层还要一小会儿才真正释放 GATT 句柄，
        /// 紧接着 `connectGatt` 会直接失败。鸿蒙那边取的也是这个量级。
        private const val RELINK_DELAY_MS = 400L
    }

    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())

    // MARK: - 对外状态

    var runtimeState by mutableStateOf<BLERuntimeState>(BLERuntimeState.Unbound)
        private set

    var pairingState by mutableStateOf<BLEPairingState>(BLEPairingState.Idle)
        private set

    var linkState by mutableStateOf(BLELinkState.Idle)
        private set

    var authenticationState by mutableStateOf(BLEAuthenticationState.MissingCertificate)
        private set

    var authenticationError by mutableStateOf<String?>(null)
        private set

    var binding by mutableStateOf<BLEVehicleBinding?>(null)
        private set

    var reconnectTokenAvailable by mutableStateOf(false)
        private set

    var isScanning by mutableStateOf(false)
        private set

    /// 直进直出。与蓝牙钥匙共用同一条 GATT 连接，不另开扫描或连接。
    var straightMoveState by mutableStateOf<BLEStraightMoveState>(BLEStraightMoveState.Idle)
        private set

    val devices = mutableStateListOf<BLEDiscoveredDevice>()

    /// 已完成认证且没有别的帧在飞，可以下发控制。
    val canControl: Boolean
        get() = authenticationState == BLEAuthenticationState.Authenticated &&
            cryptoSession != null &&
            characteristic != null

    val hasPairedBefore: Boolean
        get() = context?.let { BLEPairingHistory.hasPaired(it.accountId, it.vin) } ?: false

    // MARK: - 依赖与内部状态

    val callCar = CallCarController()
    private var context: BLECredentialContext? = null
    private var productionEligible = false

    private var gatt: BluetoothGatt? = null
    private var characteristic: BluetoothGattCharacteristic? = null
    private var connectedAddress: String? = null
    private var connectedDeviceName: String? = null
    private var connectionIntent: ConnectionIntent = ConnectionIntent.Managed
    private var mtu = 23

    /// 扫描时看到的广播资料，按地址存。`devices` 是给界面列表用的，只留看得见的那几项；
    /// 排查连错设备要的 connectable、广播服务这些不该塞进 UI 模型，单独留一份。
    private val advertisements = mutableMapOf<String, Advertisement>()

    /// 已经记过 DISCOVER 的广播签名。rssi 每秒都在跳，跟着打日志会把缓冲冲没，
    /// 只有名字、可连接性、带没带 FFFE 变了才值得再记一条。
    private val loggedAdvertisementSignatures = mutableMapOf<String, String>()

    /// 各阶段起点，用来量耗时——「卡了多久」比「失败了」有用得多。
    private var connectStartedAt: Long? = null
    private var mtuStartedAt: Long? = null
    private var discoveryStartedAt: Long? = null
    private var subscribeStartedAt: Long? = null

    /// 是我们自己关的连接。用来把「主动断开」和「掉线」分开：只有后者才值得回溯时序。
    private var closingIntentionally = false

    /// 这台设备已经为了建链卡住重连过一次。防的是「连上→卡住→重连→又卡住」转圈。
    private var relinkedOnce = false

    /// 下一轮连接跳过主动 MTU 协商。上一轮等不到 `onMtuChanged` 时置起——
    /// 同一条路再走一遍多半还是同样的结果，不如按 mtu=23 先把服务发现跑完。
    /// 一次性：用掉就清，别让后面每一轮连接都白白丢掉大 MTU。
    private var skipMtuNegotiation = false

    /// 补救性重连的定时器。归 controller 持有，是为了让用户在这 400 ms 里
    /// 取消配对、切车或关蓝牙时，能把已经作废的那次重连掐掉。
    private var linkRetryJob: Job? = null

    /// 当前这条链路当初是用哪种 `autoConnect` 发起的，重连时照搬。
    private var lastConnectAutoConnect = false

    private var cryptoSession: LeapBLECryptoSession? = null
    private var authenticationMode: AuthenticationMode? = null
    private var reconnectToken: String? = null
    private var pendingFullAuthenticationFallback = false

    private val reassembler = LeapBLEFrameReassembler()

    private var transmissionPurpose: TransmissionPurpose? = null
    private var transmissionChunks: List<ByteArray> = emptyList()
    private var nextChunk = 0

    private var pendingControlLabel: String? = null
    private var activeControlAttempt: ControlAttempt? = null
    private var completedControlAttempt: Pair<Long, BLEControlAttemptResult>? = null
    private var configurationInFlight: LeapBLEConfiguration? = null

    private var responseTimeoutJob: Job? = null
    private var pairingTimeoutJob: Job? = null
    private var attemptSequence = 0L

    private var straightMoveHeartbeatJob: Job? = null
    private var straightMoveWatchdogJob: Job? = null
    private var straightMoveStopJob: Job? = null
    private var pendingStraightMoveOrder: StraightMoveOrder? = null
    /// 用 `elapsedRealtime` 而不是 `currentTimeMillis`：看门狗量的是「上一帧发出去多久了」，
    /// 系统对时或用户改时间会让墙钟往回跳，那会让看门狗要么永不触发、要么立刻误停。
    private var lastStraightMoveTransmissionAt: Long? = null

    /// App 是否在前台。直进直出全程要求前台——那是「按住才动」的安全前提，
    /// 前台服务保住的是无感钥匙的连接，不是让人能在锁屏下遥控车辆移动。
    private var applicationIsActive = true

    private val adapter: BluetoothAdapter?
        get() = (AppEnv.context.getSystemService(BluetoothManager::class.java))?.adapter

    init {
        // binding 在配对成功、开关切换、设置同步完成、解绑四条路径上都会变，
        // 与其在每处补一行起停服务，不如直接盯着快照状态本身。
        scope.launch {
            snapshotFlow { binding?.shouldMaintainConnection == true }
                .distinctUntilChanged()
                .collect { syncBackgroundService() }
        }
    }

    private class ControlAttempt(val id: Long, var didStartWrite: Boolean)

    /// 一台设备在这一轮扫描里露出来的广播内容。
    private class Advertisement(
        val rssi: Int,
        val isConnectable: Boolean,
        val advertisesTargetService: Boolean,
        val serviceUUIDs: String,
    )

    private enum class ConnectionIntent { Pairing, Managed }

    private enum class AuthenticationMode(val label: String) {
        Full("完整认证"),
        Reconnect("快速重连"),
    }

    private sealed class TransmissionPurpose(val label: String) {
        class Authentication(val mode: AuthenticationMode) : TransmissionPurpose(mode.label)
        data object Configuration : TransmissionPurpose("钥匙设置")
        class Control(val command: LeapBLEControlCommand, val attemptID: Long?) :
            TransmissionPurpose(command.label)
        class StraightMove(val order: StraightMoveOrder) : TransmissionPurpose(order.label)
    }

    // MARK: - 权限与系统蓝牙

    val hasScanPermission: Boolean get() = granted(Manifest.permission.BLUETOOTH_SCAN)

    val hasConnectPermission: Boolean get() = granted(Manifest.permission.BLUETOOTH_CONNECT)

    val hasBluetoothPermission: Boolean get() = hasScanPermission && hasConnectPermission

    val bluetoothEnabled: Boolean get() = adapter?.isEnabled == true

    val bluetoothSupported: Boolean
        get() = AppEnv.context.packageManager
            .hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(AppEnv.context, permission) ==
            PackageManager.PERMISSION_GRANTED

    // MARK: - 后台常驻

    /// 是否需要前台服务替我们守着这条 GATT 连接。没绑定、没资格、没连接权限都不需要——
    /// 那种情况下挂一条常驻通知只是白占状态栏。
    val wantsBackgroundArming: Boolean
        get() = productionEligible &&
            binding?.shouldMaintainConnection == true &&
            hasConnectPermission

    private fun syncBackgroundService() = BLEKeyForegroundService.sync()

    /// App 前后台切换。前台服务保的是无感钥匙，直进直出仍旧只在前台可用。
    fun setApplicationActive(active: Boolean) {
        callCar.setApplicationActive(active)
        applicationIsActive = active
        if (!active) {
            if (straightMoveState.isPrepared) emergencyStopStraightMove("App 已离开前台")
            // 后台扫描会被系统限频到几乎不出结果，与其让用户对着空列表等，不如直接收。
            if (pairingState == BLEPairingState.Scanning) cancelPairing()
        } else {
            ensureManagedConnection()
        }
    }

    // MARK: - 装配

    /// 账号 / 车辆 / 证书任何一项变了都要重新调一次。传 null 的证书表示还没同步到。
    fun configure(
        accountId: String,
        deviceId: String,
        vin: String,
        certificate: LeapBLEKeyCertificate?,
    ) {
        productionEligible = accountId.isNotEmpty() && vin.isNotEmpty()

        val next = certificate?.let {
            BLECredentialContext(it, accountId, deviceId, vin)
        }
        callCar.configure(next)
        val changed = next?.certificate?.fingerprint != context?.certificate?.fingerprint ||
            next?.vin != context?.vin ||
            next?.accountId != context?.accountId
        context = next

        if (!productionEligible) {
            runtimeState = BLERuntimeState.Unbound
            authenticationState = BLEAuthenticationState.MissingCertificate
            return
        }
        if (next == null) {
            binding = BLEVehicleBindingStore.load(accountId, vin)
            authenticationState = BLEAuthenticationState.MissingCertificate
            runtimeState = if (binding == null) BLERuntimeState.Unbound else BLERuntimeState.Recovering
            return
        }

        if (changed) {
            stopManagedConnection()
            authenticationState = BLEAuthenticationState.Prepared
        }
        binding = BLEVehicleBindingStore.load(accountId, vin)
        reconnectToken = BLEReconnectTokenStore.load(accountId, vin)
        reconnectTokenAvailable = reconnectToken != null
        runtimeState = when {
            binding == null -> BLERuntimeState.Unbound
            binding?.isBluetoothControlEnabled != true -> BLERuntimeState.Disabled
            else -> BLERuntimeState.Recovering
        }
        ensureManagedConnection()
        syncBackgroundService()
    }

    /// 退登 / 换账号。绑定、证书、重连凭证一起清——账号都换了，钥匙不能留。
    fun deactivate(clearBinding: Boolean) {
        pairingTimeoutJob?.cancel()
        pairingTimeoutJob = null
        stopScan()
        productionEligible = false
        stopManagedConnection()
        val current = context
        if (clearBinding && current != null) {
            BLEVehicleBindingStore.clear(current.accountId, current.vin)
            BLEReconnectTokenStore.clear(current.accountId, current.vin)
            BLEKeyCertificateStore.clear(current.accountId, current.vin)
        }
        context = null
        binding = null
        reconnectToken = null
        reconnectTokenAvailable = false
        pairingState = BLEPairingState.Idle
        authenticationState = BLEAuthenticationState.MissingCertificate
        runtimeState = BLERuntimeState.Unbound
        syncBackgroundService()
    }

    // MARK: - 配对

    fun beginPairing() {
        val current = context
        when {
            !productionEligible ->
                return fail("请先登录并选择车辆")
            current == null ->
                return fail("请先同步当前车辆的蓝牙证书")
            !current.certificate.isSupportedKeyType ->
                return fail("当前蓝牙证书类型不受支持（keyType=${current.certificate.keyType}）")
            !current.certificate.hasValidPasswordCard ->
                return fail("当前蓝牙证书的 passwordCard 无效，请重新同步")
            !bluetoothSupported ->
                return fail("这台设备不支持低功耗蓝牙")
            !hasBluetoothPermission ->
                return fail("请允许壹跑使用附近的蓝牙设备")
            !bluetoothEnabled -> {
                runtimeState = BLERuntimeState.WaitingForBluetooth
                return fail("请先打开手机蓝牙")
            }
        }

        closeGatt()
        stopScan()
        devices.clear()
        advertisements.clear()
        loggedAdvertisementSignatures.clear()

        val scanner = adapter?.bluetoothLeScanner ?: return fail("系统蓝牙不可用")
        val filters = listOf(
            ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build(),
        )
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        scanner.startScan(filters, settings, scanCallback)
        isScanning = true
        pairingState = BLEPairingState.Scanning
        runtimeState = BLERuntimeState.Scanning
        append("PAIR", "开始按 FFFE 搜索当前车辆")
        // 安卓这一层带 ScanFilter，系统只把广播里带 FFFE 的报上来。看不到设备时
        // 「过滤掉了」和「压根没广播」分不出来，所以把过滤条件本身也记一笔。
        append("SCAN", "开始扫描，过滤=FFFE 模式=LOW_LATENCY")

        pairingTimeoutJob?.cancel()
        pairingTimeoutJob = scope.launch {
            delay(PAIRING_SCAN_TIMEOUT_MS)
            if (pairingState != BLEPairingState.Scanning) return@launch
            stopScan()
            if (devices.isEmpty()) {
                pairingState = BLEPairingState.Failed("附近没有搜到车辆，请靠近车辆后重试")
                runtimeState = BLERuntimeState.NeedsAttention("附近没有搜到车辆")
            }
        }
    }

    private fun fail(message: String) {
        pairingState = BLEPairingState.Failed(message)
    }

    fun pair(address: String) {
        if (pairingState != BLEPairingState.Scanning || devices.none { it.address == address }) {
            pairingState = BLEPairingState.Failed("候选车辆已经离开扫描范围")
            return
        }
        stopScan()
        pairingState = BLEPairingState.Connecting(address)
        connect(address, ConnectionIntent.Pairing, autoConnect = false)

        pairingTimeoutJob?.cancel()
        pairingTimeoutJob = scope.launch {
            delay(PAIRING_CONNECT_TIMEOUT_MS)
            val state = pairingState
            if (state is BLEPairingState.Connecting || state is BLEPairingState.Authenticating) {
                closeGatt()
                pairingState = BLEPairingState.Failed("连接车辆超时，请靠近后重试")
                runtimeState = BLERuntimeState.NeedsAttention("连接车辆超时")
            }
        }
    }

    fun cancelPairing() {
        pairingTimeoutJob?.cancel()
        pairingTimeoutJob = null
        stopScan()
        if (connectionIntent == ConnectionIntent.Pairing) closeGatt()
        pairingState = BLEPairingState.Idle
        if (binding?.shouldMaintainConnection == true) {
            ensureManagedConnection()
        } else if (binding == null) {
            runtimeState = BLERuntimeState.Unbound
        }
    }

    private fun stopScan() {
        if (!isScanning) return
        isScanning = false
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        append("SCAN", "停止扫描，共发现 ${devices.size} 个设备")
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            scope.launch { noteDevice(result) }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            scope.launch { results.forEach { noteDevice(it) } }
        }

        override fun onScanFailed(errorCode: Int) {
            scope.launch {
                isScanning = false
                append("ERROR", "扫描失败 ${scanFailureLabel(errorCode)}")
                pairingState = BLEPairingState.Failed("系统蓝牙扫描失败（$errorCode）")
            }
        }
    }

    /// `ScanCallback` 的失败码。6 号（扫得太频繁）最常见也最容易被误读成「附近没有车」——
    /// 那是系统在 30 秒窗口里掐了第 6 次扫描，跟车在不在根本无关。
    private fun scanFailureLabel(errorCode: Int): String = when (errorCode) {
        ScanCallback.SCAN_FAILED_ALREADY_STARTED -> "errorCode=1 上一轮扫描还没停"
        ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "errorCode=2 应用注册扫描失败"
        ScanCallback.SCAN_FAILED_INTERNAL_ERROR -> "errorCode=3 系统蓝牙内部错误"
        ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED -> "errorCode=4 系统不支持这种扫描"
        5 -> "errorCode=5 蓝牙硬件资源已耗尽"
        6 -> "errorCode=6 扫描太频繁，被系统限流"
        else -> "errorCode=$errorCode"
    }

    private fun noteDevice(result: ScanResult) {
        val address = result.device?.address ?: return
        // 车名可能为 null（广播里没带 name），此时只显示 MAC 尾段，不编一个假名字。
        val name = runCatching { result.device.name }.getOrNull()
            ?: result.scanRecord?.deviceName
        val existing = devices.indexOfFirst { it.address == address }
        val device = BLEDiscoveredDevice(address, name, result.rssi)
        if (existing >= 0) devices[existing] = device else devices.add(device)

        val serviceUUIDs = result.scanRecord?.serviceUuids.orEmpty()
            .joinToString(" ") { it.uuid.toString() }
        val advertised = Advertisement(
            rssi = result.rssi,
            isConnectable = result.isConnectable,
            advertisesTargetService = result.scanRecord?.serviceUuids.orEmpty()
                .any { it.uuid == SERVICE_UUID },
            serviceUUIDs = serviceUUIDs,
        )
        advertisements[address] = advertised

        val signature = "${name ?: ""}|${advertised.isConnectable}|" +
            "${advertised.advertisesTargetService}|$serviceUUIDs"
        if (loggedAdvertisementSignatures[address] == signature) return
        loggedAdvertisementSignatures[address] = signature
        append(
            "DISCOVER",
            "发现 ${name ?: "(无名)"} ${maskedAddress(address)} rssi=${result.rssi}" +
                " connectable=${advertised.isConnectable}" +
                " 带FFFE=${advertised.advertisesTargetService}" +
                " 广播服务=${serviceUUIDs.ifEmpty { "(无)" }}",
        )
    }

    // MARK: - 设置与绑定

    fun setBluetoothControlEnabled(enabled: Boolean) {
        val current = binding ?: return
        val next = if (enabled) {
            current.copy(
                configuration = current.configuration.copy(isEnabled = true),
                syncState = BLEConfigurationSyncState.Pending,
                removeAfterDisable = false,
            )
        } else {
            current.copy(
                configuration = current.configuration.copy(
                    isEnabled = false,
                    autoUnlockEnabled = false,
                    autoLockEnabled = false,
                ),
                syncState = BLEConfigurationSyncState.PendingDisable,
            )
        }
        persistAndApply(next)
    }

    fun updatePassiveEntry(autoUnlock: Boolean, autoLock: Boolean) {
        val current = binding ?: return
        persistAndApply(
            current.copy(
                configuration = current.configuration.copy(
                    isEnabled = true,
                    autoUnlockEnabled = autoUnlock,
                    autoLockEnabled = autoLock,
                ),
                syncState = BLEConfigurationSyncState.Pending,
                removeAfterDisable = false,
            ),
        )
    }

    /// 解绑不是「本地删掉了事」：车端还留着这把钥匙，必须先把关闭配置同步过去，
    /// 收到回复后才清本地记录。同步不上就一直停在 pendingDisable，界面照实说。
    fun removeBinding() {
        val current = binding ?: return
        persistAndApply(
            current.copy(
                configuration = current.configuration.copy(
                    isEnabled = false,
                    autoUnlockEnabled = false,
                    autoLockEnabled = false,
                ),
                syncState = BLEConfigurationSyncState.PendingDisable,
                removeAfterDisable = true,
            ),
        )
    }

    fun clearReconnectToken() = invalidateReconnectToken("用户手动清除快速重连凭证")

    private fun persistAndApply(value: BLEVehicleBinding) {
        if (!BLEVehicleBindingStore.save(value)) {
            runtimeState = BLERuntimeState.NeedsAttention("蓝牙钥匙设置写入本机加密存储失败")
            return
        }
        binding = value
        if (authenticationState == BLEAuthenticationState.Authenticated) {
            sendPendingConfigurationIfPossible()
        } else {
            ensureManagedConnection()
        }
    }

    // MARK: - 控车

    /// 首页控车的蓝牙优先路径。返回 [BLEControlAttemptResult.UnavailableBeforeWrite]
    /// 表示这条指令根本没发出去，调用方应当回退到 HTTP 远控。
    suspend fun performControl(
        command: LeapBLEControlCommand,
        connectionTimeoutMs: Long = 6_000,
    ): BLEControlAttemptResult {
        if (!productionEligible || binding?.isBluetoothControlEnabled != true) {
            return BLEControlAttemptResult.UnavailableBeforeWrite("蓝牙钥匙未启用")
        }
        if (!hasConnectPermission) {
            return BLEControlAttemptResult.UnavailableBeforeWrite("未获得蓝牙权限")
        }
        ensureManagedConnection()

        val deadline = System.currentTimeMillis() + connectionTimeoutMs
        while (!canControl && System.currentTimeMillis() < deadline) {
            (runtimeState as? BLERuntimeState.NeedsAttention)?.let {
                return BLEControlAttemptResult.UnavailableBeforeWrite(it.message)
            }
            delay(80)
        }
        if (!canControl) {
            return BLEControlAttemptResult.UnavailableBeforeWrite("车辆蓝牙连接或认证未就绪")
        }

        val attemptID = ++attemptSequence
        completedControlAttempt = null
        activeControlAttempt = ControlAttempt(attemptID, didStartWrite = false)
        try {
            val session = cryptoSession ?: run {
                activeControlAttempt = null
                return BLEControlAttemptResult.UnavailableBeforeWrite("蓝牙会话密钥不可用")
            }
            val frame = session.controlFrame(command)
            pendingControlLabel = command.label
            append("CONTROL", "生成${command.label}指令 cmdID=${command.code} frame=${frame.size} bytes")
            beginTransmission(frame, TransmissionPurpose.Control(command, attemptID))
        } catch (e: Exception) {
            activeControlAttempt = null
            pendingControlLabel = null
            return BLEControlAttemptResult.UnavailableBeforeWrite(LeapError.messageOf(e))
        }

        val resultDeadline = System.currentTimeMillis() + 9_000
        while (System.currentTimeMillis() < resultDeadline) {
            completedControlAttempt?.let { (id, result) ->
                if (id == attemptID) {
                    completedControlAttempt = null
                    activeControlAttempt = null
                    return result
                }
            }
            delay(80)
        }
        val didStartWrite = activeControlAttempt?.didStartWrite == true
        activeControlAttempt = null
        pendingControlLabel = null
        return if (didStartWrite) {
            BLEControlAttemptResult.SentWithoutConfirmation
        } else {
            BLEControlAttemptResult.UnavailableBeforeWrite("蓝牙控制帧未能开始写入")
        }
    }

    private fun finishControlAttempt(result: BLEControlAttemptResult, id: Long?) {
        if (id == null) return
        completedControlAttempt = id to result
    }

    // MARK: - 直进直出

    /// 等现有的蓝牙钥匙连接完成认证。直进直出不新建连接，也不新建扫描。
    suspend fun prepareStraightMove(timeoutMs: Long = 50_000) {
        if (!productionEligible) throw LeapError.server("当前环境不能使用直进直出")
        if (binding?.isBluetoothControlEnabled != true) {
            throw LeapError.server("请先绑定并开启蓝牙钥匙")
        }
        if (!applicationIsActive) throw LeapError.server("请保持 App 在前台")
        if (!hasConnectPermission) throw LeapError.server("未获得蓝牙权限")
        if (!bluetoothEnabled) throw LeapError.server("请先打开手机蓝牙")

        straightMoveState = BLEStraightMoveState.Preparing
        ensureManagedConnection()
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (!canControl && SystemClock.elapsedRealtime() < deadline) {
            if (!applicationIsActive) {
                straightMoveState = BLEStraightMoveState.Failed("App 已离开前台")
                throw LeapError.server("请保持 App 在前台")
            }
            (runtimeState as? BLERuntimeState.NeedsAttention)?.let {
                straightMoveState = BLEStraightMoveState.Failed(it.message)
                throw LeapError.server(it.message)
            }
            delay(80)
        }
        if (!canControl) {
            straightMoveState = BLEStraightMoveState.Failed("车辆蓝牙连接或认证未就绪")
            throw LeapError.server("靠近车辆后重试，蓝牙连接需在 50 秒内完成")
        }
        straightMoveState = BLEStraightMoveState.Ready
        append("STRAIGHT", "直进直出会话已就绪")
    }

    /// 按下即发一帧，随后 100ms 一帧地续。调用方必须在松手时调 [stopStraightMove]。
    fun startStraightMove(direction: StraightMoveDirection) {
        if (!applicationIsActive) throw LeapError.server("请保持 App 在前台")
        if (!straightMoveState.isPrepared || !canControl || cryptoSession == null) {
            throw LeapError.server("直进直出尚未就绪")
        }
        straightMoveStopJob?.cancel()
        straightMoveStopJob = null
        val order = StraightMoveOrder.of(direction)
        val moving = BLEStraightMoveState.Moving(direction)
        straightMoveState = moving
        queueStraightMove(order)

        straightMoveHeartbeatJob?.cancel()
        straightMoveHeartbeatJob = scope.launch {
            while (true) {
                delay(100)
                if (!applicationIsActive || straightMoveState != moving) return@launch
                queueStraightMove(order)
            }
        }

        lastStraightMoveTransmissionAt = SystemClock.elapsedRealtime()
        straightMoveWatchdogJob?.cancel()
        // 看门狗独立于心跳：心跳只管排帧，写队列堵住时排进去的帧发不出去，
        // 车辆却还按上一帧在走。超过 350ms（三个心跳周期）没真发出去就当链路断了。
        straightMoveWatchdogJob = scope.launch {
            while (true) {
                delay(100)
                if (straightMoveState != moving) return@launch
                val last = lastStraightMoveTransmissionAt ?: return@launch
                if (SystemClock.elapsedRealtime() - last > 350) {
                    emergencyStopStraightMove("控制心跳中断")
                    return@launch
                }
            }
        }
        append("STRAIGHT", "开始${direction.label}，100ms 心跳已启动")
    }

    /// 松手停止。停止帧插到当前写入之后，并以 70ms 间隔补发两次。
    fun stopStraightMove() = stopStraightMove(null)

    /// 退出页面：先停车，再收掉本次控制状态；蓝牙钥匙的连接继续由控制器自己维护。
    fun closeStraightMove() {
        if (straightMoveState == BLEStraightMoveState.Idle) return
        straightMoveHeartbeatJob?.cancel()
        straightMoveHeartbeatJob = null
        straightMoveWatchdogJob?.cancel()
        straightMoveWatchdogJob = null
        straightMoveState = BLEStraightMoveState.Paused
        pendingStraightMoveOrder = StraightMoveOrder.Stop
        queueStraightMove(StraightMoveOrder.Stop)
        straightMoveStopJob?.cancel()
        straightMoveStopJob = scope.launch {
            repeat(2) {
                delay(70)
                queueStraightMove(StraightMoveOrder.Stop)
            }
            delay(140)
            pendingStraightMoveOrder = null
            straightMoveState = BLEStraightMoveState.Idle
            append("STRAIGHT", "直进直出控制已关闭")
        }
    }

    private fun emergencyStopStraightMove(reason: String) = stopStraightMove(reason)

    private fun stopStraightMove(reason: String?) {
        straightMoveHeartbeatJob?.cancel()
        straightMoveHeartbeatJob = null
        straightMoveWatchdogJob?.cancel()
        straightMoveWatchdogJob = null
        pendingStraightMoveOrder = StraightMoveOrder.Stop
        straightMoveState = reason?.let { BLEStraightMoveState.Failed(it) }
            ?: BLEStraightMoveState.Paused
        queueStraightMove(StraightMoveOrder.Stop)
        straightMoveStopJob?.cancel()
        straightMoveStopJob = scope.launch {
            repeat(2) {
                delay(70)
                queueStraightMove(StraightMoveOrder.Stop)
            }
        }
        append("STRAIGHT", reason?.let { "异常停止：$it" } ?: "松手停止")
    }

    private fun queueStraightMove(order: StraightMoveOrder) {
        val session = cryptoSession
        if (authenticationState != BLEAuthenticationState.Authenticated || session == null) {
            emergencyStopStraightMoveIfNeeded("蓝牙认证已失效")
            return
        }
        if (transmissionPurpose != null) {
            // 停止永远覆盖移动心跳；移动心跳只保留最新一帧，避免写队列积压后盲走。
            if (order == StraightMoveOrder.Stop ||
                pendingStraightMoveOrder != StraightMoveOrder.Stop
            ) {
                pendingStraightMoveOrder = order
            }
            return
        }
        try {
            pendingStraightMoveOrder = null
            beginTransmission(session.straightMoveFrame(order), TransmissionPurpose.StraightMove(order))
        } catch (e: Exception) {
            emergencyStopStraightMoveIfNeeded(LeapError.messageOf(e))
        }
    }

    /// 出事时尽最大努力把停止帧塞出去：写队列空着就直接发，堵着就排进去等。
    /// 无论发没发出去，状态都落到 failed——界面必须马上不给按。
    private fun emergencyStopStraightMoveIfNeeded(reason: String) {
        if (!straightMoveState.isPrepared) return
        straightMoveHeartbeatJob?.cancel()
        straightMoveHeartbeatJob = null
        straightMoveWatchdogJob?.cancel()
        straightMoveWatchdogJob = null
        pendingStraightMoveOrder = StraightMoveOrder.Stop
        val session = cryptoSession
        if (transmissionPurpose == null &&
            authenticationState == BLEAuthenticationState.Authenticated &&
            session != null
        ) {
            runCatching {
                val frame = session.straightMoveFrame(StraightMoveOrder.Stop)
                pendingStraightMoveOrder = null
                beginTransmission(frame, TransmissionPurpose.StraightMove(StraightMoveOrder.Stop))
            }
        }
        straightMoveState = BLEStraightMoveState.Failed(reason)
        append("STRAIGHT", "异常停止：$reason")
    }

    // MARK: - 连接管理

    private fun ensureManagedConnection() {
        val current = binding ?: return
        if (!productionEligible || !current.shouldMaintainConnection) return
        if (pairingState == BLEPairingState.Scanning) return
        if (!hasConnectPermission) {
            runtimeState = BLERuntimeState.NeedsAttention("请允许壹跑使用附近的蓝牙设备")
            return
        }
        if (!bluetoothEnabled) {
            runtimeState = BLERuntimeState.WaitingForBluetooth
            return
        }
        if (gatt != null && connectedAddress == current.deviceAddress) {
            connectionIntent = ConnectionIntent.Managed
            if (linkState == BLELinkState.Ready &&
                authenticationState != BLEAuthenticationState.Authenticated &&
                authenticationState != BLEAuthenticationState.Authenticating
            ) {
                authenticate()
            }
            return
        }
        connect(current.deviceAddress, ConnectionIntent.Managed, autoConnect = true)
    }

    /// compileSdk 37 把带 transport 的 `connectGatt` 标了废弃，替代品
    /// `connectGatt(BluetoothGattConnectionSettings, …)` 是 API 37 才有的，minSdk 31 用不了。
    /// 等最低版本抬上去再换，现在为它加一条版本分支只是多一条跑不到的代码。
    @Suppress("DEPRECATION")
    private fun connect(
        address: String,
        intent: ConnectionIntent,
        autoConnect: Boolean,
        isRelink: Boolean = false,
    ) {
        closeGatt()
        val device: BluetoothDevice = runCatching { adapter?.getRemoteDevice(address) }.getOrNull()
            ?: run {
                runtimeState = BLERuntimeState.NeedsAttention("系统已找不到这台车，请在车旁重新绑定")
                return
            }
        connectionIntent = intent
        connectedAddress = address
        connectedDeviceName = null
        linkState = BLELinkState.Connecting
        runtimeState = BLERuntimeState.Connecting
        connectStartedAt = SystemClock.elapsedRealtime()
        closingIntentionally = false
        lastConnectAutoConnect = autoConnect
        // 补救性重连不复位这两个标记，否则「卡住→重连→再卡住」会一直转下去。
        if (!isRelink) {
            relinkedOnce = false
            skipMtuNegotiation = false
        }
        BLETrace.armReplay()
        append(
            "CONNECT",
            "发起连接 ${maskedAddress(address)}" +
                " 来源=${if (intent == ConnectionIntent.Pairing) "配对" else "常驻"}" +
                " autoConnect=$autoConnect",
        )
        gatt = device.connectGatt(AppEnv.context, autoConnect, gattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    private fun stopManagedConnection() {
        closeGatt()
        resetVolatileConnectionState()
    }

    private fun closeGatt() {
        // 先掐掉待发的补救性重连：走到这儿说明链路要么被别人接手了，要么是用户
        // 自己收的手，再让 400 ms 后那次重连把连接拉起来只会是幽灵连接。
        // （`relinkOnce` 自己是先关链路、后建定时器，不会误伤。）
        linkRetryJob?.cancel()
        linkRetryJob = null
        gatt?.let {
            closingIntentionally = true
            append("CONNECT", "主动断开当前连接")
            runCatching { it.disconnect() }
            runCatching { it.close() }
        }
        gatt = null
        characteristic = null
        connectedAddress = null
        connectedDeviceName = null
        connectStartedAt = null
        mtuStartedAt = null
        discoveryStartedAt = null
        subscribeStartedAt = null
        linkState = BLELinkState.Idle
    }

    private fun resetVolatileConnectionState() {
        if (straightMoveState.isPrepared) {
            straightMoveHeartbeatJob?.cancel()
            straightMoveHeartbeatJob = null
            straightMoveWatchdogJob?.cancel()
            straightMoveWatchdogJob = null
            straightMoveStopJob?.cancel()
            straightMoveStopJob = null
            pendingStraightMoveOrder = null
            straightMoveState = BLEStraightMoveState.Failed("车辆蓝牙连接已断开")
        }
        responseTimeoutJob?.cancel()
        responseTimeoutJob = null
        cryptoSession = null
        authenticationMode = null
        pendingFullAuthenticationFallback = false
        authenticationState = if (context == null) {
            BLEAuthenticationState.MissingCertificate
        } else {
            BLEAuthenticationState.Prepared
        }
        pendingControlLabel = null
        transmissionPurpose = null
        transmissionChunks = emptyList()
        nextChunk = 0
        configurationInFlight = null
        reassembler.reset()
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            scope.launch {
                if (g !== gatt) {
                    runCatching { g.close() }
                    return@launch
                }
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    connectedDeviceName = runCatching { g.device?.name }.getOrNull()
                    val elapsed = connectStartedAt?.let { SystemClock.elapsedRealtime() - it }
                    append(
                        "CONNECT",
                        "已连接 ${connectedAddress?.let { maskedAddress(it) } ?: "(未知)"}" +
                            " 名称=${connectedDeviceName ?: "(无名)"}" +
                            (elapsed?.let { "，耗时 $it ms" } ?: ""),
                    )
                    linkState = BLELinkState.Discovering
                    runtimeState = BLERuntimeState.Connecting
                    if (skipMtuNegotiation) {
                        skipMtuNegotiation = false
                        mtu = 23
                        append("MTU", "上一轮 MTU 协商没有回调，本轮跳过主动协商，按 mtu=23 继续")
                        beginServiceDiscovery(g)
                    } else {
                        mtuStartedAt = SystemClock.elapsedRealtime()
                        append("MTU", "请求 MTU $REQUESTED_MTU，等协商结果")
                        if (!g.requestMtu(REQUESTED_MTU)) {
                            mtuStartedAt = null
                            append("MTU", "系统拒绝了 MTU 请求，按 mtu=$mtu 直接发现服务")
                            beginServiceDiscovery(g)
                        } else {
                            startMtuWatchdog()
                        }
                    }
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    handleDisconnect(status)
                }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, negotiated: Int, status: Int) {
            scope.launch {
                if (g !== gatt) return@launch
                val waited = mtuStartedAt?.let { SystemClock.elapsedRealtime() - it }
                mtuStartedAt = null
                mtu = if (status == BluetoothGatt.GATT_SUCCESS) negotiated else 23
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    append("MTU", "协商结果 mtu=$mtu，等了 ${waited ?: "?"} ms")
                } else {
                    // 协商失败不影响能不能用，只是每片小到 20 字节——认证帧会被切成十几片。
                    append("MTU", "协商失败 status=$status，退回 mtu=23，等了 ${waited ?: "?"} ms")
                }
                beginServiceDiscovery(g)
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            scope.launch {
                if (g !== gatt) return@launch
                val elapsed = discoveryStartedAt?.let { SystemClock.elapsedRealtime() - it }
                discoveryStartedAt = null
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    append("SERVICE", "服务发现失败 status=$status，耗时 ${elapsed ?: "?"} ms")
                    append("ERROR", "发现服务失败 status=$status")
                    logDiscoveryContext()
                    BLETrace.replay("服务发现失败 status=$status")
                    linkState = BLELinkState.Failed
                    runtimeState = BLERuntimeState.NeedsAttention("车辆蓝牙服务不可用")
                    return@launch
                }

                val services = g.services.orEmpty()
                val service = g.getService(SERVICE_UUID)
                append(
                    "SERVICE",
                    "服务发现完成：${services.size} 个服务，FFFE=${if (service == null) "无" else "有"}" +
                        "，耗时 ${elapsed ?: "?"} ms",
                )
                // 摊开才查得动。归 SERVICE-MAP 是为了只进回溯缓冲、不刷 logcat——
                // 一台车能报出十几个服务，逐条写系统日志会把有用的那几行挤没。
                for (item in services) {
                    val characteristics = item.characteristics.orEmpty()
                    append(
                        "SERVICE-MAP",
                        "${item.uuid} → ${
                            if (characteristics.isEmpty()) {
                                "(无特征)"
                            } else {
                                characteristics.joinToString(" ") { it.uuid.toString() }
                            }
                        }",
                    )
                }

                // 三种失法要分开说：服务表整个是空的、有服务但没 FFFE、有 FFFE 但里面没 FFF2。
                // 混成一句「没有找到 FFFE/FFF2」，等于把「连错设备」和「服务发现没跑完」
                // 这两件完全不同的事写成同一行。
                if (services.isEmpty()) {
                    append("ERROR", "GATT 回了空服务列表——服务发现没完成，或者拿到的是过期缓存")
                    logDiscoveryContext()
                    BLETrace.replay("服务表为空")
                    linkState = BLELinkState.Failed
                    runtimeState = BLERuntimeState.NeedsAttention("这台设备不是零跑蓝牙钥匙模块")
                    return@launch
                }
                if (service == null) {
                    append(
                        "ERROR",
                        "服务表里没有 FFFE。期望 $SERVICE_UUID，" +
                            "实际 ${services.joinToString(" ") { it.uuid.toString() }}",
                    )
                    logDiscoveryContext()
                    BLETrace.replay("服务表里没有 FFFE")
                    linkState = BLELinkState.Failed
                    runtimeState = BLERuntimeState.NeedsAttention("这台设备不是零跑蓝牙钥匙模块")
                    return@launch
                }
                val target = service.getCharacteristic(CHARACTERISTIC_UUID)
                if (target == null) {
                    val characteristics = service.characteristics.orEmpty()
                    append(
                        "ERROR",
                        "FFFE 服务在，但里面没有 FFF2。期望 $CHARACTERISTIC_UUID，实际 " +
                            if (characteristics.isEmpty()) {
                                "(无特征)"
                            } else {
                                characteristics.joinToString(" ") { it.uuid.toString() }
                            },
                    )
                    logDiscoveryContext()
                    BLETrace.replay("FFFE 里没有 FFF2")
                    linkState = BLELinkState.Failed
                    runtimeState = BLERuntimeState.NeedsAttention("这台设备不是零跑蓝牙钥匙模块")
                    return@launch
                }

                characteristic = target
                // 写类型是双端对过一次的地方，出怪问题时第一个要看的就是这行。
                val properties = target.properties
                append(
                    "SERVICE",
                    "FFF2 就绪：write=${properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0}" +
                        " writeNoResponse=${
                            properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0
                        }" +
                        " notify=${properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0}" +
                        " indicate=${properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0}",
                )

                val registered = g.setCharacteristicNotification(target, true)
                if (!registered) {
                    // 本地注册失败时 CCCD 照样写得进去，但通知永远不会回调——
                    // 症状是「连上了、认证发出去了、没有任何回包」，不记这行根本查不到。
                    append("NOTIFY", "本机登记通知回调失败，后续可能收不到车辆回包")
                }
                val cccd = target.getDescriptor(CCCD_UUID)
                if (cccd == null) {
                    append("ERROR", "FFF2 没有 CCCD，无法订阅通知")
                    logDiscoveryContext()
                    BLETrace.replay("FFF2 没有 CCCD")
                    linkState = BLELinkState.Failed
                    return@launch
                }
                subscribeStartedAt = SystemClock.elapsedRealtime()
                append("NOTIFY", "开始订阅 FFF2 通知（写 CCCD）")
                writeDescriptor(g, cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            }
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            scope.launch {
                if (g !== gatt || descriptor.uuid != CCCD_UUID) return@launch
                val elapsed = subscribeStartedAt?.let { SystemClock.elapsedRealtime() - it }
                subscribeStartedAt = null
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    append("ERROR", "订阅 FFF2 通知失败 status=$status，耗时 ${elapsed ?: "?"} ms")
                    BLETrace.replay("订阅 FFF2 通知失败 status=$status")
                    linkState = BLELinkState.Failed
                    return@launch
                }
                append("NOTIFY", "已订阅 FFF2 通知，耗时 ${elapsed ?: "?"} ms")
                linkState = BLELinkState.Ready
                reassembler.reset()
                authenticate()
            }
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            val value = ch.value ?: return
            scope.launch { if (g === gatt) receive(value) }
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            scope.launch { if (g === gatt) receive(value) }
        }

        override fun onCharacteristicWrite(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            status: Int,
        ) {
            scope.launch {
                if (g !== gatt) return@launch
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    failTransmission("写入 FFF2 失败 status=$status")
                    return@launch
                }
                sendNextChunk()
            }
        }
    }

    private fun beginServiceDiscovery(g: BluetoothGatt) {
        discoveryStartedAt = SystemClock.elapsedRealtime()
        append("SERVICE", "开始服务发现")
        // 返回 false 意味着这次请求根本没发出去，`onServicesDiscovered` 不会来，
        // 链路就此停在「连接中」——没有任何回调会把它推下去，只能自己兜。
        if (!g.discoverServices()) {
            discoveryStartedAt = null
            append("ERROR", "系统拒绝了服务发现请求")
            relinkOnce(
                reason = "系统拒绝服务发现",
                skipMtu = false,
                failureMessage = "读取车辆的蓝牙服务失败，请靠近车辆后重试",
            )
        }
    }

    /// MTU 协商的看门狗。回调迟迟不来时链路会停在「连接中」不动，没有任何事件
    /// 能把它推下去；照鸿蒙的做法关掉链路重连一次，下一轮直接按 mtu=23 走。
    ///
    /// 不在这里替 `onMtuChanged` 直接去发现服务：超时只代表 App 不再等，底层那次
    /// EXCHANGE_MTU 并没有取消，接着发服务发现等于同时挂两个 GATT request。
    private fun startMtuWatchdog() {
        val startedAt = mtuStartedAt ?: return
        val g = gatt
        scope.launch {
            delay(MTU_WATCHDOG_MS)
            if (gatt !== g || mtuStartedAt != startedAt) return@launch
            append("MTU", "等协商结果超过 $MTU_WATCHDOG_MS ms 还没回调")
            relinkOnce(
                reason = "MTU 协商无回调",
                skipMtu = true,
                failureMessage = "与车辆协商蓝牙参数超时，请靠近车辆后重试",
            )
        }
    }

    /// 建链卡在半路时的兜底：关掉当前链路，隔 [RELINK_DELAY_MS] 重连一次。
    ///
    /// 值得重连的理由是这两种卡法都带偶发性：第一次连上时车端的服务表还没进系统缓存，
    /// MTU 与服务发现挤在一起也容易撞上并发的 GATT request；断开再连时服务表通常已经
    /// 在缓存里，`skipMtu` 再把那次协商让开，第二轮多半就顺了。
    ///
    /// **每条链路只兜一次**（[relinkedOnce]）。第二次还卡在同一步，说明不是偶发竞态，
    /// 再关再连只是把「连接中」的转圈拉长，不如把失败摆出来让车主靠近车辆重试。
    private fun relinkOnce(reason: String, skipMtu: Boolean, failureMessage: String) {
        val address = connectedAddress ?: return
        val intent = connectionIntent
        val autoConnect = lastConnectAutoConnect
        if (relinkedOnce) {
            append("ERROR", "$reason，这条链路已经重连过一次，不再重试")
            logDiscoveryContext()
            BLETrace.replay("$reason（重连后仍然卡住）")
            linkState = BLELinkState.Failed
            runtimeState = BLERuntimeState.NeedsAttention(failureMessage)
            return
        }
        relinkedOnce = true
        if (skipMtu) skipMtuNegotiation = true
        append("CONNECT", "$reason，关闭当前链路并重连一次")
        BLETrace.replay(reason)
        closeGatt()
        linkRetryJob = scope.launch {
            delay(RELINK_DELAY_MS)
            linkRetryJob = null
            // 这 400 ms 里蓝牙可能已经被关掉了，那就别再去拉链路。
            if (adapter?.isEnabled != true) {
                append("CONNECT", "补救重连前蓝牙已关闭，放弃这次重连")
                return@launch
            }
            connect(address, intent, autoConnect, isRelink = true)
        }
    }

    @Suppress("DEPRECATION")
    private fun writeDescriptor(
        g: BluetoothGatt,
        descriptor: BluetoothGattDescriptor,
        value: ByteArray,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(descriptor, value)
        } else {
            descriptor.value = value
            g.writeDescriptor(descriptor)
        }
    }

    private fun handleDisconnect(status: Int) {
        val expected = closingIntentionally
        closingIntentionally = false
        val elapsed = connectStartedAt?.let { SystemClock.elapsedRealtime() - it }
        append(
            "CONNECT",
            "连接已断开（${disconnectReasonLabel(status)}）" +
                (elapsed?.let { "，本次连接存活 $it ms" } ?: ""),
        )
        // 自己关的不回溯——那是解绑、切车、重连前的清场，不是故障。
        if (!expected) BLETrace.replay("非预期断连 ${disconnectReasonLabel(status)}")
        connectStartedAt = null
        mtuStartedAt = null
        discoveryStartedAt = null
        subscribeStartedAt = null
        val intent = connectionIntent
        val attempt = activeControlAttempt
        resetVolatileConnectionState()
        characteristic = null
        linkState = BLELinkState.Idle

        if (attempt != null) {
            finishControlAttempt(
                if (attempt.didStartWrite) {
                    BLEControlAttemptResult.FailedAfterWrite("控制过程中连接断开")
                } else {
                    BLEControlAttemptResult.UnavailableBeforeWrite("控制帧写入前连接断开")
                },
                attempt.id,
            )
        }

        when (intent) {
            ConnectionIntent.Pairing -> {
                pairingTimeoutJob?.cancel()
                pairingTimeoutJob = null
                closeGatt()
                pairingState = BLEPairingState.Failed("绑定过程中车辆连接断开")
                runtimeState = BLERuntimeState.NeedsAttention("绑定过程中车辆连接断开")
            }
            // autoConnect=true 的 GATT 句柄留着，系统会在车辆再次出现时自动接上，
            // 这正是「走近车就能控」需要的行为，别在这里 close 掉。
            ConnectionIntent.Managed -> runtimeState = BLERuntimeState.Recovering
        }
    }

    // MARK: - 认证

    private fun authenticate(forceFull: Boolean = false) {
        if (linkState != BLELinkState.Ready || characteristic == null) {
            append("ERROR", "认证前必须先连接并订阅 FFF2")
            return
        }
        val current = context ?: run {
            authenticationState = BLEAuthenticationState.MissingCertificate
            append("ERROR", "请先同步蓝牙证书")
            return
        }
        try {
            val session = LeapBLECryptoSession.make(current.certificate, current.vin)
            val token = reconnectToken
            val mode: AuthenticationMode
            val frame: ByteArray
            if (!forceFull && token != null) {
                mode = AuthenticationMode.Reconnect
                frame = session.reconnectAuthenticationFrame(
                    token = token,
                    accountId = current.accountId,
                    configuration = activeConfiguration,
                )
            } else {
                mode = AuthenticationMode.Full
                frame = session.fullAuthenticationFrame(
                    certificate = current.certificate,
                    accountId = current.accountId,
                    deviceId = current.deviceId,
                    configuration = activeConfiguration,
                )
            }
            cryptoSession = session
            authenticationMode = mode
            authenticationState = BLEAuthenticationState.Authenticating
            runtimeState = BLERuntimeState.Authenticating
            authenticationError = null
            (pairingState as? BLEPairingState.Connecting)?.let {
                pairingTimeoutJob?.cancel()
                pairingTimeoutJob = null
                pairingState = BLEPairingState.Authenticating(it.address)
            }
            append(
                "AUTH",
                "生成${mode.label}帧 type=${if (mode == AuthenticationMode.Reconnect) "AA EE" else "AA AE"} " +
                    "sessionID=${session.sessionID} frame=${frame.size} bytes",
            )
            beginTransmission(frame, TransmissionPurpose.Authentication(mode))
        } catch (e: Exception) {
            failAuthentication(LeapError.messageOf(e))
        }
    }

    /// 认证帧里带的配置：已绑定就用绑定里那份，没绑定（首次配对）用只开手动控车的那份。
    private val activeConfiguration: LeapBLEConfiguration
        get() = binding?.configuration ?: LeapBLEConfiguration.MANUAL_CONTROL

    private fun failAuthentication(message: String) {
        responseTimeoutJob?.cancel()
        responseTimeoutJob = null
        pendingFullAuthenticationFallback = false
        pairingTimeoutJob?.cancel()
        pairingTimeoutJob = null
        authenticationState = BLEAuthenticationState.Failed
        authenticationError = message
        pendingControlLabel = null
        when (connectionIntent) {
            ConnectionIntent.Pairing -> {
                pairingState = BLEPairingState.Failed(message)
                runtimeState = BLERuntimeState.NeedsAttention("车辆身份认证失败")
            }
            ConnectionIntent.Managed -> runtimeState = BLERuntimeState.NeedsAttention(message)
        }
        append("ERROR", "蓝牙认证失败：$message")
    }

    private fun completeAuthentication(lockState: String) {
        if (authenticationState != BLEAuthenticationState.Authenticating) return
        responseTimeoutJob?.cancel()
        responseTimeoutJob = null
        authenticationState = BLEAuthenticationState.Authenticated
        authenticationError = null
        runtimeState = BLERuntimeState.Ready
        append("AUTH", "${authenticationMode?.label ?: "蓝牙认证"}成功，车辆门锁状态=$lockState")
        if (connectionIntent == ConnectionIntent.Pairing) {
            completePairingIfNeeded()
        } else {
            updateBindingVerification()
            sendPendingConfigurationIfPossible()
        }
    }

    private fun completePairingIfNeeded() {
        val current = context ?: return
        val address = connectedAddress ?: return
        val value = BLEVehicleBinding(
            accountId = current.accountId,
            vin = current.vin,
            deviceAddress = address,
            certificateFingerprint = current.certificate.fingerprint,
            configuration = LeapBLEConfiguration.MANUAL_CONTROL,
            syncState = BLEConfigurationSyncState.Pending,
            removeAfterDisable = false,
            lastVerifiedAt = System.currentTimeMillis(),
        )
        if (!BLEVehicleBindingStore.save(value)) {
            pairingState = BLEPairingState.Failed("车辆认证成功，但绑定信息写入本机加密存储失败")
            runtimeState = BLERuntimeState.NeedsAttention("绑定信息无法安全保存")
            return
        }
        binding = value
        BLEPairingHistory.recordPaired(current.accountId, current.vin)
        connectionIntent = ConnectionIntent.Managed
        pairingTimeoutJob?.cancel()
        pairingTimeoutJob = null
        pairingState = BLEPairingState.Bound
        runtimeState = BLERuntimeState.Ready
        append("PAIR", "当前 VIN 完整认证成功，已保存可信车辆绑定")
        sendPendingConfigurationIfPossible()
    }

    private fun updateBindingVerification() {
        val current = binding ?: return
        val credential = context ?: return
        val next = current.copy(
            lastVerifiedAt = System.currentTimeMillis(),
            certificateFingerprint = credential.certificate.fingerprint,
        )
        binding = next
        BLEVehicleBindingStore.save(next)
    }

    private fun saveReconnectToken(token: String) {
        val current = context ?: return
        if (!BLEReconnectTokenStore.save(token, current.accountId, current.vin)) {
            append("ERROR", "快速重连凭证写入本机加密存储失败")
            return
        }
        reconnectToken = token
        reconnectTokenAvailable = true
        append("TOKEN", "已保存快速重连凭证 length=${token.length} hex chars")
    }

    private fun invalidateReconnectToken(reason: String) {
        context?.let { BLEReconnectTokenStore.clear(it.accountId, it.vin) }
        reconnectToken = null
        reconnectTokenAvailable = false
        append("TOKEN", reason)
    }

    private fun performFullAuthenticationFallback() {
        responseTimeoutJob?.cancel()
        responseTimeoutJob = null
        authenticationState = BLEAuthenticationState.Prepared
        append("AUTH", "快速重连凭证失效，自动回退完整认证")
        authenticate(forceFull = true)
    }

    // MARK: - 配置同步

    private fun sendPendingConfigurationIfPossible() {
        val current = binding ?: return
        if (current.syncState == BLEConfigurationSyncState.Synced) return
        if (configurationInFlight != null) return
        if (authenticationState != BLEAuthenticationState.Authenticated) return
        val session = cryptoSession ?: return
        if (transmissionPurpose != null || pendingControlLabel != null) return
        try {
            val frame = session.configurationFrame(current.configuration)
            configurationInFlight = current.configuration
            runtimeState = BLERuntimeState.SyncingConfiguration
            append("CONFIG", "发送命令 3，同步 9 字节蓝牙钥匙设置")
            beginTransmission(frame, TransmissionPurpose.Configuration)
        } catch (e: Exception) {
            configurationInFlight = null
            append("ERROR", "蓝牙钥匙设置发送失败：${LeapError.messageOf(e)}")
        }
    }

    private fun completeConfigurationSync(identifier: String, result: String?) {
        val current = binding ?: return
        if (current.syncState == BLEConfigurationSyncState.Synced) return
        val sent = configurationInFlight ?: return
        configurationInFlight = null
        responseTimeoutJob?.cancel()
        responseTimeoutJob = null
        append("CONFIG", "车辆已回复命令 3 identifier=$identifier result=${result ?: "(无)"}")

        if (current.configuration != sent) {
            runtimeState = BLERuntimeState.Ready
            append("CONFIG", "设置在发送期间发生变化，继续同步最新配置")
            sendPendingConfigurationIfPossible()
            return
        }

        val next = current.copy(syncState = BLEConfigurationSyncState.Synced)
        binding = next
        if (!BLEVehicleBindingStore.save(next)) {
            runtimeState = BLERuntimeState.NeedsAttention("车辆已接收设置，但本机状态保存失败")
            return
        }
        if (!next.configuration.isEnabled) {
            if (next.removeAfterDisable) {
                BLEVehicleBindingStore.clear(next.accountId, next.vin)
                BLEReconnectTokenStore.clear(next.accountId, next.vin)
                binding = null
                reconnectToken = null
                reconnectTokenAvailable = false
                pairingState = BLEPairingState.Idle
                runtimeState = BLERuntimeState.Unbound
            } else {
                runtimeState = BLERuntimeState.Disabled
            }
            stopManagedConnection()
        } else {
            runtimeState = BLERuntimeState.Ready
        }
    }

    // MARK: - 收发

    private fun beginTransmission(frame: ByteArray, purpose: TransmissionPurpose) {
        if (transmissionPurpose != null) {
            throw org.yipao.app.core.LeapBLEProtocolError.invalidFrame("已有数据正在写入")
        }
        val target = characteristic
            ?: throw org.yipao.app.core.LeapBLEProtocolError.invalidFrame("GATT 尚未就绪")
        val writable = target.properties and
            (BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE)
        if (writable == 0) {
            throw org.yipao.app.core.LeapBLEProtocolError.invalidFrame("FFF2 不可写")
        }
        val chunkSize = maxOf(20, minOf(mtu - 3, MAX_CHUNK))
        transmissionPurpose = purpose
        transmissionChunks = frame.toList().chunked(chunkSize) { it.toByteArray() }
        nextChunk = 0
        append(
            "TX",
            "开始发送${purpose.label} frame=${frame.size} bytes " +
                "chunks=${transmissionChunks.size} chunkLimit=$chunkSize",
            LeapCrypto.toHex(frame).uppercase(),
        )
        sendNextChunk()
    }

    private fun sendNextChunk() {
        val purpose = transmissionPurpose ?: return
        val target = characteristic ?: return failTransmission("GATT 已断开")
        val g = gatt ?: return failTransmission("GATT 已断开")

        if (nextChunk >= transmissionChunks.size) {
            completeTransmission(purpose)
            return
        }
        val index = nextChunk
        val chunk = transmissionChunks[index]
        nextChunk += 1
        if (index == 0 && purpose is TransmissionPurpose.Control) {
            activeControlAttempt?.takeIf { it.id == purpose.attemptID }?.didStartWrite = true
        }
        val writeType = if (target.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) {
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        } else {
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        }
        append(
            "TX-CHUNK",
            "第 ${index + 1}/${transmissionChunks.size} 片，${chunk.size} bytes" +
                " 写类型=${if (writeType == BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) {
                    "带应答"
                } else {
                    "不带应答"
                }}",
            LeapCrypto.toHex(chunk).uppercase(),
        )
        val ok = writeCharacteristic(g, target, chunk, writeType)
        if (!ok) failTransmission("系统拒绝了第 ${index + 1} 个分片的写入")
    }

    @Suppress("DEPRECATION")
    private fun writeCharacteristic(
        g: BluetoothGatt,
        target: BluetoothGattCharacteristic,
        value: ByteArray,
        writeType: Int,
    ): Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        g.writeCharacteristic(target, value, writeType) ==
            android.bluetooth.BluetoothStatusCodes.SUCCESS
    } else {
        target.writeType = writeType
        target.value = value
        g.writeCharacteristic(target)
    }

    private fun completeTransmission(purpose: TransmissionPurpose) {
        transmissionPurpose = null
        transmissionChunks = emptyList()
        nextChunk = 0
        append("TX-FRAME", "${purpose.label}发送完成")
        if (pendingFullAuthenticationFallback) {
            pendingFullAuthenticationFallback = false
            performFullAuthenticationFallback()
            return
        }
        if (purpose is TransmissionPurpose.StraightMove) {
            // 挪车帧没有回执要等，这里只喂看门狗，再把心跳压下来的那一帧放行。
            lastStraightMoveTransmissionAt = SystemClock.elapsedRealtime()
            pendingStraightMoveOrder?.let {
                pendingStraightMoveOrder = null
                queueStraightMove(it)
            }
            return
        }
        startResponseTimeout(purpose)
    }

    private fun failTransmission(message: String) {
        val purpose = transmissionPurpose
        // 写到第几片断的、每片多大、写类型是什么——全在缓冲里，这时候不倒出来就没了。
        BLETrace.replay("写入失败：$message")
        transmissionPurpose = null
        transmissionChunks = emptyList()
        nextChunk = 0
        when (purpose) {
            is TransmissionPurpose.Authentication -> failAuthentication(message)
            TransmissionPurpose.Configuration -> {
                configurationInFlight = null
                append("ERROR", "同步蓝牙钥匙设置失败：$message")
            }
            is TransmissionPurpose.Control -> {
                val didStartWrite = activeControlAttempt?.didStartWrite == true
                pendingControlLabel = null
                finishControlAttempt(
                    if (didStartWrite) {
                        BLEControlAttemptResult.FailedAfterWrite(message)
                    } else {
                        BLEControlAttemptResult.UnavailableBeforeWrite(message)
                    },
                    purpose.attemptID,
                )
                append("ERROR", "发送${purpose.command.label}失败：$message")
            }
            is TransmissionPurpose.StraightMove ->
                emergencyStopStraightMoveIfNeeded("蓝牙写入失败：$message")
            null -> append("ERROR", "发送数据失败：$message")
        }
    }

    private fun startResponseTimeout(purpose: TransmissionPurpose) {
        responseTimeoutJob?.cancel()
        responseTimeoutJob = scope.launch {
            when (purpose) {
                is TransmissionPurpose.Authentication -> {
                    delay(AUTH_TIMEOUT_MS)
                    if (authenticationState == BLEAuthenticationState.Authenticating) {
                        BLETrace.replay("${purpose.mode.label}等车辆应答超时")
                        failAuthentication("${purpose.mode.label}后 10 秒内未收到有效认证响应")
                    }
                }
                TransmissionPurpose.Configuration -> {
                    delay(CONFIG_TIMEOUT_MS)
                    val sent = configurationInFlight
                    configurationInFlight = null
                    runtimeState = if (authenticationState == BLEAuthenticationState.Authenticated) {
                        BLERuntimeState.Ready
                    } else {
                        BLERuntimeState.Recovering
                    }
                    append("CONFIG", "命令 3 已写入，但 8 秒内未收到车辆回复，保留待同步状态")
                    BLETrace.replay("钥匙设置等车辆应答超时")
                    if (sent != null && binding?.configuration != sent) {
                        sendPendingConfigurationIfPossible()
                    }
                }
                // 挪车帧 100ms 一发，没有「等回执」这回事，起超时只会自己打自己。
                is TransmissionPurpose.StraightMove -> return@launch
                is TransmissionPurpose.Control -> {
                    delay(CONTROL_TIMEOUT_MS)
                    if (pendingControlLabel == purpose.command.label) {
                        pendingControlLabel = null
                        finishControlAttempt(
                            BLEControlAttemptResult.SentWithoutConfirmation,
                            purpose.attemptID,
                        )
                        append("CONTROL", "${purpose.command.label}已发送，但 8 秒内未收到车辆动作确认")
                        BLETrace.replay("${purpose.command.label}等车辆确认超时")
                    }
                }
            }
        }
    }

    private fun receive(value: ByteArray) {
        append("RX-CHUNK", "收到 ${value.size} bytes", LeapCrypto.toHex(value).uppercase())
        val frames = reassembler.append(value)
        if (frames.isEmpty() && reassembler.bufferedByteCount > 0) {
            append("REASSEMBLY", "帧尚未收全，已缓存 ${reassembler.bufferedByteCount} bytes")
        }
        frames.forEach { handle(it) }
    }

    private fun handle(frame: LeapBLEFrame) {
        append(
            "RX-FRAME",
            "${frame.kind.label} 声明载荷 ${frame.declaredPayloadLength} bytes",
            frame.logDetail(true),
        )
        val session = cryptoSession
        if (frame.kind == LeapBLEFrameKind.Encrypted && session == null) {
            // 车在发密文，我们手上却没有会话密钥——认证还没完成，或者刚被重置。
            // 不记这行的话，这一帧就是彻底静默地掉在地上。
            append("ERROR", "收到密文但本地没有会话密钥")
        }
        if (frame.kind == LeapBLEFrameKind.Encrypted && session != null) {
            try {
                val plain = session.decrypt(frame)
                append("DECRYPT", "AA AB 解密成功 length=${plain.size}")
                // 挪车途中只允许出现配置回执这一种加密回包。别的都说明车端在跑别的业务，
                // 或者我们跟车已经不同频了——两种情况都不该继续让车走。
                when (val response = LeapBLEDecryptedResponse.from(plain)) {
                    is LeapBLEDecryptedResponse.Authentication -> {
                        completeAuthentication(response.lockState)
                        if (straightMoveState.isPrepared &&
                            authenticationState != BLEAuthenticationState.Authenticated
                        ) {
                            emergencyStopStraightMove("车辆认证状态异常")
                        }
                    }
                    is LeapBLEDecryptedResponse.ReconnectToken ->
                        saveReconnectToken(response.token)
                    is LeapBLEDecryptedResponse.Command -> {
                        val wasConfigurationResponse = configurationInFlight != null
                        append(
                            "DECRYPT",
                            "解析指令回复 identifier=${response.identifier} " +
                                "result=${response.result ?: "(无)"}",
                        )
                        completeConfigurationSync(response.identifier, response.result)
                        if (straightMoveState.isPrepared && !wasConfigurationResponse) {
                            emergencyStopStraightMove("收到非挪车业务响应")
                        }
                    }
                    is LeapBLEDecryptedResponse.Other -> {
                        append("DECRYPT", "解析响应 type=${response.type} fields=${response.fields.size}")
                        if (straightMoveState.isPrepared) {
                            emergencyStopStraightMove("收到未识别的车辆状态")
                        }
                    }
                    null -> {
                        append("DECRYPT", "解密明文不是已知分号响应")
                        if (straightMoveState.isPrepared) {
                            emergencyStopStraightMove("收到未识别的车辆状态")
                        }
                    }
                }
            } catch (e: Exception) {
                append("ERROR", "AA AB 解密失败：${LeapError.messageOf(e)}")
                // 解密失败多半是前面某一片收错或漏收，答案在收包时序里，不在这一帧上。
                BLETrace.replay("解密失败：${LeapError.messageOf(e)}")
                if (straightMoveState.isPrepared) {
                    emergencyStopStraightMove("车辆回包解密失败")
                }
            }
        }

        when (val event = frame.event) {
            is LeapBLEEvent.ErrorResponse -> handleErrorResponse(event.resultCode)
            is LeapBLEEvent.LockOperation -> {
                val confirmed = when (event.operation) {
                    LeapBLEEvent.Operation.Unlock -> LeapBLEControlCommand.Unlock
                    LeapBLEEvent.Operation.Lock -> LeapBLEControlCommand.Lock
                    else -> null
                }
                if (event.trigger == LeapBLEEvent.Trigger.Active &&
                    confirmed != null &&
                    pendingControlLabel == confirmed.label
                ) {
                    responseTimeoutJob?.cancel()
                    responseTimeoutJob = null
                    pendingControlLabel = null
                    finishControlAttempt(
                        BLEControlAttemptResult.Confirmed,
                        activeControlAttempt?.id,
                    )
                    append("CONTROL", "车辆事件确认：${confirmed.label}完成")
                }
                append("EVENT", event.summary)
            }
            null -> Unit
            else -> {
                append("EVENT", event.summary)
                if (straightMoveState.isPrepared) {
                    emergencyStopStraightMove("收到未识别的车辆事件")
                }
            }
        }
    }

    /// 3 / 4 / 7 是车端说「这个重连凭证我不认」。清掉重来一次完整认证即可，
    /// 不要当成认证失败弹给用户——这是正常的凭证轮换。
    private fun handleErrorResponse(resultCode: Int) {
        val tokenInvalid = resultCode == 3 || resultCode == 4 || resultCode == 7
        if (tokenInvalid) {
            invalidateReconnectToken("车辆返回 resultCode=$resultCode，已清除快速重连凭证")
        }
        if (straightMoveState.isPrepared) {
            emergencyStopStraightMove("车辆拒绝控制（$resultCode）")
        }
        when {
            authenticationState == BLEAuthenticationState.Authenticating -> {
                if (tokenInvalid && authenticationMode == AuthenticationMode.Reconnect) {
                    if (transmissionPurpose == null) {
                        performFullAuthenticationFallback()
                    } else {
                        pendingFullAuthenticationFallback = true
                        append("AUTH", "快速重连凭证失效，等待当前写入结束后回退完整认证")
                    }
                } else {
                    failAuthentication("车辆返回 resultCode=$resultCode")
                }
            }
            configurationInFlight != null && binding?.syncState != BLEConfigurationSyncState.Synced -> {
                configurationInFlight = null
                runtimeState = BLERuntimeState.Ready
                append("ERROR", "命令 3 被车辆拒绝：resultCode=$resultCode")
            }
            pendingControlLabel != null -> {
                val label = pendingControlLabel
                responseTimeoutJob?.cancel()
                responseTimeoutJob = null
                pendingControlLabel = null
                finishControlAttempt(
                    BLEControlAttemptResult.FailedAfterWrite("车辆返回 resultCode=$resultCode"),
                    activeControlAttempt?.id,
                )
                append("ERROR", "${label}被车辆拒绝：resultCode=$resultCode")
            }
        }
    }

    // MARK: - 日志

    /// 写一条链路日志。
    ///
    /// `detail` 是帧的十六进制内容——能开车门的密文，只进 [BLETrace] 的内存缓冲，
    /// 且只在 debug 构建回溯时才会露面，正式包里任何时候都不会落到 logcat。
    ///
    /// 高频分类（分片、重组、服务表）由 [BLETrace] 判定，同样只进缓冲：逐条写 logcat
    /// 会把 `DiagLog` 刷爆，真正有用的那几条反而看不见。
    private fun append(category: String, message: String, detail: String = "") {
        if (BLETrace.note(category, message, detail)) {
            DiagLog.note("[ble:$category] $message")
        }
    }

    /// GATT `status` 的中文说法。
    ///
    /// 分得清「谁断的」很要紧：车端主动断（19）说明连接本身是通的、是车端不接受或者
    /// 在等一个没等到的动作；链路超时（8）才是信号和距离的问题；133 则多半根本没连上。
    /// 光看裸码号做不出这个判断，所以直接落在日志里。
    private fun disconnectReasonLabel(status: Int): String = when (status) {
        BluetoothGatt.GATT_SUCCESS -> "status=0 正常断开"
        8 -> "status=8 链路超时，信号弱或离得太远"
        19 -> "status=19 车端主动断开"
        22 -> "status=22 本机主动断开"
        34 -> "status=34 链路层响应超时"
        62 -> "status=62 连接没能建立起来"
        133 -> "status=133 GATT 通用失败，多半是没连上或系统缓存过期"
        else -> "status=$status"
    }

    /// 服务发现没找到 FFFE/FFF2 时，把「我到底连上了谁」记下来。
    ///
    /// 这一步最常见的真相不是协议不对，而是连错了设备——车机的音频模块、上一次绑定
    /// 留下的旧地址、甚至旁边另一台车。光看服务列表分辨不出来，得把连接对象、来源、
    /// 广播里带的服务一起摆出来才有得比。
    private fun logDiscoveryContext() {
        val address = connectedAddress
        append(
            "SERVICE",
            "连接对象 ${address?.let { maskedAddress(it) } ?: "(未知)"}" +
                " 名称=${connectedDeviceName ?: "(无名)"}" +
                " 来源=${if (connectionIntent == ConnectionIntent.Pairing) "配对" else "常驻"}" +
                " 绑定地址=${binding?.deviceAddress?.let { maskedAddress(it) } ?: "(未绑定)"}",
        )
        val advertised = address?.let { advertisements[it] }
        if (advertised == null) {
            append("SERVICE", "这台设备不在本次扫描列表里（按已保存的地址直连）")
            return
        }
        append(
            "SERVICE",
            "广播资料 rssi=${advertised.rssi} connectable=${advertised.isConnectable}" +
                " 带FFFE=${advertised.advertisesTargetService}" +
                " 广播服务=${advertised.serviceUUIDs.ifEmpty { "(无)" }}",
        )
    }

    /// MAC 只留厂商段和尾段：整串 MAC 是能定位到这台车的。
    private fun maskedAddress(address: String): String {
        val parts = address.split(":")
        if (parts.size != 6) return "**"
        return "${parts[0]}:${parts[1]}:**:**:**:${parts[5]}"
    }
}

/// 直进直出的状态机。`isPrepared` 指「这一页正在控制车辆」——出任何岔子都要靠它
/// 决定要不要补发停止帧。
sealed class BLEStraightMoveState {
    data object Idle : BLEStraightMoveState()
    data object Preparing : BLEStraightMoveState()
    data object Ready : BLEStraightMoveState()
    data class Moving(val direction: StraightMoveDirection) : BLEStraightMoveState()
    data object Paused : BLEStraightMoveState()
    data class Failed(val message: String) : BLEStraightMoveState()

    val isPrepared: Boolean get() = this is Ready || this is Moving || this is Paused

    val isMoving: Boolean get() = this is Moving
}

/// 扫描到的候选车辆。
data class BLEDiscoveredDevice(
    val address: String,
    val name: String?,
    val rssi: Int,
) {
    val displayName: String get() = name ?: "未命名设备 ${address.takeLast(5)}"
}

class BLECredentialContext(
    val certificate: LeapBLEKeyCertificate,
    val accountId: String,
    val deviceId: String,
    val vin: String,
)

sealed class BLERuntimeState {
    data object Disabled : BLERuntimeState()
    data object Unbound : BLERuntimeState()
    data object WaitingForBluetooth : BLERuntimeState()
    data object Scanning : BLERuntimeState()
    data object Connecting : BLERuntimeState()
    data object Authenticating : BLERuntimeState()
    data object SyncingConfiguration : BLERuntimeState()
    data object Ready : BLERuntimeState()
    data object Recovering : BLERuntimeState()
    data class NeedsAttention(val message: String) : BLERuntimeState()

    val label: String
        get() = when (this) {
            Disabled -> "已关闭"
            Unbound -> "尚未绑定"
            WaitingForBluetooth -> "等待系统蓝牙"
            Scanning -> "正在搜索车辆"
            Connecting -> "正在连接车辆"
            Authenticating -> "正在认证车辆"
            SyncingConfiguration -> "正在同步设置"
            Ready -> "蓝牙钥匙可用"
            Recovering -> "正在等待车辆"
            is NeedsAttention -> "需要处理"
        }

    val detail: String? get() = (this as? NeedsAttention)?.message
}

sealed class BLEPairingState {
    data object Idle : BLEPairingState()
    data object Scanning : BLEPairingState()
    data class Connecting(val address: String) : BLEPairingState()
    data class Authenticating(val address: String) : BLEPairingState()
    data object Bound : BLEPairingState()
    data class Failed(val message: String) : BLEPairingState()
}

enum class BLELinkState(val label: String) {
    Idle("未连接"),
    Connecting("正在连接"),
    Discovering("正在发现服务"),
    Ready("已就绪"),
    Failed("连接失败"),
}

enum class BLEAuthenticationState {
    MissingCertificate,
    Prepared,
    Authenticating,
    Authenticated,
    Failed,
}

sealed class BLEControlAttemptResult {
    data object Confirmed : BLEControlAttemptResult()
    data object SentWithoutConfirmation : BLEControlAttemptResult()
    data class UnavailableBeforeWrite(val message: String) : BLEControlAttemptResult()
    data class FailedAfterWrite(val message: String) : BLEControlAttemptResult()

    /// 只有「根本没发出去」才该回退 HTTP 远控。写进去了但没确认，再发一次就是重复下发。
    val shouldFallbackToHTTP: Boolean get() = this is UnavailableBeforeWrite
}
