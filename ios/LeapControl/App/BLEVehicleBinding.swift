import Foundation
import Security

enum BLEConfigurationSyncState: String, Codable, Equatable, Sendable {
    case synced
    case pending
    case pendingDisable
}

struct BLEVehicleBinding: Codable, Equatable, Sendable {
    let accountId: String
    let vin: String
    let peripheralIdentifier: UUID
    var certificateFingerprint: String
    var configuration: LeapBLEConfiguration
    var syncState: BLEConfigurationSyncState
    var removeAfterDisable: Bool
    var lastVerifiedAt: Date?
    var protocolMinor: Int? = nil

    var isBluetoothControlEnabled: Bool {
        configuration.isEnabled && syncState != .pendingDisable
    }

    var isPassiveEntryEnabled: Bool {
        isBluetoothControlEnabled
            && (configuration.autoUnlockEnabled || configuration.autoLockEnabled)
    }

    var shouldMaintainConnection: Bool {
        isBluetoothControlEnabled || syncState == .pendingDisable
    }
}

/// 已认证车辆和它的无感配置按账号/VIN 隔离保存，不能进入 UserDefaults 或 App Group。
struct BLEVehicleBindingStore: Sendable {
    private let service = "org.yipao.app.ble-vehicle-binding"

    func loadOutcome(accountId: String, vin: String) -> KeychainLoadOutcome<BLEVehicleBinding> {
        var query = baseQuery(accountId: accountId, vin: vin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return status == errSecItemNotFound ? .missing : .failure(status)
        }
        // 解不出来按「没有」算：持久坏数据只能重新配对，重试救不了。
        guard let data = item as? Data,
              let binding = try? JSONDecoder().decode(BLEVehicleBinding.self, from: data) else {
            return .missing
        }
        // 存量回填：旧版本配的对只存在钥匙串里，没走过本版的 `save()`。读到一次就
        // 补上痕迹，否则这批用户升级后一退登，「需要重新配对」提示会被 hasPaired
        // 吞掉——而他们正是这条提示要服务的人。
        BLEPairingHistory.recordPaired(accountId: binding.accountId, vin: binding.vin)
        return .found(binding)
    }

    func load(accountId: String, vin: String) -> BLEVehicleBinding? {
        if case .found(let binding) = loadOutcome(accountId: accountId, vin: vin) {
            return binding
        }
        return nil
    }

    func isInteractionBlocked() -> Bool {
        KeychainProbe.interactionBlocked(service: service)
    }

    @discardableResult
    func save(_ binding: BLEVehicleBinding) -> Bool {
        guard let data = try? JSONEncoder().encode(binding) else { return false }
        let query = baseQuery(accountId: binding.accountId, vin: binding.vin)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let saved: Bool
        if status == errSecItemNotFound {
            saved = SecItemAdd(query.merging(attributes) { current, _ in current } as CFDictionary, nil)
                == errSecSuccess
        } else {
            saved = status == errSecSuccess
        }
        if saved {
            BLEPairingHistory.recordPaired(accountId: binding.accountId, vin: binding.vin)
        }
        return saved
    }

    func clear(accountId: String, vin: String) {
        SecItemDelete(baseQuery(accountId: accountId, vin: vin) as CFDictionary)
    }

    func clearAll() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        KeychainSharing.apply(to: &query)
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(accountId: String, vin: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId + "|" + vin
        ]
        KeychainSharing.apply(to: &query)
        return query
    }
}

/// App 重装会清 UserDefaults、保留 Keychain。首次启动先清旧 binding，避免新安装直接接管旧车。
enum BLEInstallationGuard {
    private static let marker = "ble.installation.initialized.v1"

    static func prepareIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: marker) else { return }
        // 重启未解锁的窗口里（蓝牙恢复拉起、prewarming）UserDefaults 的 plist 受文件
        // 保护，读回来的是默认值 false，和「真的没初始化过」分不开；而钥匙串条目此时
        // 锁着但元数据可查。任何一组报「锁着读不到」就说明这不是新安装——什么都不做，
        // 留到下一次解锁后的启动再判。这里误清一次，用户就得回车旁重新配对。
        if BLEVehicleBindingStore().isInteractionBlocked()
            || BLEReconnectTokenStore().isInteractionBlocked()
            || BLEKeyCertificateStore().isInteractionBlocked() {
            return
        }
        BLEVehicleBindingStore().clearAll()
        BLEReconnectTokenStore().clearAll()
        BLEKeyCertificateStore().clearAll()
        defaults.set(true, forKey: marker)
    }
}

/// 「这台车在这部手机上配对过」的痕迹，专给「需要重新配对」提示做归因：
/// 钥匙串三件套退登会被连坐清掉，没有痕迹就分不清「配对丢了」和「从没配过」，
/// 后者弹这条提示纯属吓人。放 UserDefaults 而不是钥匙串：它只影响一条提示文案，
/// 重装丢了就不提示，无害。
enum BLEPairingHistory {
    private static let key = "ble.everPaired"

    static func recordPaired(accountId: String, vin: String) {
        let token = accountId + "|" + vin
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !list.contains(token) else { return }
        list.append(token)
        UserDefaults.standard.set(list, forKey: key)
    }

    static func hasPaired(accountId: String, vin: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .contains(accountId + "|" + vin)
    }
}
