import Foundation
import Security

/// App 与卡片扩展共享的 Keychain 组。卡片要下发控车指令就得读到同一份登录态。
enum KeychainSharing {
    /// entitlement 里写的是 `$(AppIdentifierPrefix)org.yipao.app`，真机上会展开成
    /// `<TeamID>.org.yipao.app`。查询时若只写 `org.yipao.app`，匹配不到任何组，
    /// 所有读写都静默失败——登录态存不住、「记住密码」永远不生效。
    ///
    /// Team ID 不写死在代码里：先写一条不指定组的临时项，读回系统给它分配的默认组。
    /// 默认组就是 entitlement 列表里的第一项，也就是我们要的这个共享组。
    ///
    /// 探测失败时返回 nil，查询就不带组限定——两个 target 的默认组本来就是同一个，
    /// 所以退化路径依然是共享的。显式指定只是为了将来 entitlement 里多加一个组时不会串。
    static let accessGroup: String? = resolveAccessGroup()

    static func apply(to query: inout [String: Any]) {
        guard let accessGroup else { return }
        query[kSecAttrAccessGroup as String] = accessGroup
    }

    private static func resolveAccessGroup() -> String? {
        #if targetEnvironment(simulator)
        // 模拟器没有真实的 AppIdentifierPrefix，不加组限定即可。
        return nil
        #else
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.yipao.app.accessgroup-probe",
            kSecAttrAccount as String: "probe"
        ]
        SecItemDelete(probe as CFDictionary)

        var attributes = probe
        attributes[kSecValueData as String] = Data("probe".utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecReturnAttributes as String] = true

        var result: CFTypeRef?
        let status = SecItemAdd(attributes as CFDictionary, &result)
        SecItemDelete(probe as CFDictionary)

        guard status == errSecSuccess,
              let saved = result as? [String: Any],
              let group = saved[kSecAttrAccessGroup as String] as? String
        else { return nil }
        return group
        #endif
    }
}

/// 会话落 Keychain。里面是 token、signKey 和 VIN，不能进 UserDefaults。
struct SessionStore: Sendable {
    /// 服务名可注入，只为让单测能开一条独立的钥匙串项，不去碰真实登录态
    /// （测试进程里的钥匙串就是这台机器上真实的那一份，写进去会把人挤下线）。
    /// 生产代码一律用无参 `SessionStore()`。
    private let service: String
    private let account = "leap-session"
    /// 设备号单独存一条，不跟着会话 JSON 走。
    ///
    /// 它和 token 不是一类东西：token 会续期、会被别的进程换发，设备号则是登录那一刻
    /// 上报给服务端、被服务端拿去绑 token 的**唯一正确值**，一旦变了，老链路（远控、
    /// 里程、位置）就一律 `result=39`，且只有重新短信登录才解得开。
    ///
    /// 混在会话 JSON 里的问题是整份写回会盖它：任何一个手里拿着半截会话的进程
    /// （重启未解锁时被 BLE 恢复或控件预热拉起、钥匙串读不到）一次 `save` 就能把它冲掉。
    /// 单独一条，读写都只经过 `loadDeviceId` / `saveDeviceId`，谁都盖不着。
    private let deviceIdAccount = "leap-device-id"

    init(service: String = "org.yipao.app.session") {
        self.service = service
    }

    /// 读钥匙串的三种结局。「没有」和「读不到」必须分开：
    /// 条目是 `AfterFirstUnlock` 等级，重启后未解锁时（BLE 恢复、系统 prewarming
    /// 都会在那个窗口拉起进程）读取会报 `errSecInteractionNotAllowed`——
    /// 那不是用户退了登，把它当成「没登录」定论，用户就「莫名其妙被退出登录」了。
    enum LoadOutcome {
        case found(LeapSession)
        /// `errSecItemNotFound`，或有数据但解不出来：确实没有可用的会话
        /// （从没登录过 / 已退登 / 持久坏数据——坏数据重试救不了，重新登录即自愈）。
        case missing
        /// 其它 OSStatus：这一次没读到，不代表没有。
        case failure(OSStatus)
    }

    func loadOutcome() -> LoadOutcome {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        KeychainSharing.apply(to: &query)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return status == errSecItemNotFound ? .missing : .failure(status)
        }
        // 解不出来按「没有」算，和各 BLE store 一个口径：能读到数据说明钥匙串没锁，
        // 坏的是数据本身，归进 `.failure` 会让武装探针把它当「锁着」永远挂起重试。
        guard let data = item as? Data,
              var session = try? JSONDecoder().decode(LeapSession.self, from: data) else {
            return .missing
        }
        // 设备号以单独那条为准；会话 JSON 里那份只是历史遗留（也可能已被谁盖空了）。
        if let deviceId = loadDeviceId(), !deviceId.isEmpty {
            session.deviceId = deviceId
        } else if !session.deviceId.isEmpty {
            // 老用户第一次走到这：把会话里那个搬进单独条目，之后就再也不会被盖。
            saveDeviceId(session.deviceId)
        }
        return .found(session)
    }

    /// 单独那条设备号。读不到（没有 / 钥匙串还锁着）都返回 nil——
    /// 调用方一律按「这次拿不到」处理，绝不能据此发一个新设备号。
    func loadDeviceId() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceIdAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        KeychainSharing.apply(to: &query)
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let deviceId = String(data: data, encoding: .utf8),
              !deviceId.isEmpty else { return nil }
        return deviceId
    }

    /// 写单独那条设备号。空值一律不写：那只会把真的那个抹掉。
    func saveDeviceId(_ deviceId: String) {
        guard !deviceId.isEmpty else { return }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceIdAccount
        ]
        KeychainSharing.apply(to: &query)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(deviceId.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { current, _ in current } as CFDictionary, nil)
        }
    }

    func load() -> LeapSession? {
        if case .found(let session) = loadOutcome() { return session }
        return nil
    }

    func save(_ session: LeapSession) {
        // 单独那条跟着一起更新（空值不写，见 `saveDeviceId`）。
        saveDeviceId(session.deviceId)
        guard let data = try? JSONEncoder().encode(session) else { return }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        KeychainSharing.apply(to: &query)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // 设备解锁后可读，且不参与 iCloud/备份迁移。
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { current, _ in current } as CFDictionary, nil)
        }
    }

    /// 只清会话，**不动设备号**。
    ///
    /// 设备号不是登录态的一部分，是这台手机的身份。退登后留着它，下次登录仍用同一个
    /// 设备号去绑——服务端那边不会多出一台设备，也少一次「新设备登录」的风控。
    /// 真要换（换账号也不需要换），只有 `clearDeviceId()` 一条路。
    func clear() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        KeychainSharing.apply(to: &query)
        SecItemDelete(query as CFDictionary)
    }

    func clearDeviceId() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceIdAccount
        ]
        KeychainSharing.apply(to: &query)
        SecItemDelete(query as CFDictionary)
    }
}

/// 蓝牙钥匙各 store 共用的三态读取结果。「没有」和「读不到」必须分开
/// （同 `SessionStore.LoadOutcome` 的理由）：条目都是 `AfterFirstUnlock` 等级，
/// 重启未解锁的窗口里（prewarming、极端时序的蓝牙恢复拉起）读取会报
/// `errSecInteractionNotAllowed`——把那当成「没有」，会拆掉本来救得回来的绑定和证书。
enum KeychainLoadOutcome<Value> {
    case found(Value)
    /// `errSecItemNotFound`：确实没有这条。
    case missing
    /// 其它 OSStatus：这一次没读到，不代表没有。
    case failure(OSStatus)
}

/// 「这组条目现在读不读得到」的探针。锁定窗口里 `SecItemCopyMatching` 对
/// `AfterFirstUnlock` 条目报 `errSecInteractionNotAllowed`；除「读到了」和
/// 「确实没有」之外的一切结果都按「读不到」算——调用方拿它决定要不要清库，
/// 拿不准时宁可什么都不做。
enum KeychainProbe {
    static func interactionBlocked(service: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        KeychainSharing.apply(to: &query)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status != errSecSuccess && status != errSecItemNotFound
    }
}

/// 蓝牙证书单独按账号和 VIN 存放，退出登录时可整组删除，不和会话 JSON 混在一起。
struct BLEKeyCertificateStore: Sendable {
    private let service = "org.yipao.app.ble-key-certificate"

    func loadOutcome(accountId: String, vin: String) -> KeychainLoadOutcome<LeapBLEKeyCertificate> {
        var query = baseQuery(accountId: accountId, vin: vin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return status == errSecItemNotFound ? .missing : .failure(status)
        }
        // 解不出来或没过校验的按「没有」算：那是坏数据，出路是重新同步，重试救不了。
        guard let data = item as? Data,
              let certificate = try? JSONDecoder().decode(LeapBLEKeyCertificate.self, from: data),
              certificate.isSupportedKeyType,
              certificate.hasValidPasswordCard else { return .missing }
        return .found(certificate)
    }

    func load(accountId: String, vin: String) -> LeapBLEKeyCertificate? {
        if case .found(let certificate) = loadOutcome(accountId: accountId, vin: vin) {
            return certificate
        }
        return nil
    }

    func isInteractionBlocked() -> Bool {
        KeychainProbe.interactionBlocked(service: service)
    }

    @discardableResult
    func save(_ certificate: LeapBLEKeyCertificate, accountId: String, vin: String) -> Bool {
        guard certificate.isSupportedKeyType,
              certificate.hasValidPasswordCard,
              let data = try? JSONEncoder().encode(certificate) else { return false }
        let query = baseQuery(accountId: accountId, vin: vin)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { current, _ in current } as CFDictionary, nil)
                == errSecSuccess
        }
        return status == errSecSuccess
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

/// `AA AE` 返回的 BLE 快速重连 token，按账号和 VIN 隔离保存。
struct BLEReconnectTokenStore: Sendable {
    private let service = "org.yipao.app.ble-reconnect-token"

    func isInteractionBlocked() -> Bool {
        KeychainProbe.interactionBlocked(service: service)
    }

    func load(accountId: String, vin: String) -> String? {
        var query = baseQuery(accountId: accountId, vin: vin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    @discardableResult
    func save(_ token: String, accountId: String, vin: String) -> Bool {
        guard (try? LeapBLEProtocol.decodeReconnectToken(token)) != nil else { return false }
        let query = baseQuery(accountId: accountId, vin: vin)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { current, _ in current } as CFDictionary, nil)
                == errSecSuccess
        }
        return status == errSecSuccess
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

/// 操作密码单独存放，只在通过生物识别后取出，用于免去每次手输。
struct OperationPasswordStore: Sendable {
    private let service = "org.yipao.app.oppwd"
    private let account = "operation-password"

    func read() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        KeychainSharing.apply(to: &query)
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 返回是否真的写进去了。写失败必须让上层知道——否则用户勾了「记住密码」，
    /// 下次还是被要求手输，却看不到任何原因。
    @discardableResult
    func write(_ password: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        KeychainSharing.apply(to: &query)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            // 和 token 那两条一个等级：开机首次解锁后可读，**设备锁着也读得到**。
            //
            // 原来是 `WhenUnlockedThisDeviceOnly`（锁着就读不到），于是锁屏底部的
            // 两个控件在真正锁屏的状态下一律取不到操作密码，
            // 指令根本发不出去——「锁屏直接能按」这个设计从来没有真正兑现过。
            //
            // 这确实放宽了一档：设备锁着时，能在本机执行代码的攻击者可以读到它。
            // 但 token 早就是这一档了，而车主已经选择了「直接控车」这个折衷
            // （门槛就是手机在手），两条一致比一严一松更好解释。仍然是
            // ThisDeviceOnly，不进 iCloud 钥匙串、不随备份走。
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let ok: Bool
        if status == errSecItemNotFound {
            ok = SecItemAdd(query.merging(attributes) { current, _ in current } as CFDictionary, nil) == errSecSuccess
        } else {
            ok = status == errSecSuccess
        }
        // 顺带记一个「存过了」的标记到 App Group。锁屏上的组件在设备锁着时渲染，
        // 那时读不到这条钥匙串（`WhenUnlockedThisDeviceOnly`），只能靠标记判断
        // 该渲染成按钮还是链接——理由见 `SharedSettings.hasSavedOperationPassword`。
        if ok { SharedSettings.hasSavedOperationPassword = true }
        return ok
    }

    func clear() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        KeychainSharing.apply(to: &query)
        SecItemDelete(query as CFDictionary)
        SharedSettings.hasSavedOperationPassword = false
    }

    var hasPassword: Bool { read()?.isEmpty == false }

    /// 把 App Group 里那个标记和钥匙串的真实情况对齐。
    ///
    /// 老用户在这个标记出现之前就存过密码，标记会是 false，锁屏组件于是一直
    /// 渲染成链接。App 每次启动时对齐一次即可——**必须在 App 里做**，
    /// 那时设备一定是解锁的，读得到钥匙串。
    /// 返回标记是否发生了变化——变了的话调用方要刷新卡片和控件，
    /// 否则它们会继续按上一次渲染的结果显示（widget 渲染是系统缓存的）。
    @discardableResult
    func syncSharedFlag() -> Bool {
        let actual = hasPassword
        let changed = SharedSettings.hasSavedOperationPassword != actual
        SharedSettings.hasSavedOperationPassword = actual
        return changed
    }

    /// 把已经存着的那条密码重写一遍，让它用上新的可访问性等级。
    ///
    /// **改代码只影响新写入的项**：`kSecAttrAccessible` 是钥匙串项自己的属性，
    /// 已经存在的那条还是当初写入时的等级。不重写一次，老用户的锁屏组件永远读不到。
    /// 必须在 App 里做——那时设备一定是解锁的，老等级才读得出来。
    func migrateAccessibilityIfNeeded() {
        guard let password = read(), !password.isEmpty else { return }
        write(password)
    }
}
