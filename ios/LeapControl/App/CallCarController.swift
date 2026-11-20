import CoreBluetooth
import Foundation
import Observation
import UIKit

/// EEED 座舱连接有自己的认证与 AA AC 解码器，不复用 FFFE 钥匙会话。
@MainActor @Observable
final class CallCarController: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private(set) var straightMoveState: BLEVehicleController.StraightMoveState = .idle {
        didSet { if oldValue != straightMoveState { BLEDiagnostics.record("cockpit", "state=\(straightMoveState)") } }
    }
    private(set) var authenticated = false
    private var context: LeapBLECredentialContext?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var crypto: LeapBLECryptoSession?
    private var buffer = CallCarPacketBuffer()
    private var order: UInt8 = 3
    private var chunks: [Data] = []
    private var writing = false
    private var timer: Task<Void, Never>?
    private var generation = 0
    private var lastResponse = Date.distantPast
    private var writeStarted = Date.distantPast
    private var closing = false
    private var backgroundObserver: NSObjectProtocol?

    override init() {
        super.init()
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.closeStraightMove() }
            }
    }

    func configure(_ value: LeapBLECredentialContext?) {
        if context != value { closeStraightMove(); context = value }
    }

    func prepareStraightMove() async throws {
        BLEDiagnostics.record("cockpit", "prepare certificate=\(context != nil)")
        guard UIApplication.shared.applicationState == .active, context != nil else {
            throw LeapError.server("请先同步车辆蓝牙证书，并保持 App 在前台")
        }
        disconnect()
        generation += 1
        let epoch = generation
        closing = false
        straightMoveState = .preparing
        central = CBCentralManager(delegate: self, queue: .main)
        let deadline = Date.now.addingTimeInterval(50)
        do {
            while Date.now < deadline {
                try Task.checkCancellation()
                guard epoch == generation else { throw CancellationError() }
                if straightMoveState == .ready { return }
                if case .failed(let message) = straightMoveState { throw LeapError.server(message) }
                try await Task.sleep(for: .milliseconds(80))
            }
            throw LeapError.server("车辆直进直出未就绪，请检查上电、车门、P 档和周围环境")
        } catch {
            if epoch == generation { fail(error.localizedDescription) }
            throw error
        }
    }

    func startStraightMove(_ direction: StraightMoveDirection) throws {
        guard !closing, UIApplication.shared.applicationState == .active,
              straightMoveState == .ready, authenticated, Date.now.timeIntervalSince(lastResponse) < 1 else {
            throw LeapError.server("请等待车辆就绪；暂停后需先恢复")
        }
        order = direction == .forward ? 1 : 2
        straightMoveState = .moving(direction)
        sendOrder()
    }

    func stopStraightMove() {
        guard authenticated, !closing else { return }
        order = 3
        straightMoveState = .paused
        sendOrder()
    }

    func resume() {
        guard straightMoveState == .paused, authenticated, !closing else { return }
        order = 4 // 官方“继续”，不会在恢复后自动续发方向。
        straightMoveState = .preparing
        sendOrder()
    }

    func closeStraightMove() {
        BLEDiagnostics.record("cockpit", "close authenticated=\(authenticated)")
        generation += 1
        let epoch = generation
        closing = true
        order = 3
        straightMoveState = .idle
        if authenticated {
            sendOrder()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.generation == epoch else { return }
                self.order = 6 // 官方主动退出业务
                self.sendOrder()
                try? await Task.sleep(for: .milliseconds(200))
                guard self.generation == epoch else { return }
                self.disconnect()
            }
        } else { disconnect() }
    }

    private func fail(_ message: String) {
        BLEDiagnostics.record("cockpit", "fail message=\(BLEDiagnostics.safeMessage(message))")
        closeStraightMove()
        straightMoveState = .failed(message)
    }

    private func disconnect() {
        BLEDiagnostics.record("cockpit", "disconnect local=true")
        timer?.cancel(); timer = nil
        central?.stopScan()
        if let peripheral { peripheral.delegate = nil; central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; characteristic = nil; crypto = nil
        authenticated = false; chunks = []; writing = false; buffer.reset()
        central?.delegate = nil; central = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        BLEDiagnostics.record("cockpit", "bluetooth.state=\(central.state.rawValue)")
        guard central === self.central else { return }
        guard central.state == .poweredOn else { fail("手机蓝牙不可用"); return }
        BLEDiagnostics.record("cockpit", "scan.start service=EEED")
        central.scanForPeripherals(withServices: [CBUUID(string: CallCarProtocol.service)])
    }

    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, peripheral == nil, !closing, let context,
              let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              CallCarProtocol.matches(manufacturerData: manufacturer, vin: context.vin) else { return }
        BLEDiagnostics.record("cockpit", "scan.match rssi=\(RSSI)")
        central.stopScan()
        peripheral = device; device.delegate = self
        central.connect(device)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        BLEDiagnostics.record("cockpit", "connect.success")
        guard peripheral === self.peripheral else { return }
        peripheral.discoverServices([CBUUID(string: CallCarProtocol.service)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        BLEDiagnostics.record("cockpit", "connect.failed error=\(BLEDiagnostics.error(error))")
        guard peripheral === self.peripheral else { return }; fail("座舱蓝牙连接失败")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        BLEDiagnostics.record("cockpit", "disconnect error=\(BLEDiagnostics.error(error))")
        guard peripheral === self.peripheral else { return }; authenticated = false; fail("座舱蓝牙已断开")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        BLEDiagnostics.record("cockpit", "services=\(peripheral.services?.map { $0.uuid.uuidString } ?? []) error=\(BLEDiagnostics.error(error))")
        guard peripheral === self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: CallCarProtocol.service) }) else {
            fail("车辆未提供直进直出蓝牙服务"); return
        }
        peripheral.discoverCharacteristics([CBUUID(string: CallCarProtocol.characteristic)], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        BLEDiagnostics.record("cockpit", "characteristics count=\(service.characteristics?.count ?? 0) error=\(BLEDiagnostics.error(error))")
        guard peripheral === self.peripheral else { return }
        guard error == nil, let characteristic = service.characteristics?.first(where: {
            $0.uuid == CBUUID(string: CallCarProtocol.characteristic)
        }), characteristic.properties.contains(.write) else { fail("座舱蓝牙特征不可用"); return }
        self.characteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        BLEDiagnostics.record("cockpit", "notify enabled=\(characteristic.isNotifying) error=\(BLEDiagnostics.error(error))")
        guard peripheral === self.peripheral, characteristic === self.characteristic, let context else { return }
        guard error == nil, characteristic.isNotifying else { fail("座舱蓝牙订阅失败"); return }
        do {
            let crypto = try LeapBLECryptoSession.make(certificate: context.certificate, vin: context.vin)
            self.crypto = crypto
            let frame = try crypto.callCarAuthenticationFrame(certificate: context.certificate,
                accountId: context.accountId, deviceId: context.deviceId)
            BLEDiagnostics.record("cockpit", "auth.frame bytes=\(frame.count)")
            write(frame)
        } catch { fail(error.localizedDescription) }
    }
    private func write(_ data: Data) {
        BLEDiagnostics.record("cockpit", "tx.request header=\(data.prefix(2).hexString) bytes=\(data.count) busy=\(writing) order=\(order)")
        guard !writing, let peripheral, characteristic != nil else { return }
        let size = max(1, peripheral.maximumWriteValueLength(for: .withResponse))
        chunks = stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
        writing = true; writeStarted = .now
        nextChunk()
    }
    private func nextChunk() {
        guard let peripheral, let characteristic, !chunks.isEmpty else { writing = false; return }
        peripheral.writeValue(chunks.removeFirst(), for: characteristic, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        BLEDiagnostics.record("cockpit", "tx.ack remaining=\(chunks.count) error=\(BLEDiagnostics.error(error))")
        guard peripheral === self.peripheral, characteristic === self.characteristic else { return }
        guard error == nil else { authenticated = false; fail("座舱指令写入失败"); return }
        nextChunk()
    }
    private func sendOrder() {
        guard authenticated, !writing, let crypto else { return }
        do { write(try crypto.callCarOrderFrame(order)) } catch { authenticated = false; fail(error.localizedDescription) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        BLEDiagnostics.record("cockpit", "rx.chunk bytes=\(characteristic.value?.count ?? 0) error=\(BLEDiagnostics.error(error))")
        guard peripheral === self.peripheral, characteristic === self.characteristic, !closing else { return }
        guard error == nil, let data = characteristic.value, let crypto else { fail("座舱回包读取失败"); return }
        do {
            for packet in try buffer.append(data) {
                BLEDiagnostics.record("cockpit", "rx.frame type=\(packet.type) bytes=\(packet.payload.count)")
                guard !closing else { return }
                guard packet.type != 0 else { throw LeapError.server("座舱认证失败，请同步蓝牙证书后重试") }
                // 座舱 Data 区为 Base64 密文；只借用已验证的会话解密，不借用钥匙回包分类。
                var raw = Data([0xAA, 0xAB]); raw.appendLittleEndian(UInt32(packet.payload.count)); raw.append(packet.payload)
                let plain = try crypto.decrypt(LeapBLEFrame(kind: .encrypted, declaredPayloadLength: packet.payload.count, bytes: raw))
                guard let text = String(data: plain, encoding: .utf8), let status = CallCarStatus.parse(text) else {
                    throw LeapError.server("无法识别座舱状态，已停止控制")
                }
                authenticated = true; lastResponse = .now
                BLEDiagnostics.record("cockpit", "rx.status \(status.diagnosticSummary)")
                switch status {
                case .waiting:
                    if straightMoveState == .ready || straightMoveState.isMoving {
                        order = 3; straightMoveState = .preparing
                    }
                case .activate:
                    order = 5; straightMoveState = .preparing
                case .ready:
                    if !straightMoveState.isMoving { order = 3; straightMoveState = .ready }
                case .paused:
                    order = 3; straightMoveState = .paused
                case .failed(let code): fail("车辆退出直进直出（原因 \(code)）")
                case .unavailable(let code): fail("车辆暂不可用，请检查车门、P 档及踏板（原因 \(code)）")
                }
                if !closing, timer == nil {
                    BLEDiagnostics.record("cockpit", "heartbeat.start intervalMs=100")
                    timer = Task { @MainActor [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(100))
                            guard !Task.isCancelled, let self else { return }
                            if !self.closing && (Date.now.timeIntervalSince(self.lastResponse) > 1 ||
                                (self.writing && Date.now.timeIntervalSince(self.writeStarted) > 0.35)) {
                                self.fail("座舱控制连接超时，已停止"); return
                            }
                            self.sendOrder()
                        }
                    }
                }
            }
        } catch { fail(error.localizedDescription) }
    }
}

private extension CallCarStatus {
    var diagnosticSummary: String {
        switch self {
        case .waiting: return "kind=waiting reason=0"
        case .activate: return "kind=activate reason=0"
        case .ready: return "kind=ready reason=0"
        case .paused(let reason): return "kind=paused reason=\(reason)"
        case .failed(let reason): return "kind=failed reason=\(reason)"
        case .unavailable(let reason): return "kind=unavailable reason=\(reason)"
        }
    }
}
