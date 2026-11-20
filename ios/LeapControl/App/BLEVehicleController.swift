@preconcurrency import CoreBluetooth
import CoreLocation
import Foundation
import UIKit
import Observation

struct BLEDiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var serviceUUIDs: [String]
    var isConnectable: Bool
    var lastSeen: Date

    var maskedIdentifier: String {
        let value = id.uuidString
        return "..." + value.suffix(8)
    }

    var advertisesTargetService: Bool {
        serviceUUIDs.contains { CBUUID(string: $0) == CBUUID(string: LeapBLEProtocol.serviceUUID) }
    }
}

enum BLEVehicleRuntimeState: Equatable {
    case disabled
    case unbound
    case waitingForBluetooth
    case scanning
    case connecting
    case authenticating
    case syncingConfiguration
    case ready
    case recovering
    case needsAttention(String)

    var label: String {
        switch self {
        case .disabled: return "已关闭"
        case .unbound: return "尚未绑定"
        case .waitingForBluetooth: return "等待系统蓝牙"
        case .scanning: return "正在搜索车辆"
        case .connecting: return "正在连接车辆"
        case .authenticating: return "正在认证车辆"
        case .syncingConfiguration: return "正在同步设置"
        case .ready: return "蓝牙钥匙可用"
        case .recovering: return "正在等待车辆"
        case .needsAttention: return "需要处理"
        }
    }

    var detail: String? {
        if case .needsAttention(let message) = self { return message }
        return nil
    }
}

enum BLEProximityWakeState: Equatable {
    case disabled
    case needsAlwaysAuthorization
    case monitoring
    case unavailable

    var label: String {
        switch self {
        case .disabled: return "未启用"
        case .needsAlwaysAuthorization: return "需始终允许定位"
        case .monitoring: return "已启用"
        case .unavailable: return "此设备不可用"
        }
    }
}

enum BLEPairingState: Equatable {
    case idle
    case preparing
    case scanning
    case connecting(UUID)
    case authenticating(UUID)
    case bound
    case failed(String)

    var diagnosticPhase: String {
        switch self {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .scanning: return "scanning"
        case .connecting: return "connecting"
        case .authenticating: return "authenticating"
        case .bound: return "bound"
        case .failed: return "failed"
        }
    }

    /// A background eligibility refresh must not tear down a manual pairing that has not
    /// saved its binding yet. Credentials and eligibility must still be exactly the same.
    func preservesConnection(onRefreshFrom current: LeapBLECredentialContext?,
                             to incoming: LeapBLECredentialContext?, eligible: Bool) -> Bool {
        guard eligible, let current, current == incoming else { return false }
        switch self {
        case .scanning, .connecting, .authenticating: return true
        default: return false
        }
    }
}

enum BLEControlAttemptResult: Equatable {
    case confirmed
    case sentWithoutConfirmation
    case unavailableBeforeWrite(String)
    case failedAfterWrite(String)

    var shouldFallbackToHTTP: Bool {
        if case .unavailableBeforeWrite = self { return true }
        return false
    }
}

@Observable
@MainActor
final class BLEVehicleController: NSObject {
    enum StraightMoveState: Equatable {
        case idle
        case preparing
        case ready
        case moving(StraightMoveDirection)
        case paused
        case failed(String)

        var isPrepared: Bool {
            switch self {
            case .ready, .moving, .paused: return true
            default: return false
            }
        }

        var isMoving: Bool {
            if case .moving = self { return true }
            return false
        }
    }

    enum BluetoothState: String {
        case unknown = "未知"
        case resetting = "正在重置"
        case unsupported = "不支持"
        case unauthorized = "未授权"
        case poweredOff = "已关闭"
        case poweredOn = "已开启"
    }

    enum LinkState: String {
        case idle = "未连接"
        case connecting = "连接中"
        case discovering = "发现服务中"
        case subscribing = "订阅通知中"
        case ready = "已订阅"
        case disconnecting = "断开中"
        case failed = "失败"
    }

    enum AuthenticationState: String {
        case missingCertificate = "未同步证书"
        case prepared = "待认证"
        case authenticating = "认证中"
        case authenticated = "已认证"
        case failed = "认证失败"
    }

    enum AuthenticationMode: Equatable {
        case full
        case reconnect

        var label: String {
            switch self {
            case .full: return "完整认证"
            case .reconnect: return "快速重连"
            }
        }
    }

    private enum TransmissionPurpose: Equatable {
        case authentication(AuthenticationMode)
        case configuration
        case control(LeapBLEControlCommand, UUID?)
        case straightMove(StraightMoveOrder)
    }

    private enum ConnectionIntent: Equatable {
        case idle
        case pairing(UUID)
        case managed
    }

    let callCar = CallCarController()

    private static let serviceUUID = CBUUID(string: LeapBLEProtocol.serviceUUID)
    private static let characteristicUUID = CBUUID(string: LeapBLEProtocol.characteristicUUID)
    private static let restorationIdentifier = "org.yipao.app.ble.central"
    var bluetoothState: BluetoothState = .unknown
    var linkState: LinkState = .idle {
        didSet { if oldValue != linkState { BLEDiagnostics.record("key", "link.state=\(linkState)") } }
    }
    var isScanning = false
    var devices: [BLEDiscoveredDevice] = []

    var connectedDeviceName: String?
    var connectedIdentifier: UUID?

    var maximumWriteWithoutResponse = 0
    var maximumWriteWithResponse = 0
    var includeSensitivePayloads = false

    var authenticationState: AuthenticationState = .missingCertificate {
        didSet { if oldValue != authenticationState { BLEDiagnostics.record("key", "auth.state=\(authenticationState)") } }
    }
    var authenticationError: String?
    var certificateFingerprint: String?
    var pendingControlLabel: String?
    var reconnectTokenAvailable = false
    var lastConfirmedControlCommand: LeapBLEControlCommand?
    private(set) var runtimeState: BLEVehicleRuntimeState = .disabled
    private(set) var pairingState: BLEPairingState = .idle
    private(set) var binding: BLEVehicleBinding? {
        didSet {
            syncProximityWakeMonitoring(requestAuthorization: false)
        }
    }
    private(set) var proximityWakeState: BLEProximityWakeState = .disabled
    private(set) var straightMoveState: StraightMoveState = .idle

    var isBound: Bool { binding != nil }
    var isBluetoothControlEnabled: Bool { binding?.isBluetoothControlEnabled == true }
    var isPassiveEntryEnabled: Bool { binding?.isPassiveEntryEnabled == true }
    var autoUnlockEnabled: Bool { binding?.configuration.autoUnlockEnabled == true }
    var autoLockEnabled: Bool { binding?.configuration.autoLockEnabled == true }
    var configurationSyncState: BLEConfigurationSyncState? { binding?.syncState }

    var canControl: Bool {
        linkState == .ready
            && authenticationState == .authenticated
            && transmissionPurpose == nil
            && pendingControlLabel == nil
    }

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var connectedPeripheral: CBPeripheral?
    @ObservationIgnored private var protocolCharacteristic: CBCharacteristic?
    @ObservationIgnored private var reassembler = LeapBLEFrameReassembler()
    @ObservationIgnored private var credentialContext: LeapBLECredentialContext?
    @ObservationIgnored private var cryptoSession: LeapBLECryptoSession?
    @ObservationIgnored private var reconnectToken: String?
    @ObservationIgnored private var authenticationMode: AuthenticationMode?

    // Local counters correlate attempts without exposing peripheral/account identifiers.
    @ObservationIgnored private var diagnosticConnection = 0
    @ObservationIgnored private var diagnosticAuthentication = 0
    @ObservationIgnored private var diagnosticAuthenticationStarted: TimeInterval?
    @ObservationIgnored private var diagnosticAuthSentParts = 0
    @ObservationIgnored private var diagnosticAuthAckedParts = 0
    @ObservationIgnored private var diagnosticAuthTotalParts = 0
    @ObservationIgnored private var rejectedAuthWritePending = false

    private var authenticationTrace: String {
        let elapsed = diagnosticAuthenticationStarted.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) } ?? -1
        return "connection=\(diagnosticConnection) attempt=\(diagnosticAuthentication) elapsedMs=\(elapsed) sent=\(diagnosticAuthSentParts)/\(diagnosticAuthTotalParts) acked=\(diagnosticAuthAckedParts)"
    }

    @ObservationIgnored private var pendingFullAuthenticationFallback = false
    @ObservationIgnored private let reconnectTokenStore = BLEReconnectTokenStore()
    @ObservationIgnored private let bindingStore = BLEVehicleBindingStore()
    @ObservationIgnored private let proximityWakeMonitor = BLEProximityWakeMonitor()
    @ObservationIgnored private var productionEligible = false
    @ObservationIgnored private var applicationIsActive = true
    @ObservationIgnored private var connectionIntent: ConnectionIntent = .idle
    @ObservationIgnored private var restoredPeripherals: [CBPeripheral] = []
    /// 上一次武装时钥匙串「读不到」（非 notFound 的 OSStatus）。此时绝不能拆绑定
    /// 和恢复来的连接——那可能只是重启未解锁的窗口。调用方看到它为 true 要安排重试。
    @ObservationIgnored private(set) var armBlockedByKeychain = false
    /// 挂起态下收到 CB 事件时踢上层再试一轮武装。重试梯只有四个 tick，进程被系统
    /// 挂起再唤醒时可能已全部到期烧完，解锁通知又不保证补投——那之后车端的
    /// 连接/断开事件就是仅剩的重开时机，不给这条通道感应解锁会一直死到前台打开。
    @ObservationIgnored var onArmingStalledEvent: (() -> Void)?
    @ObservationIgnored var onProximityWakeEvent: (() -> Void)?
    @ObservationIgnored var onProtocolVersionNeeded: ((String, String) -> Void)?
    /// 绑定未就绪时挂起的恢复连接的看门狗：武装迟迟不完成就统一断开，
    /// 别让没人认领的连接一直占着车端。
    @ObservationIgnored private var restorationHoldTask: Task<Void, Never>?
    @ObservationIgnored private var connectionEpoch = 0
    @ObservationIgnored private var configurationInFlight: LeapBLEConfiguration?
    @ObservationIgnored private var activeControlAttempt: (id: UUID, didStartWrite: Bool)?
    @ObservationIgnored private var completedControlAttempt: (id: UUID, result: BLEControlAttemptResult)?
    @ObservationIgnored private var transmissionPurpose: TransmissionPurpose?
    @ObservationIgnored private var transmissionFrame: Data?
    @ObservationIgnored private var transmissionChunks: [Data] = []
    @ObservationIgnored private var nextTransmissionChunk = 0
    @ObservationIgnored private var transmissionWriteType: CBCharacteristicWriteType = .withResponse
    @ObservationIgnored private var responseTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTimeoutTask: Task<Void, Never>?

    @ObservationIgnored private var straightMoveHeartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var straightMoveWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var straightMoveStopTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStraightMoveOrder: StraightMoveOrder?
    @ObservationIgnored private var lastStraightMoveTransmissionAt: ContinuousClock.Instant?

    override init() {
        BLEInstallationGuard.prepareIfNeeded()
        super.init()
        proximityWakeMonitor.onStateChange = { [weak self] state in
            self?.proximityWakeState = state
        }
        proximityWakeMonitor.onWake = { [weak self] source in
            guard let self else { return }
            BLEDiagnostics.record("key", "proximity.wake source=\(source)")
            self.onProximityWakeEvent?()
        }
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier
            ]
        )
    }

    func configure(credentialContext: LeapBLECredentialContext?) {
        BLEDiagnostics.record("key", "context.configure certificate=\(credentialContext != nil)")
        guard self.credentialContext != credentialContext else { return }
        let previousAccountId = self.credentialContext?.accountId
        let previousVIN = self.credentialContext?.vin
        if previousAccountId != credentialContext?.accountId || previousVIN != credentialContext?.vin { cloudProtocolVersion = nil }
        callCar.configure(credentialContext)
        self.credentialContext = credentialContext
        cryptoSession = nil
        authenticationMode = nil
        lastConfirmedControlCommand = nil
        pendingFullAuthenticationFallback = false
        authenticationError = nil
        pendingControlLabel = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        if previousVIN != nil,
           (previousVIN != credentialContext?.vin || previousAccountId != credentialContext?.accountId),
           let peripheral = connectedPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        guard let credentialContext else {
            certificateFingerprint = nil
            reconnectToken = nil
            reconnectTokenAvailable = false
            authenticationState = .missingCertificate
            return
        }
        let storedToken = reconnectTokenStore.load(
            accountId: credentialContext.accountId,
            vin: credentialContext.vin
        )
        if let storedToken, (try? LeapBLEProtocol.decodeReconnectToken(storedToken)) != nil {
            reconnectToken = storedToken
            reconnectTokenAvailable = true
        } else {
            if storedToken != nil {
                reconnectTokenStore.clear(
                    accountId: credentialContext.accountId,
                    vin: credentialContext.vin
                )
            }
            reconnectToken = nil
            reconnectTokenAvailable = false
        }
        certificateFingerprint = credentialContext.certificate.fingerprint
        authenticationState = .prepared
    }

    /// 绑定和资格（非演示态）都通过后才维持生产连接。
    ///
    /// `credentialUnreadable` 表示证书钥匙串这一刻「读不到」而非「没有」（重启未解锁
    /// 的窗口）。那时手里已有的证书继续用；手里也没有就保持现状等重试，
    /// 绝不能按「缺证书」把绑定和恢复来的连接拆掉。
    func configureProduction(
        credentialContext: LeapBLECredentialContext?,
        eligible: Bool,
        credentialUnreadable: Bool = false
    ) {
        productionEligible = eligible
        let effectiveContext = (credentialUnreadable && credentialContext == nil)
            ? self.credentialContext
            : credentialContext
        if pairingState.preservesConnection(onRefreshFrom: self.credentialContext,
                                            to: effectiveContext, eligible: eligible) {
            BLEDiagnostics.record("key", "context.refresh.preservePairing state=\(pairingState.diagnosticPhase)")
            return
        }
        configure(credentialContext: effectiveContext)

        guard eligible else {
            binding = nil
            armBlockedByKeychain = false
            runtimeState = .disabled
            // 确定无资格，挂起的恢复连接也没有等下去的意义。
            rejectUnclaimedRestoration()
            stopManagedConnection()
            return
        }
        guard let credentialContext = effectiveContext else {
            if credentialUnreadable {
                armBlockedByKeychain = true
                runtimeState = .recovering
                return
            }
            binding = nil
            armBlockedByKeychain = false
            runtimeState = .needsAttention("缺少当前车辆的蓝牙证书")
            // 确定态的拆除都要回收挂起的恢复连接，不能留给 45 秒看门狗：
            // 重装清库后走到这里时，App 已判定「无证书」，没理由再挂着车端连接。
            rejectUnclaimedRestoration()
            stopManagedConnection()
            return
        }
        guard credentialContext.certificate.isSupportedKeyType else {
            binding = nil
            runtimeState = .needsAttention(
                "当前蓝牙证书类型不受支持（keyType=\(credentialContext.certificate.keyType)）"
            )
            rejectUnclaimedRestoration()
            stopManagedConnection()
            return
        }
        guard credentialContext.certificate.hasValidPasswordCard else {
            binding = nil
            runtimeState = .needsAttention("当前蓝牙证书的 passwordCard 无效，请重新同步")
            rejectUnclaimedRestoration()
            stopManagedConnection()
            return
        }

        var stored: BLEVehicleBinding?
        switch bindingStore.loadOutcome(
            accountId: credentialContext.accountId,
            vin: credentialContext.vin
        ) {
        case .found(let value):
            armBlockedByKeychain = false
            stored = value
        case .missing:
            armBlockedByKeychain = false
            stored = nil
        case .failure:
            armBlockedByKeychain = true
            guard let current = binding,
                  current.accountId == credentialContext.accountId,
                  current.vin == credentialContext.vin else {
                // 绑定既不在手也读不出来：挂起等重试，别把恢复来的连接当过期拆掉。
                runtimeState = .recovering
                return
            }
            // 内存里这份还热着，跳过持久层直接沿用。
            stored = current
        }
        if var value = stored,
           value.certificateFingerprint != credentialContext.certificate.fingerprint {
            reconnectTokenStore.clear(accountId: value.accountId, vin: value.vin)
            reconnectToken = nil
            reconnectTokenAvailable = false
            value.certificateFingerprint = credentialContext.certificate.fingerprint
            value.syncState = value.configuration.isEnabled ? .pending : .pendingDisable
            value.lastVerifiedAt = nil
            _ = bindingStore.save(value)
            stored = value
        }
        binding = stored

        guard let binding else {
            rejectUnclaimedRestoration()
            stopManagedConnection()
            runtimeState = .unbound
            return
        }
        guard binding.shouldMaintainConnection else {
            runtimeState = .disabled
            stopManagedConnection()
            return
        }

        adoptRestoredPeripheralIfPossible()
        ensureManagedConnection()
    }

    /// 登录态还「未知」（钥匙串锁着读不到，或读到了但内存会话还没恢复）时的挂起
    /// 入口：`configureProduction` 的任何一条路都会把「未知」当「否」执行拆除，
    /// 所以那时不能进它。这里只举旗等重试/解锁通知，`didConnect` 见旗会把恢复的
    /// 连接挂起而不是拆掉。
    func suspendArming(message: String) {
        guard !armBlockedByKeychain else { return }
        armBlockedByKeychain = true
        runtimeState = .recovering
    }

    func setApplicationActive(_ active: Bool) {
        BLEDiagnostics.record("key", "foreground=\(active)")
        applicationIsActive = active
        syncProximityWakeMonitoring(requestAuthorization: active)
        if !active {
            if straightMoveState.isPrepared {
                emergencyStopStraightMove(reason: "App 已离开前台")
            }
            if pairingState == .scanning { cancelPairing() }
        } else if active {
            ensureManagedConnection()
        }
    }

    func requestProximityWakeAuthorization() {
        syncProximityWakeMonitoring(requestAuthorization: true)
    }

    /// 等待现有生产 BLE 会话连接并完成认证。直进直出不创建第二个 central manager。
    func prepareStraightMove(timeout: Duration = .seconds(50)) async throws {
        guard productionEligible else { throw LeapError.server("当前环境不能使用直进直出") }
        guard binding?.isBluetoothControlEnabled == true else {
            throw LeapError.server("请先绑定并开启蓝牙钥匙")
        }
        guard applicationIsActive else { throw LeapError.server("请保持 App 在前台") }
        guard bluetoothState == .poweredOn else { throw LeapError.server("请先打开手机蓝牙") }

        straightMoveState = .preparing
        ensureManagedConnection()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !canControl, clock.now < deadline {
            guard applicationIsActive else {
                straightMoveState = .failed("App 已离开前台")
                throw LeapError.server("请保持 App 在前台")
            }
            if case .needsAttention(let message) = runtimeState {
                straightMoveState = .failed(message)
                throw LeapError.server(message)
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard canControl else {
            straightMoveState = .failed("车辆蓝牙连接或认证未就绪")
            throw LeapError.server("靠近车辆后重试，蓝牙连接需在 50 秒内完成")
        }
        straightMoveState = .ready
    }

    /// 按下后立即发送一帧，并以 100ms 周期持续发送。调用方必须在松手时调用 stop。
    func startStraightMove(_ direction: StraightMoveDirection) throws {
        guard applicationIsActive else { throw LeapError.server("请保持 App 在前台") }
        guard straightMoveState.isPrepared, canControl, cryptoSession != nil else {
            throw LeapError.server("直进直出尚未就绪")
        }
        straightMoveStopTask?.cancel()
        straightMoveStopTask = nil
        let order = StraightMoveOrder(direction: direction)
        straightMoveState = .moving(direction)
        queueStraightMove(order)
        straightMoveHeartbeatTask?.cancel()
        straightMoveHeartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self,
                      self.applicationIsActive,
                      self.straightMoveState == .moving(direction) else { return }
                self.queueStraightMove(order)
            }
        }
        let clock = ContinuousClock()
        lastStraightMoveTransmissionAt = clock.now
        straightMoveWatchdogTask?.cancel()
        straightMoveWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self,
                      self.straightMoveState == .moving(direction),
                      let last = self.lastStraightMoveTransmissionAt else { return }
                if last.duration(to: clock.now) > .milliseconds(350) {
                    self.emergencyStopStraightMove(reason: "控制心跳中断")
                    return
                }
            }
        }
    }

    /// 松手停止。停止帧会立即排到当前 GATT 写入之后，并短间隔补发三次。
    func stopStraightMove() {
        stopStraightMove(markFailed: nil)
    }

    /// 页面退出时先停止，再结束本次控制状态；共享蓝牙钥匙连接继续由全局控制器维护。
    func closeStraightMove() {
        guard straightMoveState != .idle else { return }
        straightMoveHeartbeatTask?.cancel()
        straightMoveHeartbeatTask = nil
        straightMoveWatchdogTask?.cancel()
        straightMoveWatchdogTask = nil
        straightMoveState = .paused
        pendingStraightMoveOrder = .stop
        queueStraightMove(.stop)
        straightMoveStopTask?.cancel()
        straightMoveStopTask = Task { @MainActor [weak self] in
            for _ in 0..<2 {
                try? await Task.sleep(for: .milliseconds(70))
                guard !Task.isCancelled, let self else { return }
                self.queueStraightMove(.stop)
            }
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self else { return }
            self.pendingStraightMoveOrder = nil
            self.straightMoveState = .idle
        }
    }

    private func emergencyStopStraightMove(reason: String) {
        stopStraightMove(markFailed: reason)
    }

    private func stopStraightMove(markFailed reason: String?) {
        straightMoveHeartbeatTask?.cancel()
        straightMoveHeartbeatTask = nil
        straightMoveWatchdogTask?.cancel()
        straightMoveWatchdogTask = nil
        pendingStraightMoveOrder = .stop
        straightMoveState = reason.map(StraightMoveState.failed) ?? .paused
        queueStraightMove(.stop)
        straightMoveStopTask?.cancel()
        straightMoveStopTask = Task { @MainActor [weak self] in
            for _ in 0..<2 {
                try? await Task.sleep(for: .milliseconds(70))
                guard !Task.isCancelled, let self else { return }
                self.queueStraightMove(.stop)
            }
        }
    }

    private func queueStraightMove(_ order: StraightMoveOrder) {
        guard authenticationState == .authenticated, let cryptoSession else {
            emergencyStopStraightMoveIfNeeded(reason: "蓝牙认证已失效")
            return
        }
        guard transmissionPurpose == nil else {
            // 停止永远覆盖移动心跳；移动心跳只保留最新一帧，避免写队列积压后盲走。
            if order == .stop || pendingStraightMoveOrder != .stop {
                pendingStraightMoveOrder = order
            }
            return
        }
        do {
            pendingStraightMoveOrder = nil
            let frame = try cryptoSession.straightMoveFrame(order: order)
            try beginTransmission(frame, purpose: .straightMove(order))
        } catch {
            emergencyStopStraightMoveIfNeeded(reason: error.localizedDescription)
        }
    }

    private func emergencyStopStraightMoveIfNeeded(reason: String) {
        guard straightMoveState.isPrepared else { return }
        straightMoveHeartbeatTask?.cancel()
        straightMoveHeartbeatTask = nil
        straightMoveWatchdogTask?.cancel()
        straightMoveWatchdogTask = nil
        pendingStraightMoveOrder = .stop
        if transmissionPurpose == nil,
           authenticationState == .authenticated,
           let cryptoSession,
           let frame = try? cryptoSession.straightMoveFrame(order: .stop) {
            pendingStraightMoveOrder = nil
            try? beginTransmission(frame, purpose: .straightMove(.stop))
        }
        straightMoveState = .failed(reason)
    }

    func beginPairing() {
        BLEDiagnostics.record("key", "pair.begin bluetooth=\(bluetoothState) certificate=\(credentialContext != nil)")
        guard productionEligible else {
            pairingState = .failed("请先登录并选择车辆")
            return
        }
        guard applicationIsActive else {
            pairingState = .failed("请回到 App 前台后搜索车辆")
            return
        }
        guard let credentialContext else {
            pairingState = .failed("请先同步当前车辆的蓝牙证书")
            return
        }
        guard credentialContext.certificate.isSupportedKeyType else {
            pairingState = .failed(
                "当前蓝牙证书类型不受支持（keyType=\(credentialContext.certificate.keyType)）"
            )
            return
        }
        guard credentialContext.certificate.hasValidPasswordCard else {
            pairingState = .failed("当前蓝牙证书的 passwordCard 无效，请重新同步")
            return
        }
        guard bluetoothState == .poweredOn else {
            runtimeState = .waitingForBluetooth
            switch bluetoothState {
            case .unknown, .resetting:
                pairingState = .preparing
            case .poweredOff:
                pairingState = .failed("请先打开手机蓝牙")
            case .unauthorized:
                pairingState = .failed("请在系统设置中允许壹跑使用蓝牙")
            case .unsupported:
                pairingState = .failed("这台设备不支持低功耗蓝牙")
            case .poweredOn:
                break
            }
            return
        }

        if let peripheral = connectedPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        stopScan()
        devices.removeAll()
        peripherals.removeAll()

        BLEDiagnostics.record("key", "scan.start service=\(Self.serviceUUID)")
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        pairingState = .scanning
        runtimeState = .scanning
        schedulePairingScanTimeout()
    }

    func pair(to id: UUID) {
        BLEDiagnostics.record("key", "pair.select known=\(peripherals[id] != nil)")
        guard pairingState == .scanning, peripherals[id] != nil else {
            pairingState = .failed("候选车辆已经离开扫描范围")
            return
        }
        pairingState = .connecting(id)
        connect(to: id, intent: .pairing(id))
        schedulePairingConnectionTimeout(for: id, epoch: connectionEpoch)
    }

    @ObservationIgnored private(set) var pairingPreparationGeneration = 0

    func cancelPairing() {
        pairingPreparationGeneration += 1
        BLEDiagnostics.record("key", "pair.cancel")
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        stopScan()
        if case .pairing = connectionIntent, let peripheral = connectedPeripheral {
            central.cancelPeripheralConnection(peripheral)
            resetVolatileConnectionState()
        }
        pairingState = .idle
        if binding?.shouldMaintainConnection == true {
            ensureManagedConnection()
        } else if binding == nil {
            runtimeState = .unbound
        }
    }

    func setBluetoothControlEnabled(_ enabled: Bool) {
        guard var binding else { return }
        binding.configuration.isEnabled = enabled
        if !enabled {
            binding.configuration.autoUnlockEnabled = false
            binding.configuration.autoLockEnabled = false
            binding.syncState = .pendingDisable
        } else {
            binding.syncState = .pending
            binding.removeAfterDisable = false
        }
        persistAndApply(binding)
    }

    func updatePassiveEntry(autoUnlock: Bool, autoLock: Bool) {
        guard var binding else { return }
        binding.configuration.isEnabled = true
        binding.configuration.autoUnlockEnabled = autoUnlock
        binding.configuration.autoLockEnabled = autoLock
        binding.syncState = .pending
        binding.removeAfterDisable = false
        persistAndApply(binding)
        syncProximityWakeMonitoring(requestAuthorization: applicationIsActive)
    }

    func setUnlockDistance(_ distance: BLEUnlockDistance) {
        guard var binding else { return }
        let previous = binding.configuration
        binding.configuration.setUnlockDistance(distance)
        BLEDiagnostics.record("key", "distance.selected before={\(BLEDiagnostics.configurationSummary(previous))} after={\(BLEDiagnostics.configurationSummary(binding.configuration))} authenticated=\(authenticationState == .authenticated) inFlight=\(configurationInFlight != nil) busy=\(transmissionPurpose != nil || pendingControlLabel != nil)")
        binding.syncState = binding.configuration.isEnabled ? .pending : .pendingDisable
        persistAndApply(binding)
    }

    func applyCalibration(_ calibration: BLECalibration, accountId: String, vin: String) {
        guard var binding, binding.accountId == accountId, binding.vin == vin else { return }
        let updated = calibration.applying(to: binding.configuration)
        BLEDiagnostics.record("key", "calibration.apply changed=\(updated != binding.configuration) before={\(BLEDiagnostics.configurationSummary(binding.configuration))} after={\(BLEDiagnostics.configurationSummary(updated))}")
        guard updated != binding.configuration else { return }
        binding.configuration = updated
        binding.syncState = updated.isEnabled ? .pending : .pendingDisable
        persistAndApply(binding)
    }

    func removeBinding() {
        guard var binding else { return }
        binding.configuration.isEnabled = false
        binding.configuration.autoUnlockEnabled = false
        binding.configuration.autoLockEnabled = false
        binding.syncState = .pendingDisable
        binding.removeAfterDisable = true
        persistAndApply(binding)
    }

    func deactivate(clearBinding: Bool) {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        stopScan()
        productionEligible = false
        pairingState = .idle
        runtimeState = .disabled
        if clearBinding {
            // 退出登录时内存 binding 可能已经因资格或证书变化被清空，仍须删除全部持久项。
            bindingStore.clearAll()
            reconnectTokenStore.clearAll()
        }
        binding = nil
        armBlockedByKeychain = false
        // 退登/换车是确定性的意图，挂着等武装的恢复连接不能再留到看门狗到期。
        rejectUnclaimedRestoration()
        stopManagedConnection(includeIdle: true)
        configure(credentialContext: nil)
    }

    /// 首页锁车/解锁优先走这里。只有控制帧首个字节尚未写入时，调用方才可回退 HTTP。
    func performControl(
        _ command: LeapBLEControlCommand,
        connectionTimeout: Duration = .seconds(6)
    ) async -> BLEControlAttemptResult {
        guard productionEligible, binding?.isBluetoothControlEnabled == true else {
            return .unavailableBeforeWrite("蓝牙钥匙未启用")
        }
        ensureManagedConnection()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: connectionTimeout)
        while !canControl, clock.now < deadline {
            if case .needsAttention(let message) = runtimeState {
                return .unavailableBeforeWrite(message)
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard canControl else {
            return .unavailableBeforeWrite("车辆蓝牙连接或认证未就绪")
        }

        let attemptID = UUID()
        completedControlAttempt = nil
        activeControlAttempt = (attemptID, false)
        do {
            guard let cryptoSession else {
                activeControlAttempt = nil
                return .unavailableBeforeWrite("蓝牙会话密钥不可用")
            }
            let frame = try cryptoSession.controlFrame(command: command)
            lastConfirmedControlCommand = nil
            pendingControlLabel = command.label
            try beginTransmission(frame, purpose: .control(command, attemptID))
        } catch {
            activeControlAttempt = nil
            pendingControlLabel = nil
            return .unavailableBeforeWrite(error.localizedDescription)
        }

        let resultDeadline = clock.now.advanced(by: .seconds(9))
        while clock.now < resultDeadline {
            if let completedControlAttempt, completedControlAttempt.id == attemptID {
                self.completedControlAttempt = nil
                activeControlAttempt = nil
                return completedControlAttempt.result
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        let didStartWrite = activeControlAttempt?.didStartWrite == true
        activeControlAttempt = nil
        pendingControlLabel = nil
        return didStartWrite
            ? .sentWithoutConfirmation
            : .unavailableBeforeWrite("蓝牙控制帧未能开始写入")
    }

    func authenticate(forceFull: Bool = false) {
        BLEDiagnostics.record("key", "auth.request forceFull=\(forceFull) link=\(linkState) tokenAvailable=\(reconnectToken != nil) knownMinor=\(resolvedProtocolMinor.map(String.init) ?? "unknown")")
        guard !rejectedAuthWritePending, linkState == .ready,
              connectedPeripheral != nil,
              protocolCharacteristic != nil else {
            return
        }
        guard let credentialContext else {
            authenticationState = .missingCertificate
            return
        }
        guard let version = resolvedProtocolMinor else {
            BLEDiagnostics.record("key", "auth.blocked version.unknown; refusing implicit 1.8")
            failAuthentication("尚未取得车辆蓝牙协议版本，联网后会自动重试")
            onProtocolVersionNeeded?(credentialContext.accountId, credentialContext.vin)
            return
        }
        BLEDiagnostics.record("key", "version.selected=1.\(version) cloud=\(cloudProtocolVersion != nil) advertised=\(LeapBLEProtocol.advertisedProtocolMinor(serviceUUIDs: devices.first { $0.id == connectedIdentifier }?.serviceUUIDs ?? []) != nil)")
        do {
            let session = try LeapBLECryptoSession.make(
                certificate: credentialContext.certificate,
                vin: credentialContext.vin
            )
            let mode: AuthenticationMode
            let frame: Data
            if !forceFull, let reconnectToken {
                mode = .reconnect
                frame = try session.reconnectAuthenticationFrame(
                    token: reconnectToken,
                    accountId: credentialContext.accountId,
                    configuration: activeConfiguration,
                    pre17: negotiatedProtocolMinor < 7, protocolMinor: negotiatedProtocolMinor
                )
            } else {
                mode = .full
                frame = try session.fullAuthenticationFrame(
                    certificate: credentialContext.certificate,
                    accountId: credentialContext.accountId,
                    deviceId: credentialContext.deviceId,
                    configuration: activeConfiguration, protocolMinor: negotiatedProtocolMinor
                )
            }
            diagnosticAuthentication += 1
            diagnosticAuthenticationStarted = ProcessInfo.processInfo.systemUptime
            diagnosticAuthSentParts = 0
            diagnosticAuthAckedParts = 0
            diagnosticAuthTotalParts = 0
            BLEDiagnostics.record("key", "auth.structure \(authenticationTrace) publicKeyBytes=\(session.publicKey.count) frameBytes=\(frame.count) capability=\(mode == .full ? frame.suffix(2).hexString : "reconnect") certificateFields=\(credentialContext.certificate.plainText.components(separatedBy: ";").count)")
            cryptoSession = session
            authenticationMode = mode
            BLEDiagnostics.record("key", "auth.start mode=\(mode.label) frameBytes=\(frame.count) protocolMinor=\(negotiatedProtocolMinor) keyType=\(credentialContext.certificate.keyType) accountPresent=\(!credentialContext.accountId.isEmpty) devicePresent=\(!credentialContext.deviceId.isEmpty)")
            lastConfirmedControlCommand = nil
            authenticationState = .authenticating
            runtimeState = .authenticating
            if case .pairing(let id) = connectionIntent {
                pairingTimeoutTask?.cancel()
                pairingTimeoutTask = nil
                pairingState = .authenticating(id)
            }
            authenticationError = nil
            try beginTransmission(frame, purpose: .authentication(mode))
        } catch {
            failAuthentication(error.localizedDescription)
        }
    }

    func stopScan() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
    }

    private func connect(to id: UUID, intent: ConnectionIntent) {
        BLEDiagnostics.record("key", "connect.request known=\(peripherals[id] != nil)")
        guard let peripheral = peripherals[id] else {
            return
        }
        if let current = connectedPeripheral, current.identifier != id {
            central.cancelPeripheralConnection(current)
        }
        stopScan()
        connectionIntent = intent
        connectionEpoch += 1
        configurationInFlight = nil
        reassembler.reset()
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        cryptoSession = nil
        authenticationMode = nil
        pendingFullAuthenticationFallback = false
        authenticationError = nil
        authenticationState = credentialContext == nil ? .missingCertificate : .prepared
        pendingControlLabel = nil
        transmissionPurpose = nil
        transmissionFrame = nil
        transmissionChunks.removeAll(keepingCapacity: true)
        protocolCharacteristic = nil
        connectedPeripheral = peripheral
        connectedIdentifier = id

        connectedDeviceName = peripheral.name ?? devices.first(where: { $0.id == id })?.name

        maximumWriteWithoutResponse = 0
        maximumWriteWithResponse = 0
        linkState = .connecting
        runtimeState = .connecting
        peripheral.delegate = self
        let options: [String: Any]?
        if intent == .managed {
            options = [CBConnectPeripheralOptionEnableAutoReconnect: true]
        } else {
            options = nil
        }
        central.connect(peripheral, options: options)
    }

    private func schedulePairingScanTimeout() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled,
                  let self,
                  self.pairingState == .scanning else { return }
            self.stopScan()
            self.pairingState = .failed("附近没有发现可绑定车辆，请靠近车辆后重试")
            self.runtimeState = .needsAttention("未发现车辆")
        }
    }

    private func schedulePairingConnectionTimeout(for identifier: UUID, epoch: Int) {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled,
                  let self,
                  self.connectionEpoch == epoch,
                  self.pairingState == .connecting(identifier) else { return }
            if let peripheral = self.connectedPeripheral,
               peripheral.identifier == identifier {
                self.central.cancelPeripheralConnection(peripheral)
            }
            self.pairingState = .failed("连接车辆超时，请确认车辆已唤醒后重试")
            self.runtimeState = .needsAttention("连接车辆超时")
        }
    }

    private var activeConfiguration: LeapBLEConfiguration {
        switch connectionIntent {
        case .pairing:
            return .manualControl
        case .managed:
            return binding?.configuration ?? .manualControl
        case .idle:
            return .manualControl
        }
    }

    private func persistAndApply(_ value: BLEVehicleBinding) {
        guard bindingStore.save(value) else {
            BLEDiagnostics.record("key", "configuration.localSave.failed \(BLEDiagnostics.configurationSummary(value.configuration))")
            runtimeState = .needsAttention("蓝牙钥匙设置写入钥匙串失败")
            return
        }
        binding = value
        BLEDiagnostics.record("key", "configuration.localSave.success pending=true \(BLEDiagnostics.configurationSummary(value.configuration))")
        if authenticationState == .authenticated {
            sendPendingConfigurationIfPossible()
        } else {
            ensureManagedConnection()
        }
    }

    private var cloudProtocolVersion: (accountId: String, vin: String, minor: Int)?

    func configureProtocolVersion(_ minor: Int, accountId: String, vin: String) {
        guard credentialContext?.accountId == accountId, credentialContext?.vin == vin,
              (0...255).contains(minor) else { return }
        cloudProtocolVersion = (accountId, vin, minor)
        BLEDiagnostics.record("key", "version.cloud profileMinor=\(minor)")
        // Version fetch can finish after notification subscription. Resume this connection
        // without requiring another disconnect or a fresh pairing flow.
        if linkState == .ready, authenticationState != .authenticating,
           authenticationState != .authenticated, transmissionPurpose == nil {
            BLEDiagnostics.record("key", "version.ready resumeAuthentication=true")
            authenticate()
        }
    }

    func needsCloudProtocolVersion(accountId: String, vin: String) -> Bool {
        guard credentialContext?.accountId == accountId, credentialContext?.vin == vin else { return false }
        return cloudProtocolVersion?.accountId != accountId || cloudProtocolVersion?.vin != vin
    }

    private var resolvedProtocolMinor: Int? {
        let savedVersion = binding.flatMap {
            $0.peripheralIdentifier == connectedIdentifier ? $0.protocolMinor : nil
        }
        let cloud = cloudProtocolVersion.flatMap {
            $0.accountId == credentialContext?.accountId && $0.vin == credentialContext?.vin ? $0.minor : nil
        }
        return LeapBLEProtocol.resolvedProtocolMinor(cloud: cloud,
            advertisedServices: devices.first { $0.id == connectedIdentifier }?.serviceUUIDs ?? [],
            verified: savedVersion)
    }

    // Only used after authenticate has required a known version.
    private var negotiatedProtocolMinor: Int { resolvedProtocolMinor ?? 8 }

    private func sendPendingConfigurationIfPossible() {
        guard var binding,
              binding.syncState != .synced,
              configurationInFlight == nil,
              authenticationState == .authenticated,
              let cryptoSession,
              transmissionPurpose == nil,
              pendingControlLabel == nil else { return }
        do {
            let frame = try cryptoSession.configurationFrame(binding.configuration, protocolMinor: negotiatedProtocolMinor)
            configurationInFlight = binding.configuration
            runtimeState = .syncingConfiguration
            BLEDiagnostics.record("key", "configuration.send cmd=3 \(BLEDiagnostics.configurationSummary(binding.configuration, protocolMinor: negotiatedProtocolMinor))")
            try beginTransmission(frame, purpose: .configuration)
        } catch {
            BLEDiagnostics.record("key", "configuration.send.failed \(BLEDiagnostics.failureDetail(error))")
            configurationInFlight = nil
            binding.syncState = binding.configuration.isEnabled ? .pending : .pendingDisable
            self.binding = binding
            _ = bindingStore.save(binding)
        }
    }

    private func completeConfigurationSync(identifier: String, result: String?) {
        if identifier == "3" {
            BLEDiagnostics.record("key", "configuration.ack cmd=3 result=\(BLEDiagnostics.safeMessage(result ?? "nil")) inFlight=\(configurationInFlight != nil)")
        }
        guard var binding,
              binding.syncState != .synced,
              let sentConfiguration = configurationInFlight,
              identifier == "3" else { return }
        configurationInFlight = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        guard result == "00" || result == "0" else {
            BLEDiagnostics.record("key", "configuration.rejected sent={\(BLEDiagnostics.configurationSummary(sentConfiguration))}")
            runtimeState = .needsAttention("车辆未接受钥匙设置，请重新连接后重试")
            return
        }

        guard binding.configuration == sentConfiguration else {
            BLEDiagnostics.record("key", "configuration.ack.stale resend=true sent={\(BLEDiagnostics.configurationSummary(sentConfiguration))} current={\(BLEDiagnostics.configurationSummary(binding.configuration))}")
            self.binding = binding
            _ = bindingStore.save(binding)
            runtimeState = .ready
            sendPendingConfigurationIfPossible()
            return
        }

        binding.syncState = .synced
        self.binding = binding
        guard bindingStore.save(binding) else {
            BLEDiagnostics.record("key", "configuration.confirmed.localSave.failed \(BLEDiagnostics.configurationSummary(sentConfiguration))")
            runtimeState = .needsAttention("车辆已接收设置，但本机状态保存失败")
            return
        }

        BLEDiagnostics.record("key", "configuration.synced vehicleAccepted=true \(BLEDiagnostics.configurationSummary(sentConfiguration))")
        if !binding.configuration.isEnabled {
            if binding.removeAfterDisable {
                bindingStore.clear(accountId: binding.accountId, vin: binding.vin)
                reconnectTokenStore.clear(accountId: binding.accountId, vin: binding.vin)
                self.binding = nil
                pairingState = .idle
                runtimeState = .unbound
            } else {
                runtimeState = .disabled
            }
            stopManagedConnection()
        } else {
            runtimeState = .ready
        }
    }

    private func completePairingIfNeeded() {
        guard case .pairing(let candidateID) = connectionIntent,
              connectedPeripheral?.identifier == candidateID,
              let credentialContext else { return }
        var value = BLEVehicleBinding(
            accountId: credentialContext.accountId,
            vin: credentialContext.vin,
            peripheralIdentifier: candidateID,
            certificateFingerprint: credentialContext.certificate.fingerprint,
            configuration: .manualControl,
            syncState: .pending,
            removeAfterDisable: false,
            lastVerifiedAt: .now
        )
        value.protocolMinor = negotiatedProtocolMinor
        guard bindingStore.save(value) else {
            pairingState = .failed("车辆认证成功，但绑定信息写入钥匙串失败")
            runtimeState = .needsAttention("绑定信息无法安全保存")
            return
        }
        binding = value
        connectionIntent = .managed
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        pairingState = .bound
        runtimeState = .ready
        sendPendingConfigurationIfPossible()
    }

    private func updateBindingVerification() {
        guard var binding, let credentialContext else { return }
        if binding.protocolMinor != negotiatedProtocolMinor, binding.syncState == .synced { binding.syncState = .pending }
        binding.protocolMinor = negotiatedProtocolMinor
        binding.lastVerifiedAt = .now
        binding.certificateFingerprint = credentialContext.certificate.fingerprint
        self.binding = binding
        _ = bindingStore.save(binding)
    }

    private func ensureManagedConnection() {
        guard productionEligible,
              let binding,
              binding.shouldMaintainConnection,
              pairingState != .scanning else { return }
        guard bluetoothState == .poweredOn else {
            runtimeState = .waitingForBluetooth
            return
        }

        let identifier = binding.peripheralIdentifier
        if let peripheral = connectedPeripheral, peripheral.identifier == identifier {
            connectionIntent = .managed
            switch peripheral.state {
            case .connected:
                if protocolCharacteristic == nil {
                    linkState = .discovering
                    runtimeState = .connecting
                    peripheral.delegate = self
                    peripheral.discoverServices([Self.serviceUUID])
                } else if linkState == .ready, authenticationState != .authenticated,
                          authenticationState != .authenticating {
                    authenticate()
                }
            case .connecting:
                runtimeState = .connecting
            case .disconnecting, .disconnected:
                connectKnownPeripheral(peripheral)
            @unknown default:
                runtimeState = .recovering
            }
            return
        }

        let retrieved = central.retrievePeripherals(withIdentifiers: [identifier])
        if let peripheral = retrieved.first {
            peripherals[identifier] = peripheral
            connectKnownPeripheral(peripheral)
            return
        }
        if let peripheral = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
            .first(where: { $0.identifier == identifier }) {
            peripherals[identifier] = peripheral
            connectKnownPeripheral(peripheral)
            return
        }
        runtimeState = applicationIsActive
            ? .needsAttention("系统已找不到已绑定车辆，请在车旁重新绑定")
            : .recovering
    }

    private func syncProximityWakeMonitoring(requestAuthorization: Bool) {
        proximityWakeMonitor.setEnabled(
            productionEligible && binding?.isPassiveEntryEnabled == true,
            requestAuthorization: requestAuthorization
        )
    }

    private func connectKnownPeripheral(_ peripheral: CBPeripheral) {
        BLEDiagnostics.record("key", "connect.managed peripheralState=\(peripheral.state.rawValue)")
        peripherals[peripheral.identifier] = peripheral
        if peripheral.state == .connected {
            connectionIntent = .managed
            connectedPeripheral = peripheral
            connectedIdentifier = peripheral.identifier

            peripheral.delegate = self
            linkState = .discovering
            runtimeState = .connecting
            peripheral.discoverServices([Self.serviceUUID])
        } else if peripheral.state != .connecting {
            connect(to: peripheral.identifier, intent: .managed)
        } else {
            connectionIntent = .managed
            connectedPeripheral = peripheral
            connectedIdentifier = peripheral.identifier
            runtimeState = .connecting
        }
    }

    private func adoptRestoredPeripheralIfPossible() {
        guard let binding,
              let peripheral = restoredPeripherals.first(where: {
                  $0.identifier == binding.peripheralIdentifier
              }) else { return }
        peripherals[peripheral.identifier] = peripheral
        restoredPeripherals.removeAll()
        restorationHoldTask?.cancel()
        restorationHoldTask = nil
        connectKnownPeripheral(peripheral)
    }

    /// 武装未完成（绑定压在暂不可读的钥匙串里）时到达的连接不能拆——它很可能正是
    /// 这次进程被拉起要服务的那台车。挂进恢复队列等武装完成来认领；超时没人认领
    /// 再统一断开。
    private func holdRestoredPeripheral(_ peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        if !restoredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            restoredPeripherals.append(peripheral)
        }
        restorationHoldTask?.cancel()
        restorationHoldTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self else { return }
            self.rejectUnclaimedRestoration()
        }
    }

    private func rejectUnclaimedRestoration() {
        restorationHoldTask?.cancel()
        restorationHoldTask = nil
        for peripheral in restoredPeripherals where peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        restoredPeripherals.removeAll()
    }

    /// 踢一脚放到下一跳：别在 delegate 回调半路重入武装状态机。
    private func notifyArmingStalled() {
        guard armBlockedByKeychain, let onArmingStalledEvent else { return }
        Task { @MainActor in onArmingStalledEvent() }
    }

    private func stopManagedConnection(includeIdle: Bool = false) {
        guard let peripheral = connectedPeripheral else {
            if includeIdle || connectionIntent != .idle {
                resetVolatileConnectionState()
            }
            return
        }
        guard includeIdle || connectionIntent != .idle else { return }
        central.cancelPeripheralConnection(peripheral)
        resetVolatileConnectionState()
    }

    private func resetVolatileConnectionState() {
        if straightMoveState.isPrepared {
            straightMoveHeartbeatTask?.cancel()
            straightMoveHeartbeatTask = nil
            straightMoveWatchdogTask?.cancel()
            straightMoveWatchdogTask = nil
            straightMoveStopTask?.cancel()
            straightMoveStopTask = nil
            pendingStraightMoveOrder = nil
            straightMoveState = .failed("车辆蓝牙连接已断开")
        }
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        connectedPeripheral = nil
        connectedIdentifier = nil
        protocolCharacteristic = nil
        cryptoSession = nil
        authenticationMode = nil
        pendingFullAuthenticationFallback = false
        pendingControlLabel = nil
        transmissionPurpose = nil
        transmissionFrame = nil
        transmissionChunks.removeAll(keepingCapacity: true)
        configurationInFlight = nil
        reassembler.reset()
        linkState = .idle
        authenticationState = credentialContext == nil ? .missingCertificate : .prepared
        connectionIntent = .idle
    }

    private func finishControlAttempt(_ result: BLEControlAttemptResult, id: UUID?) {
        guard let id,
              let activeControlAttempt,
              activeControlAttempt.id == id else { return }
        completedControlAttempt = (id, result)
    }

    private func beginTransmission(_ frame: Data, purpose: TransmissionPurpose) throws {
        guard transmissionPurpose == nil, !rejectedAuthWritePending else {
            throw LeapBLEProtocolError.invalidFrame("已有数据正在写入")
        }
        guard let peripheral = connectedPeripheral,
              let characteristic = protocolCharacteristic else {
            throw LeapBLEProtocolError.invalidFrame("GATT 尚未就绪")
        }

        let writeType: CBCharacteristicWriteType
        let reportedMaximum: Int
        if characteristic.properties.contains(.write) {
            writeType = .withResponse
            reportedMaximum = peripheral.maximumWriteValueLength(for: .withResponse)
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            writeType = .withoutResponse
            reportedMaximum = peripheral.maximumWriteValueLength(for: .withoutResponse)
        } else {
            throw LeapBLEProtocolError.invalidFrame("FFF2 不可写")
        }

        // 官方 iOS 1.22.66 的分片发送分支上限 160 字节。
        let chunkSize = max(20, min(reportedMaximum, 160))
        BLEDiagnostics.record("key", "tx.begin header=\(frame.prefix(2).hexString) bytes=\(frame.count) mtu=\(reportedMaximum) chunkSize=\(chunkSize) withResponse=\(writeType == .withResponse)")
        transmissionFrame = frame
        transmissionPurpose = purpose
        transmissionWriteType = writeType
        transmissionChunks = stride(from: 0, to: frame.count, by: chunkSize).map { start in
            let end = min(start + chunkSize, frame.count)
            return frame.subdata(in: start..<end)
        }
        nextTransmissionChunk = 0
        if case .authentication = purpose { diagnosticAuthTotalParts = transmissionChunks.count }
        sendAvailableChunks()
    }

    private func sendAvailableChunks() {
        guard let peripheral = connectedPeripheral,
              let characteristic = protocolCharacteristic,
              transmissionPurpose != nil else { return }

        if transmissionWriteType == .withResponse {
            guard nextTransmissionChunk < transmissionChunks.count else {
                completeTransmission()
                return
            }
            writeCurrentChunk(peripheral: peripheral, characteristic: characteristic)
            return
        }

        while nextTransmissionChunk < transmissionChunks.count,
              peripheral.canSendWriteWithoutResponse {
            writeCurrentChunk(peripheral: peripheral, characteristic: characteristic)
        }
        if nextTransmissionChunk >= transmissionChunks.count {
            completeTransmission()
        }
    }

    private func writeCurrentChunk(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let index = nextTransmissionChunk
        let chunk = transmissionChunks[index]
        nextTransmissionChunk += 1
        if index == 0,
           case .control(_, let attemptID) = transmissionPurpose,
           let attemptID,
           var attempt = activeControlAttempt,
           attempt.id == attemptID {
            attempt.didStartWrite = true
            activeControlAttempt = attempt
        }
        if case .authentication = transmissionPurpose {
            diagnosticAuthSentParts = nextTransmissionChunk
            BLEDiagnostics.record("key", "auth.tx.write \(authenticationTrace) bytes=\(chunk.count)")
        }
        peripheral.writeValue(chunk, for: characteristic, type: transmissionWriteType)
    }

    private func completeTransmission() {
        BLEDiagnostics.record("key", "tx.complete auth=\(authenticationState)")
        guard let purpose = transmissionPurpose, transmissionFrame != nil else { return }
        transmissionPurpose = nil
        transmissionFrame = nil
        transmissionChunks.removeAll(keepingCapacity: true)
        nextTransmissionChunk = 0
        if pendingFullAuthenticationFallback {
            pendingFullAuthenticationFallback = false
            performFullAuthenticationFallback()
            return
        }
        if case .straightMove = purpose {
            lastStraightMoveTransmissionAt = ContinuousClock().now
            if let order = pendingStraightMoveOrder {
                pendingStraightMoveOrder = nil
                queueStraightMove(order)
            }
        } else {
            startResponseTimeout(for: purpose)
        }
    }

    private func failTransmission(_ message: String) {
        BLEDiagnostics.record("key", "tx.failed \(message)")
        let purpose = transmissionPurpose
        transmissionPurpose = nil
        transmissionFrame = nil
        transmissionChunks.removeAll(keepingCapacity: true)
        nextTransmissionChunk = 0
        switch purpose {
        case .authentication:
            failAuthentication(message)
        case .configuration:
            BLEDiagnostics.record("key", "configuration.write.failed reason=\(BLEDiagnostics.safeMessage(message)) sent={\(configurationInFlight.map { BLEDiagnostics.configurationSummary($0) } ?? "none")}")
            configurationInFlight = nil
            runtimeState = authenticationState == .authenticated ? .ready : .recovering
        case .control(_, let attemptID):
            let didStartWrite = activeControlAttempt?.didStartWrite == true
            pendingControlLabel = nil
            finishControlAttempt(
                didStartWrite
                    ? .failedAfterWrite(message)
                    : .unavailableBeforeWrite(message),
                id: attemptID
            )
        case .straightMove:
            emergencyStopStraightMoveIfNeeded(reason: "蓝牙写入失败：\(message)")
        case nil:
            break
        }
    }

    private func startResponseTimeout(for purpose: TransmissionPurpose) {
        responseTimeoutTask?.cancel()
        responseTimeoutTask = Task { @MainActor [weak self] in
            let timeout: Duration
            switch purpose {
            case .authentication: timeout = .seconds(10)
            case .configuration: timeout = .seconds(8)
            case .control: timeout = .seconds(8)
            case .straightMove: return
            }
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            switch purpose {
            case .authentication(let mode) where self.authenticationState == .authenticating:
                self.failAuthentication("\(mode.label)后 10 秒内未收到有效认证响应")
            case .configuration:
                let sentConfiguration = self.configurationInFlight
                BLEDiagnostics.record("key", "configuration.timeout seconds=8 pending=true sent={\(sentConfiguration.map { BLEDiagnostics.configurationSummary($0) } ?? "none")}")
                self.configurationInFlight = nil
                self.runtimeState = self.authenticationState == .authenticated ? .ready : .recovering
                if let sentConfiguration,
                   self.binding?.configuration != sentConfiguration {
                    self.sendPendingConfigurationIfPossible()
                }
            case .control(let command, let attemptID) where self.pendingControlLabel == command.label:
                self.pendingControlLabel = nil
                self.finishControlAttempt(.sentWithoutConfirmation, id: attemptID)
            case .straightMove:
                break
            default:
                break
            }
        }
    }

    private func failAuthentication(_ message: String) {
        BLEDiagnostics.record("key", "auth.failed \(message) \(authenticationTrace)")
        if case .authentication = transmissionPurpose {
            // A vehicle rejection may arrive before the ATT write callback. Drop all unsent
            // fragments, and drain the outstanding callback before accepting another write.
            rejectedAuthWritePending = transmissionWriteType == .withResponse
                && diagnosticAuthSentParts > diagnosticAuthAckedParts
            BLEDiagnostics.record("key", "auth.tx.cancel \(authenticationTrace) unsent=\(max(0, transmissionChunks.count - nextTransmissionChunk)) pendingAck=\(rejectedAuthWritePending)")
            transmissionPurpose = nil
            transmissionFrame = nil
            transmissionChunks.removeAll(keepingCapacity: true)
            nextTransmissionChunk = 0
        }
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        pendingFullAuthenticationFallback = false
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        authenticationState = .failed
        authenticationError = message
        pendingControlLabel = nil
        switch connectionIntent {
        case .pairing:
            pairingState = .failed(message)
            runtimeState = .needsAttention("车辆身份认证失败")
        case .managed:
            runtimeState = .needsAttention(message)
        case .idle:
            break
        }
    }

    private func completeAuthentication(lockState: String) {
        BLEDiagnostics.record("key", "auth.confirmed previous=\(authenticationState)")
        guard authenticationState == .authenticating else { return }
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        authenticationState = .authenticated
        authenticationError = nil
        runtimeState = .ready
        if case .pairing = connectionIntent {
            completePairingIfNeeded()
        } else if connectionIntent == .managed {
            updateBindingVerification()
            sendPendingConfigurationIfPossible()
        }
    }

    private func saveReconnectToken(_ token: String) {
        BLEDiagnostics.record("key", "token.received bytes=\(token.utf8.count)")
        guard let credentialContext else { return }
        guard reconnectTokenStore.save(
            token,
            accountId: credentialContext.accountId,
            vin: credentialContext.vin
        ) else {
            return
        }
        reconnectToken = token
        reconnectTokenAvailable = true
    }

    private func invalidateReconnectToken(reason: String) {
        BLEDiagnostics.record("key", "token.invalidated \(reason)")
        if let credentialContext {
            reconnectTokenStore.clear(
                accountId: credentialContext.accountId,
                vin: credentialContext.vin
            )
        }
        reconnectToken = nil
        reconnectTokenAvailable = false
    }

    private func performFullAuthenticationFallback() {
        BLEDiagnostics.record("key", "auth.fallback.full")
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        authenticationState = .prepared
        authenticate(forceFull: true)
    }

    private func handle(_ frame: LeapBLEFrame) {
        BLEDiagnostics.record("key", "rx.frame \(BLEDiagnostics.frameSummary(frame)) auth=\(authenticationState) \(authenticationTrace)")
        if frame.kind == .encrypted, let cryptoSession {
            do {
                let plain = try cryptoSession.decrypt(frame)
                if let response = LeapBLEDecryptedResponse(data: plain) {
                    switch response {
                    case .authentication(let lockState, _):
                        completeAuthentication(lockState: lockState)
                        if straightMoveState.isPrepared, authenticationState != .authenticated {
                            emergencyStopStraightMove(reason: "车辆认证状态异常")
                        }
                    case .reconnectToken(let token):
                        saveReconnectToken(token)
                    case .command(let identifier, let result, _):
                        let wasConfigurationResponse = configurationInFlight != nil
                        completeConfigurationSync(identifier: identifier, result: result)
                        if straightMoveState.isPrepared, !wasConfigurationResponse {
                            emergencyStopStraightMove(reason: "收到非挪车业务响应")
                        }
                    case .other:
                        BLEDiagnostics.record("key", "rx.decrypted.unrecognized bytes=\(plain.count)")
                        if straightMoveState.isPrepared {
                            emergencyStopStraightMove(reason: "收到未识别的车辆状态")
                        }
                    }
                } else {
                    if straightMoveState.isPrepared {
                        emergencyStopStraightMove(reason: "收到未识别的车辆状态")
                    }
                }
            } catch {
                BLEDiagnostics.record("key", "rx.decrypt.failed error=\(BLEDiagnostics.error(error))")
                if straightMoveState.isPrepared {
                    emergencyStopStraightMove(reason: "车辆回包解密失败")
                }
            }
        }

        guard let event = frame.event else { return }
        switch event {
        case .errorResponse(let resultCode, _):
            let tokenInvalid = [3, 4, 7].contains(Int(resultCode))
            if tokenInvalid {
                invalidateReconnectToken(reason: "车辆返回 resultCode=\(resultCode)，已清除快速重连凭证")
            }
            if straightMoveState.isPrepared {
                emergencyStopStraightMove(reason: "车辆拒绝控制（\(resultCode)）")
            }
            if authenticationState == .authenticating {
                if tokenInvalid, authenticationMode == .reconnect {
                    if transmissionPurpose == nil {
                        performFullAuthenticationFallback()
                    } else {
                        pendingFullAuthenticationFallback = true
                    }
                } else {
                    failAuthentication("车辆返回 resultCode=\(resultCode)：\(LeapBLEAuthenticationResult.description(resultCode))")
                }
            } else if configurationInFlight != nil,
                      binding?.syncState != .synced {
                configurationInFlight = nil
                runtimeState = .ready
            } else if pendingControlLabel != nil {
                responseTimeoutTask?.cancel()
                responseTimeoutTask = nil
                pendingControlLabel = nil
                finishControlAttempt(
                    .failedAfterWrite("车辆返回 resultCode=\(resultCode)"),
                    id: activeControlAttempt?.id
                )
            }
        case .lockOperation(_, let trigger, let operation):
            let confirmed: LeapBLEControlCommand?
            switch operation {
            case .unlock: confirmed = .unlock
            case .lock: confirmed = .lock
            default: confirmed = nil
            }
            if trigger == .active,
               let confirmed,
               pendingControlLabel == confirmed.label {
                responseTimeoutTask?.cancel()
                responseTimeoutTask = nil
                pendingControlLabel = nil
                lastConfirmedControlCommand = confirmed
                finishControlAttempt(.confirmed, id: activeControlAttempt?.id)
            }
        case .areaChange, .other:
            if straightMoveState.isPrepared {
                emergencyStopStraightMove(reason: "收到未识别的车辆事件")
            }
            break
        }
    }

    private func isCurrentPeripheral(_ peripheral: CBPeripheral) -> Bool {
        connectedIdentifier == peripheral.identifier
            && connectedPeripheral === peripheral
    }

    private static func propertiesDescription(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.broadcast) { names.append("broadcast") }
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("signedWrite") }
        if properties.contains(.extendedProperties) { names.append("extended") }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
}

extension BLEVehicleController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        BLEDiagnostics.record("key", "bluetooth.state=\(central.state.rawValue)")
        switch central.state {
        case .unknown: bluetoothState = .unknown
        case .resetting: bluetoothState = .resetting
        case .unsupported: bluetoothState = .unsupported
        case .unauthorized: bluetoothState = .unauthorized
        case .poweredOff: bluetoothState = .poweredOff
        case .poweredOn: bluetoothState = .poweredOn
        @unknown default: bluetoothState = .unknown
        }
        if central.state != .poweredOn {
            if straightMoveState.isPrepared {
                emergencyStopStraightMove(reason: "手机蓝牙不可用")
            }
            isScanning = false
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            cryptoSession = nil
            protocolCharacteristic = nil
            authenticationMode = nil
            authenticationState = credentialContext == nil ? .missingCertificate : .prepared
            if binding?.shouldMaintainConnection == true, productionEligible {
                runtimeState = .waitingForBluetooth
            }
            switch pairingState {
            case .scanning, .connecting, .authenticating:
                pairingState = .failed("手机蓝牙不可用，请恢复后重试")
            default:
                break
            }
        } else if pairingState == .preparing {
            beginPairing()
        } else {
            adoptRestoredPeripheralIfPossible()
            ensureManagedConnection()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        BLEDiagnostics.record(
            "key",
            "central.restore peripherals=\(peripherals.count) binding=\(binding != nil) armingBlocked=\(armBlockedByKeychain)"
        )
        restoredPeripherals = peripherals
        for peripheral in peripherals {
            self.peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
        }
        // 这条日志是「进程是否真被系统为蓝牙事件拉起过」的铁证，
        // 随意见反馈的 BLE 诊断日志一起上传，后台恢复实测就靠它定性。
        adoptRestoredPeripheralIfPossible()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        if peripherals[peripheral.identifier] == nil { BLEDiagnostics.record("key", "scan.discovered rssi=\(RSSI) manufacturerBytes=\((advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.count ?? 0)") }
        peripherals[peripheral.identifier] = peripheral
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflowServices = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceUUIDs = LeapBLEProtocol.mergingAdvertisedServices(
            previous: devices.first { $0.id == peripheral.identifier }?.serviceUUIDs ?? [],
            incoming: (advertisedServices + overflowServices).map(\.uuidString)
        )
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "未命名设备"
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let now = Date.now
        let device = BLEDiscoveredDevice(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            serviceUUIDs: serviceUUIDs,
            isConnectable: connectable,
            lastSeen: now
        )
        var devicesChanged = false
        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            let previous = devices[index]
            let advertisementChanged = previous.name != device.name
                || previous.serviceUUIDs != device.serviceUUIDs
                || previous.isConnectable != device.isConnectable
            let rssiChangedMeaningfully = abs(previous.rssi - device.rssi) >= 5
            let refreshIntervalElapsed = now.timeIntervalSince(previous.lastSeen) >= 1
            if advertisementChanged || rssiChangedMeaningfully || refreshIntervalElapsed {
                devices[index] = device
                devicesChanged = true
            }
        } else {
            devices.append(device)
            devicesChanged = true
        }
        if devicesChanged {
            devices.sort {
                if $0.advertisesTargetService != $1.advertisesTargetService {
                    return $0.advertisesTargetService
                }
                return $0.rssi > $1.rssi
            }
        }

    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        BLEDiagnostics.record("key", "connect.success current=\(isCurrentPeripheral(peripheral))")
        if connectedIdentifier != peripheral.identifier {
            // 被系统拉起恢复时，连接回调可能先于接管到达：是已绑定的车就当场接管；
            // 绑定还压在暂不可读的钥匙串里就挂住等武装；确认是别的设备才拆。
            if let binding, binding.peripheralIdentifier == peripheral.identifier,
               connectedPeripheral == nil || connectedPeripheral === peripheral {
                connectionIntent = .managed
                peripherals[peripheral.identifier] = peripheral
                peripheral.delegate = self

                restoredPeripherals.removeAll { $0.identifier == peripheral.identifier }
                if restoredPeripherals.isEmpty {
                    restorationHoldTask?.cancel()
                    restorationHoldTask = nil
                }
            } else if binding == nil, armBlockedByKeychain {
                holdRestoredPeripheral(peripheral)
                notifyArmingStalled()
                return
            } else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
        }
        diagnosticConnection += 1
        rejectedAuthWritePending = false
        diagnosticAuthenticationStarted = nil
        BLEDiagnostics.record("key", "connect.accepted connection=\(diagnosticConnection)")
        linkState = .discovering
        runtimeState = .connecting
        connectedPeripheral = peripheral
        connectedIdentifier = peripheral.identifier
        connectedDeviceName = peripheral.name ?? connectedDeviceName
        maximumWriteWithoutResponse = peripheral.maximumWriteValueLength(for: .withoutResponse)
        maximumWriteWithResponse = peripheral.maximumWriteValueLength(for: .withResponse)
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        BLEDiagnostics.record("key", "connect.failed error=\(BLEDiagnostics.error(error))")
        guard isCurrentPeripheral(peripheral) else {
            return
        }
        linkState = .failed
        if straightMoveState.isPrepared {
            emergencyStopStraightMove(reason: "车辆蓝牙连接失败")
        }
        if connectedPeripheral?.identifier == peripheral.identifier {
            connectedPeripheral = nil
            connectedIdentifier = nil
            protocolCharacteristic = nil
        }
        cryptoSession = nil
        authenticationMode = nil
        pendingFullAuthenticationFallback = false
        authenticationState = credentialContext == nil ? .missingCertificate : .prepared
        if let attempt = activeControlAttempt {
            finishControlAttempt(
                attempt.didStartWrite
                    ? .failedAfterWrite(error?.localizedDescription ?? "蓝牙连接中断")
                    : .unavailableBeforeWrite(error?.localizedDescription ?? "蓝牙连接失败"),
                id: attempt.id
            )
        }
        switch connectionIntent {
        case .pairing:
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            pairingState = .failed(error?.localizedDescription ?? "连接车辆失败")
            runtimeState = .needsAttention("车辆连接失败")
        case .managed:
            runtimeState = .recovering
        case .idle:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        BLEDiagnostics.record("key", "disconnect error=\(BLEDiagnostics.error(error))")
        handleDisconnect(peripheral, isReconnecting: false, error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: (any Error)?
    ) {
        handleDisconnect(peripheral, isReconnecting: isReconnecting, error: error)
    }

    private func handleDisconnect(
        _ peripheral: CBPeripheral,
        isReconnecting: Bool,
        error: (any Error)?
    ) {
        BLEDiagnostics.record("key", "disconnect.callback reconnecting=\(isReconnecting) current=\(isCurrentPeripheral(peripheral)) error=\(BLEDiagnostics.error(error))")
        // 挂起态的断开多半预示车端马上要重连，正是重开武装重试的时机。
        notifyArmingStalled()
        guard isCurrentPeripheral(peripheral) else { return }
        rejectedAuthWritePending = false
        linkState = isReconnecting ? .connecting : (error == nil ? .idle : .failed)

        if straightMoveState.isPrepared {
            straightMoveHeartbeatTask?.cancel()
            straightMoveHeartbeatTask = nil
            straightMoveWatchdogTask?.cancel()
            straightMoveWatchdogTask = nil
            straightMoveStopTask?.cancel()
            straightMoveStopTask = nil
            pendingStraightMoveOrder = nil
            straightMoveState = .failed("车辆蓝牙连接已断开")
        }

        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        protocolCharacteristic = nil
        cryptoSession = nil
        authenticationMode = nil
        pendingFullAuthenticationFallback = false
        authenticationState = credentialContext == nil ? .missingCertificate : .prepared
        pendingControlLabel = nil
        transmissionPurpose = nil
        transmissionFrame = nil
        transmissionChunks.removeAll(keepingCapacity: true)
        configurationInFlight = nil
        reassembler.reset()

        if let attempt = activeControlAttempt {
            finishControlAttempt(
                attempt.didStartWrite
                    ? .failedAfterWrite(error?.localizedDescription ?? "控制过程中连接断开")
                    : .unavailableBeforeWrite(error?.localizedDescription ?? "控制帧写入前连接断开"),
                id: attempt.id
            )
        }

        if isReconnecting, connectionIntent == .managed {
            connectedPeripheral = peripheral
            connectedIdentifier = peripheral.identifier
            runtimeState = .recovering
            return
        }

        connectedPeripheral = nil
        connectedIdentifier = nil
        switch connectionIntent {
        case .pairing:
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            pairingState = .failed(error?.localizedDescription ?? "绑定过程中连接断开")
            runtimeState = .needsAttention("绑定过程中车辆连接断开")
        case .managed:
            runtimeState = .recovering
            ensureManagedConnection()
        case .idle:
            break
        }
    }
}

@MainActor
private final class BLEProximityWakeMonitor: NSObject, CLLocationManagerDelegate {
    private static let beaconUUID = UUID(uuidString: "FEFF0000-0000-0000-0000-000000000000")!
    private static let regionIdentifier = "org.yipao.app.vehicle-proximity"

    var onWake: ((String) -> Void)?
    var onStateChange: ((BLEProximityWakeState) -> Void)?

    private let manager = CLLocationManager()
    private let region: CLBeaconRegion
    private var enabled = false
    private var pendingWakeSource: String?
    private var lastWakeAt = Date.distantPast

    override init() {
        let constraint = CLBeaconIdentityConstraint(uuid: Self.beaconUUID)
        region = CLBeaconRegion(beaconIdentityConstraint: constraint, identifier: Self.regionIdentifier)
        region.notifyOnEntry = true
        region.notifyOnExit = false
        region.notifyEntryStateOnDisplay = true
        super.init()
        manager.delegate = self
    }

    func setEnabled(_ enabled: Bool, requestAuthorization: Bool) {
        self.enabled = enabled
        guard enabled else {
            pendingWakeSource = nil
            stopMonitoring()
            publish(.disabled)
            return
        }
        reconcileAuthorization(requestAuthorization: requestAuthorization)
        if let pendingWakeSource {
            self.pendingWakeSource = nil
            deliverWake(source: pendingWakeSource)
        }
    }

    private func reconcileAuthorization(requestAuthorization: Bool) {
        guard CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) else {
            stopMonitoring()
            publish(.unavailable)
            return
        }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            startMonitoring()
        case .notDetermined, .authorizedWhenInUse:
            stopMonitoring()
            publish(.needsAlwaysAuthorization)
            if requestAuthorization, UIApplication.shared.applicationState == .active {
                BLEDiagnostics.record("key", "proximity.authorization.requestAlways")
                manager.requestAlwaysAuthorization()
            }
        case .denied, .restricted:
            stopMonitoring()
            publish(.needsAlwaysAuthorization)
        @unknown default:
            stopMonitoring()
            publish(.unavailable)
        }
    }

    private func startMonitoring() {
        guard !manager.monitoredRegions.contains(where: { $0.identifier == region.identifier }) else {
            publish(.monitoring)
            manager.requestState(for: region)
            return
        }
        BLEDiagnostics.record("key", "proximity.monitor.start")
        manager.startMonitoring(for: region)
        manager.requestState(for: region)
        publish(.monitoring)
    }

    private func stopMonitoring() {
        guard manager.monitoredRegions.contains(where: { $0.identifier == region.identifier }) else { return }
        BLEDiagnostics.record("key", "proximity.monitor.stop")
        manager.stopMonitoring(for: region)
    }

    private func publish(_ state: BLEProximityWakeState) {
        onStateChange?(state)
    }

    private func deliverWake(source: String) {
        guard enabled else {
            pendingWakeSource = source
            BLEDiagnostics.record("key", "proximity.wake.pending source=\(source)")
            return
        }
        guard Date.now.timeIntervalSince(lastWakeAt) >= 5 else { return }
        lastWakeAt = .now
        onWake?(source)
    }

    private func isVehicleRegion(_ region: CLRegion) -> Bool {
        region.identifier == Self.regionIdentifier
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        BLEDiagnostics.record("key", "proximity.authorization status=\(manager.authorizationStatus.rawValue)")
        guard enabled else { return }
        reconcileAuthorization(requestAuthorization: false)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard isVehicleRegion(region) else { return }
        BLEDiagnostics.record("key", "proximity.region.enter")
        deliverWake(source: "entry")
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard isVehicleRegion(region) else { return }
        BLEDiagnostics.record("key", "proximity.region.state=\(state.rawValue)")
        if state == .inside {
            deliverWake(source: "inside")
        }
    }

    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        guard isVehicleRegion(region) else { return }
        BLEDiagnostics.record("key", "proximity.monitor.started")
        manager.requestState(for: region)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        BLEDiagnostics.record("key", "proximity.monitor.failed error=\(BLEDiagnostics.error(error))")
        guard enabled else { return }
        publish(.unavailable)
    }
}

extension BLEVehicleController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        BLEDiagnostics.record("key", "services=\(peripheral.services?.map { $0.uuid.uuidString } ?? []) error=\(BLEDiagnostics.error(error))")
        guard isCurrentPeripheral(peripheral) else {
            BLEDiagnostics.record("key", "services.ignored reason=nonCurrentPeripheral connection=\(diagnosticConnection)")
            return
        }
        if error != nil {
            linkState = .failed
            return
        }
        let services = peripheral.services ?? []

        guard let service = services.first(where: { $0.uuid == Self.serviceUUID }) else {
            linkState = .failed
            return
        }
        linkState = .discovering
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        BLEDiagnostics.record("key", "characteristics service=\(service.uuid) values=\(service.characteristics?.map { "\($0.uuid):\($0.properties.rawValue)" } ?? []) error=\(BLEDiagnostics.error(error))")
        guard isCurrentPeripheral(peripheral) else {
            BLEDiagnostics.record("key", "characteristics.ignored reason=nonCurrentPeripheral connection=\(diagnosticConnection)")
            return
        }
        if error != nil {
            linkState = .failed
            return
        }
        let characteristics = service.characteristics ?? []

        guard service.uuid == Self.serviceUUID,
              let characteristic = characteristics.first(where: { $0.uuid == Self.characteristicUUID }) else {
            linkState = .failed
            return
        }
        protocolCharacteristic = characteristic
        linkState = .subscribing

        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        BLEDiagnostics.record("key", "notify uuid=\(characteristic.uuid) enabled=\(characteristic.isNotifying) error=\(BLEDiagnostics.error(error))")
        guard isCurrentPeripheral(peripheral) else {
            BLEDiagnostics.record("key", "notify.ignored reason=nonCurrentPeripheral connection=\(diagnosticConnection)")
            return
        }
        if error != nil {
            linkState = .failed
            return
        }
        linkState = characteristic.isNotifying ? .ready : .failed
        guard characteristic.isNotifying else { return }
        switch connectionIntent {
        case .pairing:
            authenticate(forceFull: true)
        case .managed:
            authenticate()
        case .idle:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        BLEDiagnostics.record("key", "rx.chunk uuid=\(characteristic.uuid) bytes=\(characteristic.value?.count ?? 0) buffered=\(reassembler.bufferedByteCount) error=\(BLEDiagnostics.error(error))")
        guard isCurrentPeripheral(peripheral) else {
            BLEDiagnostics.record("key", "rx.ignored reason=nonCurrentPeripheral connection=\(diagnosticConnection)")
            return
        }
        if error != nil {
            return
        }
        guard characteristic.uuid == Self.characteristicUUID, let value = characteristic.value else { return }

        let frames = reassembler.append(value)
        BLEDiagnostics.record("key", "rx.reassembled frames=\(frames.count) remaining=\(reassembler.bufferedByteCount)")
        for frame in frames {
            handle(frame)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        BLEDiagnostics.record("key", "tx.ack part=\(nextTransmissionChunk)/\(transmissionChunks.count) error=\(BLEDiagnostics.error(error))")
        guard isCurrentPeripheral(peripheral), characteristic.uuid == Self.characteristicUUID else {
            BLEDiagnostics.record("key", "tx.ack.ignored reason=nonCurrentPeripheralOrCharacteristic")
            return
        }
        if rejectedAuthWritePending {
            rejectedAuthWritePending = false
            BLEDiagnostics.record("key", "auth.tx.cancelledAck \(authenticationTrace) error=\(BLEDiagnostics.error(error))")
            return
        }
        guard transmissionWriteType == .withResponse, transmissionPurpose != nil else { return }
        if case .authentication = transmissionPurpose {
            diagnosticAuthAckedParts += 1
            BLEDiagnostics.record("key", "auth.tx.ack \(authenticationTrace) error=\(BLEDiagnostics.error(error))")
        }
        if let error {
            failTransmission(error.localizedDescription)
            return
        }
        sendAvailableChunks()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard isCurrentPeripheral(peripheral),
              transmissionWriteType == .withoutResponse else { return }
        sendAvailableChunks()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard isCurrentPeripheral(peripheral) else { return }
        linkState = .discovering
        protocolCharacteristic = nil
        peripheral.discoverServices([Self.serviceUUID])
    }
}
