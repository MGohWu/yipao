import CoreLocation
import Foundation

enum LeapError: LocalizedError {
    case crypto(String)
    case notLoggedIn
    /// 服务端明确拒绝了当前登录态，且续期也救不回来——只能重新短信登录。
    /// 和网络错误分开：断网不能把用户踢回登录页。
    case sessionExpired
    /// 老链路持续判定「信息校验失败」（result=39），刷新 token 也救不回来。
    ///
    /// 和 `sessionExpired` 分开：那个会清会话回登录页（连蓝牙钥匙证书一起清掉），
    /// 而这个状态未必是登录态没了——deviceID 与服务端绑定的那个对不上时，
    /// refreshToken 完全有效、车况照常刷新，只有老链路（远控/里程/位置）全废。
    /// 这种情况只有重新短信登录才解得开，但不该由 App 替用户做决定，只提示。
    case needsRelogin
    case missingVehicle
    case server(String)
    case http(Int, String)
    case decode(String)
    /// 网络层失败：连不上、超时、连接被断。和 `sessionExpired` 严格分开——
    /// 断网只是这次请求没成，不能据此把用户踢回登录页。
    case network(String)

    var errorDescription: String? {
        switch self {
        case .crypto(let message): return message
        case .notLoggedIn: return "还没有登录，请先完成短信验证码登录"
        case .sessionExpired: return "登录已过期，请重新登录"
        case .needsRelogin: return "控车授权已失效，请重新登录"
        case .missingVehicle: return "还没有选择车辆"
        case .server(let message): return message
        case .http(let status, let body): return "HTTP \(status)：\(body)"
        case .decode(let message): return "响应解析失败：\(message)"
        case .network(let message): return message
        }
    }
}

extension LeapError {
    /// 把 `URLError` 翻成用户看得懂的话，其余错误原样放行。
    ///
    /// 不翻的话，弹给用户的就是系统中文原文——-1005 是「网络连接已中断」、
    /// -1009 是「似乎已断开与互联网的连接」。这几句在「锁屏久了再解锁」这个场景里
    /// 既吓人又误导：用户的网络好好的，坏掉的是 App 手里那条已经死了的复用连接。
    ///
    /// `.cancelled` 不翻：切车、退到后台停轮询都会取消在途请求，翻了就成了平白弹一条
    /// 网络错误。同理 `CancellationError` 也走不到这里（它不是 `URLError`）。
    static func wrapping(_ error: Error) -> Error {
        guard let urlError = error as? URLError, urlError.code != .cancelled else { return error }
        switch urlError.code {
        case .timedOut:
            return LeapError.network("网络响应超时，请稍后重试")
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return LeapError.network("网络连接不可用，请检查网络后重试")
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
            return LeapError.network("连接服务器失败，请稍后重试")
        default:
            // 剩下的多是证书、协议一类的少见错误，带上码方便照着日志定位。
            return LeapError.network("网络请求失败（\(urlError.code.rawValue)）")
        }
    }
}

// MARK: - 会话

struct OldAuth: Codable, Equatable {
    var accountId: String
    var token: String
    var refreshToken: String
    var nickname: String
    var tokenExpired: String
    var tokenObtainedAt: Double
    var tokenExpiresAt: Double

    var expiresAtDate: Date? {
        tokenExpiresAt > 0 ? Date(timeIntervalSince1970: tokenExpiresAt / 1000) : nil
    }
}

struct NewAuth: Codable, Equatable {
    var accountId: String
    var gatewayAccountId: String
    var accessToken: String
    var refreshToken: String
    var accessTokenExpiresAt: Double
    var nickname: String
    /// 以 base64 落盘，运行时用 `signKeyData`。
    var signKeyBase64: String

    var signKeyData: Data { Data(base64Encoded: signKeyBase64) ?? Data() }

    var expiresAtDate: Date? {
        let exp = LeapCrypto.jwtExpiryMilliseconds(accessToken)
        let value = exp > 0 ? exp : accessTokenExpiresAt
        return value > 0 ? Date(timeIntervalSince1970: value / 1000) : nil
    }
}

struct Vehicle: Codable, Equatable, Identifiable, Hashable {
    var vin: String
    var carType: String
    var name: String
    /// 是不是增程/混动车。判据抄官方：`vehicle/list` 响应里每辆车带一份 `abilities`
    /// 能力码字符串数组，含 `"39"`（官方内部 key `isExtendRange`）即增程。官方就是靠这份
    /// 清单判的，**完全不看车况 signalMap**——纯电车也会实报非零汽油续航，拿信号判会误判。
    var isExtendRange: Bool = false
    /// 运行时兜底标志：`isExtendRange` 是从「缺该字段的老会话 JSON」用 `?? false` 兜出来的、
    /// 还没被 `vehicle/list` 的真实 `abilities` 刷新过，不可信。**不参与持久化**（不进 CodingKeys）。
    /// `init(from:)` 见到 JSON 里没有 `isExtendRange` 键就置真，`VehicleStore.refresh()` 见到任一车
    /// 为真就强制重拉一次 `vehicle/list`。升级用户增程被误判成纯电、油量整块消失就是这字段缺失
    /// 且永不重拉导致的。持久化无所谓：`loadVehicles` 成功后整辆车被带 `isExtendRange` 的新对象覆盖。
    var abilitiesStale: Bool = false
    /// 支持哨兵/遮阳帘/天窗/前备箱所需的**内部能力码**清单（400/240/300/131…）。
    /// 注意 `vehicle/list` 并没有 `permission` 字段——这份清单是把响应里的原始 `abilities` 短码
    /// 经官方 `CarPerManager` 的翻译表换算出来的，见 ``permissionCodes(fromAbilities:)``。
    /// 和增程判据用的原始 `abilities`（看含不含 `"39"`）口径不同，别混。
    var permission: [String] = []
    /// 这台车支不支持哨兵模式。判据见 ``supportsSentinel(carType:permission:)``（车型不是 S01/T03
    /// 且 `permission` 含 `"400"`）。官方那边卡片可见还要叠「本账号是车主」，第三方 App 单车主
    /// 场景恒真，先不判（共享/副驾场景才需要，先记一笔）。
    var isSentinelSupported: Bool = false
    /// 运行时兜底标志，作用和 `abilitiesStale` 一模一样，只是盯的是哨兵支持位：
    /// `isSentinelSupported` 是从「缺该字段的老会话 JSON」用 `?? false` 兜出来的、还没被
    /// `vehicle/list` 的真实 `permission` 刷新过，不可信。**不参与持久化**（不进 CodingKeys）。
    ///
    /// 为什么要 stale 这道双保险、光靠 `decodeIfPresent ?? false` 不够：老用户升级前持久化的车
    /// 列表里既没有 `permission` 也没有 `isSentinelSupported`，解码兜出来的 `false` 会把「支持哨兵」
    /// 永久误判成「不支持」，且因为车列表非空、永不重拉而永不自愈——和当初 `isExtendRange` 缺失
    /// 导致增程被误判成纯电、油量整块消失是同一个坑。`init(from:)` 见到 JSON 里没有
    /// `isSentinelSupported` 键就把它置真，`VehicleStore.refresh()` 见到任一车为真就强制重拉一次
    /// `vehicle/list`。持久化无所谓：`loadVehicles` 成功后整辆车被带新字段的对象覆盖。
    var sentinelStale: Bool = false

    var id: String { vin }

    /// 支持哨兵模式的判据（反编译已钉死，见 `apk-analysis/sentinel-mode-interfaces.md` §4）：
    /// 车型不是 S01/T03，且 `permission` 能力码清单含 `"400"`。
    ///
    /// **判据查的是内部码 `permission`，不是原始 `abilities`**——`permission` 由 `abilities` 经
    /// `CarPerManager` 翻译而来（原始 `"50"` → 内部 `"400"`），增程那套 `abilities.contains("39")`
    /// 判不了哨兵。S01/T03 官方在
    /// `RemoteContorllerUtil.contains()` 里对车型走白名单硬排除，哪怕 `permission` 里有 `"400"`
    /// 也恒隐藏哨兵，所以这里先把这两个车型挡在门外，再看能力码。
    static func supportsSentinel(carType: String, permission: [String]) -> Bool {
        guard !CarTypeFamily.isS01(carType), !CarTypeFamily.isT03(carType) else { return false }
        return permission.contains("400")
    }

    /// 支持远控遮阳帘（天幕）的判据：`permission` 含 `"240"`（`apk-analysis/permission-codes-map.md`，
    /// 快捷面板 btnType "29" → `R.string.lpcar_btn_sunshade`，确证）。
    ///
    /// 和哨兵不同**不排除 S01/T03**：官方对这两个车型的前置白名单
    /// （`RemoteContorllerUtil.OooO00o`）里有 766="240"，遮阳帘照常按能力码判。
    static func supportsSunshade(permission: [String]) -> Bool {
        permission.contains("240")
    }

    /// 支持远控天窗的判据：车型不是 S01/T03，且 `permission` 含 `"300"`（同上出处，btnType "26" →
    /// `R.string.lpcar_btn_skylight`）。S01/T03 白名单里**没有** 763="300"——官方在这两个车型上
    /// 恒隐藏天窗，哪怕服务端下发了能力码，所以照哨兵那样先挡车型再看码。
    static func supportsSunroof(carType: String, permission: [String]) -> Bool {
        guard !CarTypeFamily.isS01(carType), !CarTypeFamily.isT03(carType) else { return false }
        return permission.contains("300")
    }

    /// 支持远控前备箱的判据：车型不是 S01/T03，且 `permission` 含 `"131"`（同上出处，btnType "137" →
    /// `R.string.lpcar_btn_front_trunk`；白名单没有 153="131"，车型排除理由同天窗）。
    static func supportsFrunk(carType: String, permission: [String]) -> Bool {
        guard !CarTypeFamily.isS01(carType), !CarTypeFamily.isT03(carType) else { return false }
        return permission.contains("131")
    }

    /// 舒适座舱四项的能力码判据。
    ///
    /// 这几项**只当第二道判据**：真正说话的是车况信号在不在场（见
    /// `VehicleState.hasSeatComfort` 那组）。原因是信号比能力码更贴车端，而且方向盘加热
    /// （cmdid `320`）压根没有已知的 `abilities` 原始码，只能靠信号 `1816`。
    /// 两者都没有才隐藏。
    ///
    /// S01 / T03 一律排除：那套老口径的 signalMap 里没有任何一个对应字段，
    /// 整页在老车上就是空的，不该给入口。
    static func supportsCabinComfort(carType: String, permission: [String]) -> Bool {
        guard !CarTypeFamily.isLegacyFamily(carType) else { return false }
        return permission.contains("301") || permission.contains("370") || permission.contains("440")
    }

    /// 车载冰箱的能力码判据（原始码 `76`）。车主那台 C16 不含 `76`，
    /// 和它的 signalMap 里冰箱信号全无互相印证。
    static func supportsFridge(carType: String, permission: [String]) -> Bool {
        guard !CarTypeFamily.isLegacyFamily(carType) else { return false }
        return permission.contains("500")
    }

    /// `vehicle/list` 里**根本没有 `permission` 字段**——真车抓包实证。能力码全在 `abilities`
    /// 数组里，而且是**服务器原始短码**（`"1".."89"`），不是上面判据要的内部码（400/240/300/131）。
    /// 官方 App 在 `CarPerManager`（`OooO0o.OooO00o`）里把原始码翻成内部码再判支持位，这张表就是
    /// 照抄那段翻译里我们用得到的四项。原始码经在官方 App 上 frida 解 `StubApp.getString2` 实测，
    /// 三路交叉验证一致，全表见 `apk-analysis/permission-codes-map.md`。
    ///
    /// 之前 `loadVehicles` 读的是不存在的 `permission` 字段 → 永远空 → 哨兵/遮阳帘/天窗/前备箱四个
    /// 支持位对所有真实用户恒为假、第二栏永不展开（只有手填能力码的体验模式看得到）。
    static let abilityToPermission: [String: String] = [
        "105": "bleMultipleAnchors", // 官方 iOS 1.22.66 isMulCalibration 能力位
        "50": "400",   // 哨兵 sentinel
        "13": "240",   // 遮阳帘 sunshade
        "25": "300",   // 天窗 sunroof
        "79": "131",   // 前备箱 frunk
        // 舒适座舱四项（2026-11-19 补）。这四个内部码在我们自己解出的 `CarPerManager` 全表里
        // 本来就在，只是官方 APK 里一个中文名都没有（官方 App 自己没做这些功能），所以之前没收。
        // 语义来自 leapauto，与实测 C16 的 `abilities` 逐项对得上：含 21/42/43/59、不含 76，
        // 而那台车的 signalMap 里座椅/方向盘/后视镜信号全在、冰箱信号全无——两路证据一致。
        "21": "301",   // 座椅加热 seat heating
        "85": "301",
        "93": "301",
        "42": "370",   // 座椅通风 seat ventilation
        "43": "370",
        "59": "440",   // 后视镜加热 mirror heating
        "76": "500",   // 车载冰箱 fridge
    ]

    /// 把 `vehicle/list` 的原始 `abilities` 短码翻成本 App 判据要的内部码清单。
    static func permissionCodes(fromAbilities abilities: [String]) -> [String] {
        abilities.compactMap { abilityToPermission[$0] }
    }

    private enum CodingKeys: String, CodingKey {
        case vin, carType, name, isExtendRange, permission, isSentinelSupported
    }

    init(
        vin: String,
        carType: String,
        name: String,
        isExtendRange: Bool = false,
        permission: [String] = [],
        isSentinelSupported: Bool = false
    ) {
        self.vin = vin
        self.carType = carType
        self.name = name
        self.isExtendRange = isExtendRange
        self.permission = permission
        self.isSentinelSupported = isSentinelSupported
    }

    /// 老会话的 JSON 里没有 `isExtendRange`，`decodeIfPresent` 兜底 `false`，
    /// 旧数据照样能解码（同 `LeapSession.selectedCarAlias` 那套老会话兼容思路）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vin = try container.decode(String.self, forKey: .vin)
        carType = try container.decode(String.self, forKey: .carType)
        name = try container.decode(String.self, forKey: .name)
        isExtendRange = try container.decodeIfPresent(Bool.self, forKey: .isExtendRange) ?? false
        // JSON 里压根没有 isExtendRange 键 = 老会话，上面兜出来的 false 不可信，标记待重拉。
        abilitiesStale = !container.contains(.isExtendRange)
        // 哨兵支持位照抄上面那套：decodeIfPresent 兜底让旧数据能解码，缺 isSentinelSupported 键
        // （老会话）再靠 sentinelStale 标记待重拉，避免永久误判且永不自愈。permission 同样兜空数组。
        permission = try container.decodeIfPresent([String].self, forKey: .permission) ?? []
        isSentinelSupported = try container.decodeIfPresent(Bool.self, forKey: .isSentinelSupported) ?? false
        sentinelStale = !container.contains(.isSentinelSupported)
    }

    /// 只展示后 4 位，避免整屏 VIN 泄露。
    var maskedVin: String {
        guard vin.count > 6 else { return vin }
        return String(vin.prefix(2)) + String(repeating: "*", count: max(0, vin.count - 6)) + String(vin.suffix(4))
    }
}

struct VehicleRoute: Codable, Equatable {
    var appRegion: String
    var appCenter: String
}

struct LeapSession: Codable, Equatable {
    var deviceId: String
    var appVersion: String
    var subVersion: String
    var phone: String
    var oldAuth: OldAuth?
    var newAuth: NewAuth?
    var vehicles: [Vehicle]
    var selectedVin: String
    var selectedCarType: String
    /// 车型别名（`Lafa5` 这种），从 3D 资源目录名反推、随会话存下来。
    /// 存而不是每次现推：Widget 是独立进程，读不到主 App 的缓存目录判断逻辑，
    /// 只能拿会话里这一份，卡片和首页才不会叫出两个名字。
    /// 老会话解不出这个字段，Optional 保证旧数据照样能解码。
    var selectedCarAlias: String?
    var route: VehicleRoute?
    /// 凭证（`oldAuth` / `newAuth`）最后一次换发的时刻，毫秒。
    ///
    /// 主 App、卡片扩展、控件 Intent 是三个进程，各自 new 一个 `LeapClient`、各自续期。
    /// 服务端每换发一次就把旧 refreshToken 作废，所以「谁的凭证新听谁的」必须有个判据——
    /// 没有它，主 App 那个常驻实例会拿着几小时前、早被卡片换掉的 refreshToken 去续期，
    /// 被服务端拒之后判成登录失效，用户就莫名其妙回到了登录页。
    ///
    /// 老会话解不出这个字段，Optional 保证旧数据照样能解码（当 0 处理，任何一次换发都比它新）。
    var authRevision: Double?

    /// 空会话。
    ///
    /// `deviceId` 是**空的**，不是新生成的——这是刻意的。老链路签名把 deviceID 和
    /// 不发送的 token 一起摊进 MD5，服务端按登录时上报的 deviceID 取它那份 token 重算：
    /// 设备号一旦对不上，远控/里程/位置一律 `result=39`（信息校验失败），而车辆列表、
    /// 车况走新网关照常成功——用户看到的就是「界面全好，按什么控制都失败」，
    /// 且续期救不回来（getnewtoken 不校验 deviceID），只有重新登录能重新绑定。
    ///
    /// 而 `fresh()` 会在**钥匙串读失败**时被调用（重启后未解锁被 BLE 恢复/控件预热拉起）。
    /// 那时凭空发一个新设备号，就等于把这台设备推进上面那个死结。所以留空：
    /// 空 deviceId 的会话发不出任何请求（`oldSignedParams`/`newGatewayHeaders` 会挡住），
    /// 也不会写回钥匙串，等解锁后 `syncAuthFromStore()` 把真的那个补回来。
    /// 真正需要新设备号的只有一处——首次短信登录，见 `LeapClient.ensureDeviceId()`。
    static func fresh() -> LeapSession {
        LeapSession(
            deviceId: "",
            appVersion: LeapConstants.appVersion,
            subVersion: LeapConstants.subVersion,
            phone: "",
            oldAuth: nil,
            newAuth: nil,
            vehicles: [],
            selectedVin: "",
            selectedCarType: "",
            selectedCarAlias: nil,
            route: nil,
            authRevision: nil
        )
    }

    var isLoggedIn: Bool {
        (oldAuth?.token.isEmpty == false) && (newAuth?.accessToken.isEmpty == false)
    }

    /// 手里还攥着**任何一份**凭证——哪怕只有半份，不足以算登录成功。
    ///
    /// 半份是真会出现的：`login()` 拿到 oldAuth 之后换新网关那步失败，就剩 oldAuth。
    /// 这种会话登录不了，却足以把登录请求的 header 打脏，所以清理逻辑得认它，
    /// 不能只认 `isLoggedIn`。
    var hasAnyCredential: Bool {
        oldAuth != nil || newAuth != nil
    }

    /// 界面和卡片上显示的车名。两边必须一致，否则卡片和首页会叫出两个名字。
    ///
    /// 车主在官方 App 起的名字最优先。没起过名就用车型别名——B05 这种内部代号
    /// 不适合直接摆在界面上，别名（`Lafa5`）是渲染器实际认的那个名字。
    /// 别名只有 3D 车推得出来（靠资源目录名），2D 图层车退回 carType：
    /// C10、S01 这些本来就是对外车型名，摆出来没问题。
    var displayVehicleName: String {
        if let vehicle = selectedVehicle, !vehicle.name.isEmpty { return vehicle.name }
        if let selectedCarAlias, !selectedCarAlias.isEmpty { return selectedCarAlias }
        if !selectedCarType.isEmpty { return selectedCarType }
        return "我的车"
    }

    var selectedVehicle: Vehicle? {
        vehicles.first { $0.vin == selectedVin }
    }
}

enum LeapConstants {
    // 对齐的零跑官方 App 版本号与官方服务域名。
    static let appVersion = "1.22.87"
    static let subVersion = "3.19.2-2"
    static let appUserHost = "https://appuser.leapmotor.cn"
    static let globalHost = "https://app-gw-global-master.leapmotor.com"
    /// accessToken 剩余不足 5 分钟就提前续期。
    static let accessTokenLeeway: TimeInterval = 5 * 60
    /// 老 token 剩余不足 60 秒才续期（服务端有效期约 6 小时）。
    static let oldTokenLeeway: TimeInterval = 60
    /// 老链路 `result=39` 的续期冷却窗口：老 token 是这段时间内换发的，再收到 39
    /// 就不重复续期，只当瞬时抖动重试一次。对齐官方零跑 App 的 60 秒不重复刷新闸——
    /// 刚续期后紧跟的 39 若又触发一次续期，旧 refreshToken 会立刻作废，反而制造失效窗口。
    static let oldTokenReauthCooldown: TimeInterval = 60
    /// 老链路连续判定失败到这个次数，就不再当瞬时抖动，提示用户重新登录。
    /// 每一次计数都已经经过「刷新 token 后重试」或「冷却窗口内重试」，不是裸重试。
    static let oldAuthFailureEscalationCount = 3
    /// 连续失败还要跨过这段时间才升级。服务端抖动是以秒计的，跨过 5 分钟仍每次都失败，
    /// 就不是抖动了。两个条件都满足才提示，避免又变回「服务端抖一下就被踢」。
    static let oldAuthFailureEscalationWindow: TimeInterval = 5 * 60
    /// 老 token 是这段时间内换发的，登录态探测就直接认它有效，不再打一次续期。
    /// 见 `LeapClient.validateSession`：探得太勤，几个进程之间会互相作废 refreshToken。
    static let sessionProbeFreshness: TimeInterval = 30 * 60
}

enum LeapFormat {
    /// 温度：车报 26.5 就写 26.5，报 26.0 就写 26。
    ///
    /// 原来一律 `%.0f`，26.5 被进位成 27，和车机、官方 App 差整整一度，
    /// 看上去就是我们读错了。半度是车端真实的分辨率，不该替它抹掉。
    static func temperature(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

// MARK: - 车况

/// 车端 signalMap 原始值，统一按字符串存放，解释权全部下放到取值方法。
///
/// key 用哪一套由 `schema` 决定——不同车型上报的字段命名体系不同，见 `SignalSchema`。
struct VehicleState: Equatable {
    var signalMap: [String: String] = [:]
    /// 默认按语义字段名解析：本地构造的演示车况和测试用例写的都是这一套。
    /// 真实车况在 `LeapClient.fetchVehicleState()` 里按上报内容自动识别。
    var schema: SignalSchema = .legacy
    /// 这台车是不是增程/混动车。来源是 `vehicle/list` 里那辆车的 `abilities` 能力码
    /// （含 `"39"` 即增程），由 `LeapClient.fetchVehicleState()` 从选中车注入。
    /// 车况响应本身不带这个信息，所以放这儿而不是从 signalMap 推。
    var isExtendRange: Bool = false
    var collectedAt: Date = .now
    /// 充电计划里设的充电上限（%）。数字口径的车（C11 那批）不把它当信号报。
    /// 车况响应里没有，由 `LeapClient.fetchCommonConfig()` 单独拉 commonConfig 后填充；
    /// 拉不到就保持 nil，`chargeLimit` 退回信号行为。来龙去脉见
    /// `VehicleState.chargePlanLimit(fromConfig:)`。
    var chargePlanLimit: Int?
    /// 完整的充电计划（预约时段、目标电量、循环日、开关），同样来自 commonConfig 的
    /// `config."3"`，和 `chargePlanLimit` 同源。拉不到就是 nil。
    var chargePlan: ChargePlan?

    /// 按候选顺序取第一个真的有值的 key。
    /// 车端不是每次都上报同一批字段，只认一个 key 会让整项时有时无。
    func raw(_ signal: VehicleSignal) -> String? {
        for key in schema.candidates(for: signal) {
            if let value = signalMap[key], !value.isEmpty { return value }
        }
        return nil
    }

    func int(_ signal: VehicleSignal) -> Int? {
        guard let value = raw(signal) else { return nil }
        return Int(value) ?? Int(Double(value) ?? .nan)
    }

    func double(_ signal: VehicleSignal) -> Double? {
        guard let value = raw(signal) else { return nil }
        return Double(value)
    }

    func bool(_ signal: VehicleSignal) -> Bool? {
        guard let value = raw(signal)?.lowercased() else { return nil }
        if value == "true" || value == "1" { return true }
        if value == "false" || value == "0" { return false }
        return nil
    }

    // 电池
    var soc: Int? { int(.soc) }
    var expectedMileage: Int? { int(.expectedMileage) }
    var batteryVoltage: Double? { double(.batteryVoltage) }
    var batteryCurrent: Double? { double(.batteryCurrent) }
    var dumpEnergyWh: Double? { double(.dumpEnergy) }
    /// 语义口径直接有 `chargesocSetting` 信号；数字口径没有这个信号，
    /// 退到充电计划里的 percent（官方 C11 的充电上限就是从那儿读的）。
    var chargeLimit: Int? { int(.chargeLimit) ?? chargePlanLimit }

    /// 从 config 对象里取充电计划的充电上限。
    ///
    /// 官方 `NewServerCarStateBean.ConfigBean` 里 `@SerializedName("3")` 是充电计划
    /// （`OooOOO0.java:123`：percent 非空才 `parseInt` 进 `chargeSocSetting`）。
    /// 反编译的 bean 名叫 `_$3`，为防哪台车的网关按 bean 名回，两个 key 都认。
    ///
    /// config 不在车况响应里——官方是另发 commonConfig 接口拿的（`queryCarInfoAndConfig`
    /// 里的 `queryConfig`），拿回来再和车况合并成 `NewServerCarStateBean` 才读这个 percent。
    /// 现在这条接口已经抓到并接入（见 `LeapClient.fetchCommonConfig()`），`config` 就是它
    /// 返回的 `data.config`。和完整的 `ChargePlan` 同源——只是这里只要 percent 一个数。
    static func chargePlanLimit(fromConfig config: JSONValue?) -> Int? {
        ChargePlan.fromConfig(config)?.percent
    }
    var chargeRemainMinutes: Int? { int(.chargeRemainTime) }
    var minSingleTemp: Int? { int(.minSingleTemp) }
    var chargeTimeSetting: String? { raw(.chargeTimeSetting) }
    /// 0 未在充电，1 充电中，2 本次充电已结束，3 故障，4 预约等待，6 暂停。
    ///
    /// 注意 `0` 不等于「没插枪」——C11 实测插着枪等待充电时这里就是 0，
    /// 插枪与否要看 ``chargeGunConnected``。
    var chargeState: Int? { int(.chargeState) }
    var isCharging: Bool { chargeState == 1 }
    /// 健康充电开关是否开启。数字口径 C11 报信号 `48`（`isCarHealthyChargeOpen`，1=开、0=关，
    /// 2026-08-18 关→开往返实测确认），读不到返回 nil。写入见 ``LeapCommand.healthyCharge(on:)``。
    var healthyChargeOn: Bool? { bool(.healthyCharge) }
    /// 充电枪是否插上。只有 C11 那套数字 ID 报这一项，S01 / T03 读不到（返回 nil）。
    ///
    /// 快充枪和慢充枪是两个独立信号，官方判「插枪了没」是两者取或
    /// （`o00O0O.java:52`）。只看慢充那个会把直流快充整个漏掉——插着快充枪
    /// 却显示「未连接充电枪」。
    var chargeGunConnected: Bool? {
        let fast = raw(.fastCharging).map { $0 != "0" }
        let slow = bool(.chargeGunConnected)
        guard fast != nil || slow != nil else { return nil }
        return fast == true || slow == true
    }

    /// 插的是不是直流快充枪。和 `chargeGunConnected` 里的快充项同源，单独露出来给
    /// 充电记录用——那边要区分「这趟是快充还是慢充」，只在两者的或里取不到这个信息。
    var isFastChargingConnected: Bool {
        raw(.fastCharging).map { $0 != "0" } ?? false
    }

    /// 充电功率（kW）。车不上报功率，用电压 × 电流算——这两个都是车实报的。
    ///
    /// 电流充电时是负的（电流流进电池），取绝对值。
    /// 实测对得上：724.4 V × 8.699 A = 6.30 kW，交流慢充的典型功率。
    var chargePowerKW: Double? {
        guard let voltage = batteryVoltage, let current = batteryCurrent else { return nil }
        return abs(voltage * current) / 1000
    }

    enum BatteryPreheatStatus: Equatable {
        case heating
        case temperatureGood
        case inactive
        case unknown
    }

    /// 官方 App 的“温度良好，无需加热”对应热管理请求档位为 0，且实际 PTC 没有输出功率。
    /// 只有数字车型的 1348 是已确认的实际功率；语义车型的设定值不参与判定。
    var batteryPreheatStatus: BatteryPreheatStatus {
        let power = double(.ptcPower)
        if power.map({ $0 > 0 }) == true { return .heating }
        guard let request = int(.thermalManageRequest) else {
            // 读到了实际功率、而且是 0：这就足以断定没在加热，只是分不出是「温度够了」
            // 还是「压根没开」。**不能因此退回 `.unknown`**——那会让界面把一个已知的
            // 「没加热」说成「读不到」。真正读不到是另一回事：功率字段本身缺席。
            return power == nil ? .unknown : .inactive
        }
        return request == 0 ? .temperatureGood : .inactive
    }

    var isBatteryPreheating: Bool? {
        switch batteryPreheatStatus {
        case .heating: return true
        case .temperatureGood, .inactive: return false
        case .unknown: return nil
        }
    }
    /// 直流快充。判据抄官方 `LPNewStatusBinaryParser`：**非空且不等于 `0`**——
    /// 不是 `== "1"`。数字口径那个信号不止 0/1 两个取值，只判 1 会把别的快充档漏掉。
    var isFastCharging: Bool {
        guard let value = raw(.fastCharging), !value.isEmpty else { return false }
        return value != "0"
    }

    // MARK: 增程
    //
    // 官方按 `workingCondition` 在 CLTC / WLTC 里**二选一**，不是两套都显示，
    // 也不显示总续航——纯电续航和汽油续航分开列两个数。这里照搬。
    //
    // 纯电车也会报这一组里的**纯电那几项**（`3257` `3260` 就等于标定出来的续航），
    // 所以不能拿「有没有这些字段」判断是不是增程车。

    /// 这台车是不是增程/混动车——决定要不要显示油量。
    ///
    /// 判据就一条：``isExtendRange``，来自 `vehicle/list` 里那辆车的 `abilities` 能力码
    /// 含 `"39"`（官方内部 key `isExtendRange`）。官方就是这么判的
    /// （`RemoteContorllerUtil.OooO00o(能力码)`，数据出自 `PhoneUtils.getCarPer`），
    /// **完全不看车况 signalMap**。
    ///
    /// 曾经拿 signalMap 里的汽油信号判，三份实测怎么挑字段都不稳，最后全踩了坑：
    ///
    ///                      增程版 C11    纯电 C11（800V）  纯电 C01   纯电 C11（400V）
    ///   3256 CLTC 汽油续航     506            缺席            缺席          200 ← 也报！
    ///   3259 WLTC 汽油续航     541            缺席            缺席          486 ← 也报！
    ///   3235 油量%            68.5           缺席              0            —
    ///   2956 fuelLevel          0              0             缺席           —
    ///   2946 fuelHeating        0              1               0           —
    ///
    /// - 拿 `fuelLevel != nil` 判：纯电 C11（800V）照样报 `2956=0`，被误判成增程。
    /// - 拿 `油量% != nil` 判：纯电 C01 报 `0`，`0 != nil` 成立，又被误判成增程。
    /// - 拿 `汽油续航 != nil` 判：纯电 C11（400V）实报 `3256=200`/`3259=486`，还是误判。
    ///
    /// signalMap 里就没有一个信号能干净地把纯电和增程分开，方向从根上就是错的。
    /// 换成 `abilities` 含 `"39"` 的能力码判据后，上面这些纯电车全部正确判为纯电。
    var hasFuel: Bool { isExtendRange }
    /// 油量百分比。纯电车即使报了这一项也不给——纯电 C01 报的是 `0`，
    /// 直接透出去首页和桌面卡片就会画一条空油量条。
    var gasolinePercent: Int? { hasFuel ? int(.gasolinePercent) : nil }
    /// 纯电续航（km），按车机设的口径取 CLTC 或 WLTC。
    var energyRange: Int? { int(usesWLTC ? .wltcEnergyRange : .cltcEnergyRange) }
    /// 汽油续航（km），同上。
    var gasolineRange: Int? { int(usesWLTC ? .wltcGasolineRange : .cltcGasolineRange) }
    /// 综合续航（km）。官方小组件不显示它，但详情页给得下。
    var totalRange: Int? { int(usesWLTC ? .wltcTotalRange : .cltcTotalRange) }
    /// 燃油加热中。
    ///
    /// 先要是台有油箱的车：纯电 C11 实测 `2946 = 1`，光看这个字段会说它在给燃油加热。
    /// 官方判据还多一个条件（`AirController` 里某个空调状态同时成立），那个状态我们没有，
    /// 所以这里先用 `hasFuel`（即是不是增程车）把纯电车整个挡在门外，避免最离谱的误报。
    var isFuelHeating: Bool { hasFuel && (bool(.fuelHeating) ?? false) }
    /// `1` = WLTC，其余（含读不到）按 CLTC。
    private var usesWLTC: Bool { int(.workingCondition) == 1 }

    // 驾驶状态
    /// 行车中。官方判据就是挡位取 1 或 3。
    var isDriving: Bool { [1, 3].contains(int(.gearStatus) ?? -1) }
    /// ON3 电源位。官方拿它当远程控车可用的前提。
    var powerOn3: Bool? { bool(.powerOn3) }

    // 门锁
    var isLocked: Bool? { bool(.driverDoorLocked) }
    var doorControlAllowed: Bool { bool(.doorControlAllowed) ?? true }
    var trunkOpen: Bool? { bool(.trunkOpen) }
    var frontTrunkOpen: Bool? { bool(.frontTrunkOpen) }
    var anyDoorOpen: Bool {
        [.driverDoor, .passengerDoor, .leftRearDoor, .rightRearDoor]
            .contains { bool($0) == true }
    }

    // 车窗。对外一律是开度百分比：0 关闭、100 全开。
    // 车端原始刻度各车型不同——S01 是倒过来的 0…10，C11 是 0…100——换算收在 `WindowScale` 里，
    // 这样界面不用知道每台车的刻度是怎么回事。
    /// 这台车能不能远程控车窗。
    ///
    /// **支持位单独用判不出来**：两台 T03 实测（2026-08-10），一台能控、一台不能，
    /// `isSupportWindowsRemoteControl` **都报 `2`**。官方那条 `== 2` 是必要不充分条件。
    ///
    /// 真正的分水岭是**四个开度字段在不在**：能控的那台 60 个字段，比不能控的多且只多
    /// `leftFrontWindowPercent` 那四个开度（外加一个无关的 `parkOutEnable`）；
    /// 不能控的那台只有 `*WindowStatus` 四个开合状态位。讲得通——电动升降窗的电机有位置
    /// 反馈才报得出开度，手摇窗只有一组给防盗用的开关传感器。官方在 `isT03Car()` 分支里
    /// 读的正是 `leftFrontWindowPercent`，也是同一个道理。
    ///
    /// **这条只对语义名那套（S01 / T03）成立，绝不能推广到数字口径**：C11 增程版实测
    /// 四个开度全缺，但它的车窗是能控的（官方只拿开度喂 3D 车模动画，判开合走状态位），
    /// 而且数字口径那套压根不报支持位——官方在那套解析里直接把车窗开关置 true。
    /// 所以下面按「有没有报支持位」来区分两套口径，不看车型也不看表的 id。
    var windowsRemoteSupported: Bool {
        guard let flag = raw(.windowsRemoteSupported) else {
            // 没报支持位 = 数字口径那套，官方无条件放行。
            return true
        }
        guard flag == "2" else { return false }
        return [.leftFrontWindow, .rightFrontWindow, .leftRearWindow, .rightRearWindow]
            .contains { raw($0) != nil }
    }
    var leftFrontWindow: Int? { windowOpenness(.leftFrontWindow) }
    var rightFrontWindow: Int? { windowOpenness(.rightFrontWindow) }
    var leftRearWindow: Int? { windowOpenness(.leftRearWindow) }
    var rightRearWindow: Int? { windowOpenness(.rightRearWindow) }

    private func windowOpenness(_ signal: VehicleSignal) -> Int? {
        guard let value = int(signal) else { return nil }
        return schema.windowScale.openness(raw: value)
    }

    /// 从开度字段判开没开。判据按车型各自的源码来（S01 是 `!= 10`、T03 是 `!= 0`），
    /// 不是统一的「百分比 > 0」——换算成百分比之前就得先判，不然 T03 的量程一含糊，
    /// 开合也跟着不准。
    private func windowOpenByOpenness(_ signal: VehicleSignal) -> Bool? {
        guard let value = int(signal) else { return nil }
        return schema.windowScale.isOpen(raw: value)
    }

    /// 单扇窗的开合状态位。官方判据原样照抄：**非 `"0"` 即开**
    /// （`OooOOO0.OooO0OO()` 里 `!get_$1693().equals("0")`），不是 `== "2"`——
    /// 这组信号不止 0/2 两个取值，只认 2 会把别的开启档漏成「关着」。
    ///
    /// **布尔字面量要先认**：T03 这组状态位报的是 `"true"` / `"false"`（实测），
    /// 而 `"false" != "0"` 是成立的——直接套官方判据，四扇关好的窗会全报成开着。
    /// 数字口径那组不受影响：`"0"` 走布尔分支同样是 false，`"2"` 认不出布尔、
    /// 落回 `!= "0"` 仍是开着。
    private func windowOpenFlag(_ signal: VehicleSignal) -> Bool? {
        guard let value = raw(signal), !value.isEmpty else { return nil }
        if let flag = bool(signal) { return flag }
        return value != "0"
    }

    var leftFrontWindowOpen: Bool? { windowOpenFlag(.leftFrontWindowOpen) }
    var rightFrontWindowOpen: Bool? { windowOpenFlag(.rightFrontWindowOpen) }
    var leftRearWindowOpen: Bool? { windowOpenFlag(.leftRearWindowOpen) }
    var rightRearWindowOpen: Bool? { windowOpenFlag(.rightRearWindowOpen) }

    /// 有没有窗开着。读不到任何一路车窗信号时是 nil——不知道不等于关好了。
    ///
    /// **两组信号取或：任何一路说开就算开**，不分主次。
    ///
    /// 先前是「状态位优先、开度兜底」，被真车打脸：2026-08-10 那台 T03 车窗实际开着，
    /// 四扇开度都报 `18`，而四个 `*WindowStatus` **仍然全报 `false`**（车况是 34 秒前的，
    /// 不是没刷新）。状态位优先于是界面说「已关」——该报的时候不报，比不知道更糟。
    ///
    /// 反过来「开度优先」也不对：官方在两套口径上判据本来就不一样——数字口径（C11）
    /// 判开合读的是状态位 `1693…1696`（开度那组只喂 3D 车模动画），而语义名口径的
    /// T03 分支（`isT03Car()`）判的是开度 `leftFrontWindowPercent != 0`。真按开度优先，
    /// C11 那边「开度报 0、状态位说开」的情形会被读成关着。
    ///
    /// 取或同时满足两边，而且方向是安全的：宁可多报一次「窗开着」，不能漏报。
    /// 两组都读不到才是 nil——不知道不等于关好了。
    var anyWindowOpen: Bool? {
        let readings = opennessWindowSignals.map { windowOpenByOpenness($0) }
            + [leftFrontWindowOpen, rightFrontWindowOpen, leftRearWindowOpen, rightRearWindowOpen]
        guard readings.contains(where: { $0 != nil }) else { return nil }
        return readings.contains { $0 == true }
    }

    /// 这台车按开度口径实际有的车窗。
    ///
    /// S01（`invertedTen`）是两门轿跑，**没有后窗**——车端后窗字段恒报占位 `0`，
    /// 而倒序刻度里 `0` 恰好是「全开」。把后窗算进来，关好的 S01 会因为那个占位 0
    /// 被读成「全开」，整车永远显示车窗开着（就是这次的回归）。所以倒序刻度只认前两扇。
    /// `percent`（C11 / T03）那套后窗是真的，四扇全认。
    private var opennessWindowSignals: [VehicleSignal] {
        schema.windowScale == .invertedTen
            ? [.leftFrontWindow, .rightFrontWindow]
            : [.leftFrontWindow, .rightFrontWindow, .leftRearWindow, .rightRearWindow]
    }

    /// 锁车成功那一刻还开着的东西，给「已上锁，但 XX 还开着」那句提示用。
    ///
    /// 只列**读得到且确实开着**的项，读不到的一律不算——不知道不等于开着，也不能猜。
    /// 单扇窗的判据跟 ``anyWindowOpen`` 同一套（开度和状态位取或），四扇都开就合成一个「车窗」。
    /// 遮阳帘不在里面：它开着不是隐患，锁车时不必提醒。
    var openItemsAfterLock: [String] {
        var items: [String] = []
        if anyDoorOpen { items.append("车门") }
        let windows: [(String, VehicleSignal, Bool?)] = [
            ("主驾车窗", .leftFrontWindow, leftFrontWindowOpen),
            ("副驾车窗", .rightFrontWindow, rightFrontWindowOpen),
            ("左后车窗", .leftRearWindow, leftRearWindowOpen),
            ("右后车窗", .rightRearWindow, rightRearWindowOpen)
        ]
        let openWindows = windows.filter { _, signal, flag in
            let byOpenness = opennessWindowSignals.contains(signal) ? windowOpenByOpenness(signal) : nil
            return byOpenness == true || flag == true
        }.map(\.0)
        if openWindows.count == windows.count {
            items.append("车窗")
        } else {
            items += openWindows
        }
        if sunroofOpen == true { items.append("天窗") }
        if trunkOpen == true { items.append("尾门") }
        if frontTrunkOpen == true { items.append("前备箱") }
        return items
    }

    /// 有开度的那几扇窗里开得最大的那个开度。车不报开度时是 nil——**这和「关着」是两回事**，
    /// 界面得靠 ``anyWindowOpen`` 才知道到底开没开。
    var maxWindowOpenness: Int? {
        opennessWindowSignals
            .compactMap { windowOpenness($0) }
            .max()
    }

    // 空调
    var acOn: Bool { bool(.acSwitch) ?? false }
    /// -1 表示无有效值；夹取到 18…32。
    var acSetting: Int? {
        guard let value = int(.acSetting), value >= 0 else { return nil }
        return min(32, max(18, value))
    }
    var acFanLevel: Int? { int(.acFanLevel) }
    /// 车端上报的空调模式原始值。各车型编码不是一套，解释见 `ClimateModeCoding`。
    var acModeRaw: Int? { int(.acMode) }
    /// 车上当前的空调模式。车没上报就是 nil——和「上报了、是自动」是两回事。
    var climateMode: ClimateMode? { schema.climateModeCoding.mode(raw: acModeRaw) }
    /// true=内循环。
    ///
    /// 数字口径（C11 那批）原先**没有这一项**，空调页那张「内循环 / 外循环」卡只能显示本机草稿。
    /// 2026-11-19 补上信号 `1943` 后两套口径都能读到真实状态，`syncDraftsFromState` 会自动对齐。
    var acCircleIn: Bool? { bool(.acCircleMode) }
    /// 前挡除雾（除霜）状态位。数字口径信号 `1945`，读不到 nil。
    var windshieldDefrostOn: Bool? { bool(.windshieldDefrost) }
    /// 快速降温 / 快速制热是否正在执行。数字口径信号 `2669` / `2681`。
    ///
    /// 这两个 ID 之前只在胎压误报那段注释里被排除为「含义未知的其它信号」
    /// （当时抓到 `2669=1`、`2681=2`），2026-11-19 定名，见 `SignalSchema.numeric` 的说明。
    var rapidCoolingOn: Bool? { bool(.rapidCooling) }
    var rapidHeatingOn: Bool? { bool(.rapidHeating) }
    /// true=auto，false=manual
    var acAutoMode: Bool? { bool(.acTempMode) }
    var indoorTemp: Double? { double(.indoorTemp) }
    var outdoorTemp: Double? { double(.outdoorTemp) }

    // MARK: 哨兵
    /// 哨兵模式当前是否开启。来自 signalMap 信号 `3636`（`== 1` 为开），走 `SignalSchema` 的
    /// `.sentinel` 映射，写法同 `acOn`。只有支持哨兵的车（非 S01/T03，数字口径）才报这一位，
    /// 其余车型读不到即 `false`。
    ///
    /// 注意这是**状态**（当前开没开），和车辆的**支持判据**（`Vehicle.isSentinelSupported`，
    /// 来自 `permission` 含 `"400"`）是两回事，别混——一个说这车能不能哨兵，一个说这会儿哨兵开着没。
    var sentinelOn: Bool { bool(.sentinel) ?? false }

    // MARK: 遮阳帘 / 天窗
    /// 遮阳帘开没开（信号 `1724`，0…100 开度）。开度 > 0 就算开、等于 0 才算关——
    /// 下发 `240` 开发的是 `"10"`，车回报的开度是 10 还是 100 没验过，所以不拿目标值比对。
    /// 读不到 nil。
    var sunshadeOpen: Bool? {
        guard let value = int(.sunshadeOpening) else { return nil }
        return value > 0
    }

    /// 天窗开没开（信号 `1718`，0…10 开度）。
    ///
    /// **超出 0…10 一律当读不到**：没选装可开启天窗的车会报 `15` / `150` 这类 CAN 占位值
    /// （Signal Not Available），按「> 0 即开」读会把一辆根本没天窗的车说成天窗开着。
    var sunroofOpen: Bool? {
        guard let value = int(.sunroofOpening), (0...10).contains(value) else { return nil }
        return value > 0
    }

    // 胎压（S01 实测 249–261，量级与 kPa 一致）
    var tirePressures: [(label: String, kPa: Double?, warning: Bool)] {
        [
            ("左前", double(.leftFrontTirePressure), raw(.leftFrontTireState) == "1"),
            ("右前", double(.rightFrontTirePressure), raw(.rightFrontTireState) == "1"),
            ("左后", double(.leftRearTirePressure), raw(.leftRearTireState) == "1"),
            ("右后", double(.rightRearTirePressure), raw(.rightRearTireState) == "1")
        ]
    }

    var hasTireData: Bool { tirePressures.contains { $0.kPa != nil } }
    var hasTireWarning: Bool { tirePressures.contains { $0.warning } }

    // 位置
    /// 车端上报的经纬度**原样**，未做任何换算。要显示、要算距离、要跳地图一律用
    /// ``shareableCoordinate``，别用这两个——它们可能还是 WGS-84。
    var latitude: Double? { coordinateReading?.coordinate.latitude }
    var longitude: Double? { coordinateReading?.coordinate.longitude }
    var privacyGPSAllowed: Bool { bool(.privacyGPS) ?? true }
    var collectTime: String? { raw(.collectTime) }
    var totalMileage: Int? { int(.totalMileage) }

    /// 车端采集这份车况的时刻。读不到或不可信时是 nil。
    ///
    /// 和 `VehicleStore.lastUpdated` 是两回事：后者只说明本机什么时候拉的，
    /// 轮询拉得再勤它都是「刚刚」。车休眠着不上报时，服务端会把同一份旧数据一直发回来，
    /// 只有这个字段能看出车况到底有多旧——「刷新不及时」最常见的真身就是它。
    var reportedAt: Date? {
        collectTime.flatMap { VehicleState.parseReportTime($0) }
    }

    /// 车端时间戳解析。两种形态都见过：`2026-08-05 09:40:12` 这样的字面时间，
    /// 以及秒/毫秒 epoch。字面时间不带时区，按本机时区解释——车和手机在同一个国家。
    ///
    /// 解析不出、或者落在「三十天前到五分钟后」这个窗口之外的，一律当读不到：
    /// 车端时间是拿来标注车况新旧的，宁可退回本机拉取时间，也不能报一个 1970 年。
    static func parseReportTime(_ raw: String, now: Date = .now) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let parsed: Date?
        if text.allSatisfy(\.isNumber) {
            guard let value = Double(text), value > 0 else { return nil }
            // 十位数是秒，十三位数是毫秒。按量级判断，不数位数。
            parsed = Date(timeIntervalSince1970: value < 1e11 ? value : value / 1000)
        } else {
            parsed = literalDate(text)
        }

        guard let parsed else { return nil }
        // 允许略微超前：车端时钟和手机差几十秒很常见，不该因此判定为不可信。
        let elapsed = now.timeIntervalSince(parsed)
        guard elapsed > -5 * 60, elapsed < 30 * 24 * 3600 else { return nil }
        return parsed
    }

    /// `2026-08-05 09:40:12` 这类字面时间。日期和时间之间可能是空格也可能是 T，
    /// 秒可以缺省，末尾的毫秒后缀直接扔掉。
    private static func literalDate(_ text: String) -> Date? {
        let halves = text.replacingOccurrences(of: "T", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
        guard let first = halves.first else { return nil }
        let date = first.split(separator: "-")
        let time = halves.count > 1 ? halves[1].split(separator: ":") : []
        guard date.count == 3, time.count >= 2,
              let year = Int(date[0]), let month = Int(date[1]), let day = Int(date[2]),
              let hour = Int(time[0]), let minute = Int(time[1]) else { return nil }
        // 秒位可能带小数（`12.480`），取整数部分。
        let second = time.count > 2 ? Int(Double(time[2]) ?? 0) : 0
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar.current.date(from: components)
    }

    /// 车端上报的第一组有效经纬度，附带它自己的坐标系口径。
    ///
    /// 不用 `raw(_:)` 那套「取第一个有值的 key」：经纬度是成对的，经度和纬度必须来自
    /// 同一组，跨组拼出来的点会飞到几百公里外。所以这里按 `coordinateGroups` 整组整组地
    /// 试，两组都齐了才算一个读数。
    var coordinateReading: (coordinate: CLLocationCoordinate2D, datum: CoordinateDatum)? {
        for group in schema.resolvedCoordinateGroups {
            guard let latitudeText = signalMap[group.latitudeKey], !latitudeText.isEmpty,
                  let longitudeText = signalMap[group.longitudeKey], !longitudeText.isEmpty,
                  let latitude = Double(latitudeText), let longitude = Double(longitudeText)
            else { continue }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            return (coordinate, group.datum)
        }
        return nil
    }

    /// 可以对外展示的车辆坐标。隐私模式下车端不给真实位置，非法值也一并挡掉。
    ///
    /// **出口只有这一个，且交出去的永远是 GCJ-02**：大陆的苹果地图、系统定位、以及
    /// 高德／百度／腾讯用的都是 GCJ-02。车端那几组原始坐标里只有 `2/3` 是 GCJ-02，
    /// 其余是 WGS-84，在这一行转一次——**下游谁都不许再转**，转两遍同样偏半公里，
    /// 方向还正好反过来（见 `CoordinateTransform`）。
    var shareableCoordinate: CLLocationCoordinate2D? {
        guard privacyGPSAllowed, let reading = coordinateReading else { return nil }
        switch reading.datum {
        case .gcj02:
            return reading.coordinate
        case .wgs84:
            let converted = CoordinateTransform.gcj02(fromWGS84: reading.coordinate)
            return CLLocationCoordinate2DIsValid(converted) ? converted : nil
        }
    }
}

// MARK: - 充电计划

/// 充电计划（官方 commonConfig 接口的 `data.config."3"`）。
///
/// 数字口径的车（C11 那批）不把充电上限当信号报，官方是从这张表的 `percent` 读的，
/// 顺带这里还带着预约时段、循环日和开关。整张表由 `LeapClient.fetchCommonConfig()`
/// 单独拉，车况响应里没有——来龙去脉见 `VehicleState.chargePlanLimit(fromConfig:)`。
struct ChargePlan: Equatable, Sendable {
    /// 预约充电起始时刻，形如 `23:00`。
    var beginTime: String
    /// 预约充电结束时刻，形如 `08:00`。
    var endTime: String
    /// 充至的目标电量（%），也就是充电上限。
    var percent: Int
    /// 预约开关（config 里的 `isEnable`）。
    var isEnable: Bool
    /// 循环日，7 位。**顺序按 `cycles[0]=周一 … cycles[6]=周日` 解释**——这是假设：
    /// 实测样本七位全 `1`，无法证伪顺序，官方也没另给对照，暂按周一起头。
    var cycles: [Bool]
    /// 循环模式码，含义未确认，不展示。
    var circulation: Int
    /// 补电标志，含义未确认，不展示。
    var recharge: Int

    /// 从 commonConfig 的整个 config 对象里解析充电计划。
    ///
    /// 官方 `@SerializedName("3")` 是充电计划，反编译 bean 名叫 `_$3`，两个 key 都认
    /// （同 `VehicleState.chargePlanLimit(fromConfig:)`）。`percent` 缺失（含空串）就没有
    /// 充电计划可言，返回 nil——和官方「percent 非空才 parse」的判据一致。
    static func fromConfig(_ config: JSONValue?) -> ChargePlan? {
        guard let plan = config?["3"] ?? config?["_$3"] else { return nil }
        guard let percent = plan["percent"]?.intValue else { return nil }
        return ChargePlan(
            beginTime: plan["beginTime"]?.stringValue ?? "",
            endTime: plan["endTime"]?.stringValue ?? "",
            percent: percent,
            isEnable: (plan["isEnable"]?.intValue ?? 0) == 1,
            cycles: parseCycles(plan["cycles"]?.stringValue),
            circulation: plan["circulation"]?.intValue ?? 0,
            recharge: plan["recharge"]?.intValue ?? 0
        )
    }

    /// `"1,1,1,1,1,1,1"` → 7 个布尔，`1` 为启用。缺位补 `false`、多位截到 7 位，
    /// 读不到就是全 `false`（给 UI 一个稳定的 7 位数组，不必到处判长度）。
    private static func parseCycles(_ raw: String?) -> [Bool] {
        guard let raw, !raw.isEmpty else { return Array(repeating: false, count: 7) }
        var flags = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) == "1" }
        if flags.count < 7 {
            flags.append(contentsOf: Array(repeating: false, count: 7 - flags.count))
        }
        return Array(flags.prefix(7))
    }

    /// 循环日的人类可读文案。**顺序假设 `cycles[0]=周一 … cycles[6]=周日`**（见 `cycles`）。
    /// 全 7 天 → 「每天」；周一~周五且周末关 → 「工作日」；仅周末 → 「周末」；
    /// 一天都没有 → 「从不」；其余列出具体几天，如「周一 周三 周五」。
    var cyclesDescription: String {
        guard cycles.count == 7 else { return "" }
        if cycles.allSatisfy({ $0 }) { return "每天" }
        if !cycles.contains(true) { return "从不" }
        let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        let weekdays = cycles[0..<5]
        let weekend = cycles[5..<7]
        if weekdays.allSatisfy({ $0 }), !weekend.contains(true) { return "工作日" }
        if weekend.allSatisfy({ $0 }), !weekdays.contains(true) { return "周末" }
        return zip(names, cycles).filter { $0.1 }.map { $0.0 }.joined(separator: " ")
    }
}

// MARK: - 控车命令

enum ClimateMode: String, CaseIterable, Identifiable {
    case cold, hot, vent, auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cold: return "制冷"
        case .hot: return "制热"
        case .vent: return "通风"
        case .auto: return "自动"
        }
    }

    var symbol: String {
        switch self {
        case .cold: return "snowflake"
        case .hot: return "flame.fill"
        case .vent: return "wind"
        case .auto: return "a.circle.fill"
        }
    }

    /// S01 / T03 的 acCoolingAndHeating：1=制冷、2=制热、0 和 3 都当自动。
    ///
    /// demo 项目里那条注释写的是「1=hot，2=cold」，是反的：真车正在制冷时上报的就是 `1`。
    /// 字段名本身也是这个顺序——Cooling 在前 Heating 在后。
    /// 这只影响**显示**；下发指令用的是 `wireValue` 的字符串（hot/cold），那套有 demo 的
    /// 命令预设可对，没问题。
    /// 返回 nil 表示车端**没有上报**模式，和「上报了、是自动」是两回事。
    ///
    /// 原来 `default` 一律返回 `.auto`，nil 也落进去。C11 那阵还不上报这个字段，
    /// 于是每次十秒轮询都把用户刚选的「制冷」冲成「自动」——选完等一会儿就变回去。
    ///
    /// 别直接调它：编码各车型不是一套（C11 的 `3` 是制热，不是自动），
    /// 走 `VehicleState.climateMode`，那边会按车型的 `ClimateModeCoding` 解释。
    static func fromRaw(_ raw: Int?) -> ClimateMode? {
        ClimateModeCoding.legacy.mode(raw: raw)
    }

    /// 控车 state 里的 mode 字段。
    ///
    /// `nohotcold` 是**通风**，不是自动——真车实测下发它之后模式原始值变成 `4`，
    /// 自动位 `1939` 仍是 0，电流从 1.0 掉到 0.5（只剩鼓风机在转），车主确认车机上就是通风。
    /// 界面因此多了「通风」这一档。
    ///
    /// 自动那一档试过 `hotcold`：车况纹丝不动，服务端还回 code=0——
    /// 那个值只在读取方向存在，SDK 的下发预设里从没用过。自动最后是靠
    /// `operate: "auto"` 打通的，见 `LeapCommand.climate`；这里保留 `hotcold` 只是要有个值可发。
    var wireValue: String {
        switch self {
        case .cold: return "cold"
        case .hot: return "hot"
        case .vent: return "nohotcold"
        case .auto: return "hotcold"
        }
    }
}

/// 车窗控制界面上的一个可选档位。
struct WindowPreset: Equatable, Sendable, Identifiable {
    let label: String
    /// 开度百分比：0 关闭、100 全开。
    let openness: Int

    var id: Int { openness }
}

/// 车辆驻车时自动上传的最近一张照片。接口没有历史列表，也不会触发车辆临时拍照。
struct ParkingPhoto: Equatable, Sendable {
    let available: Bool
    let url: URL?
    let uploadTime: String?
    let raw: JSONValue

    var displayUploadTime: String? {
        guard let uploadTime else { return nil }
        guard let timestamp = Double(uploadTime), timestamp.isFinite else { return uploadTime }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
        let date = Date(timeIntervalSince1970: seconds)
        return date.formatted(
            Date.FormatStyle(date: .long, time: .shortened)
                .locale(Locale(identifier: "zh_CN"))
        )
    }

    init(response: JSONValue) {
        let data = response["data"]
        let urlText = data?["fileUrl"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploadTime = data?["uploadTime"]?.stringValue
        let url = urlText.flatMap(Self.secureImageURL)
        self.available = url != nil
        self.url = url
        self.uploadTime = uploadTime?.isEmpty == false ? uploadTime : nil
        self.raw = response
    }

    /// 老接口仍可能返回 `http://` 图片地址；图片服务支持 HTTPS，统一在信任边界升级。
    private static func secureImageURL(_ text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        let normalized = text.hasPrefix("//") ? "https:\(text)" : text
        guard var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else { return nil }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.url
    }
}

/// 一条待发送的远控指令：cmdid + state JSON。
/// 指令的预期终态。
///
/// 下发成功只代表服务端受理了，车可能还在休眠，实测要 5–10 秒才动作。
/// 回执接口（`/appremotectl/query`）的返回结构没有任何已验证样本，
/// 拿它判定成败等于猜；车况是车自己报的，才是可信的判据。
/// 所以每条指令声明一个能在 `signalMap` 上验证的终态，轮询车况直到达成。
enum ControlExpectation: Equatable, Sendable {
    case locked(Bool)
    /// 关空调时只看开关；开空调时连设定温度和风量一起看，
    /// 这样"空调开着时只改温度"也能被确认，而不是一开始就判成功。
    case climate(on: Bool, temperature: Int?, fanLevel: Int?, mode: ClimateMode?)
    case windowPosition(Int)
    case trunkOpen(Bool)
    /// 前备箱开合。靠车况信号 1282（`state.frontTrunkOpen`）确认。**语义未经实车验证**：
    /// 官方内部键名叫 `isFrontTrunkLock`，若真值方向和「开」相反，成功的控车会被误报成
    /// 「未收到车辆确认」——实车验证后如有出入在这里修正方向。
    case frontTrunkOpen(Bool)
    /// 哨兵开关。靠 signalMap 3636 翻转确认（`state.sentinelOn`），和门锁/尾门一样车况里查得到。
    case sentinel(Bool)
    /// 座椅加热 / 通风档位。八个座椅信号都在一台 C16 的真实 signalMap 里，档位能直接比对。
    case seatLevel(position: SeatPosition, channel: SeatComfortChannel, level: Int)
    /// 方向盘加热档位（信号 1816）。
    case steeringWheelLevel(Int)
    /// 后视镜加热开关。**三个信号任一翻到位就算确认**：`49`、`50`，还有 `1946`
    /// （后风挡「及外后视镜」电加热除雾）。cmdid 440 到底动的是哪一个没验过，不赌一个。
    case mirrorHeating(Bool)
    /// 遮阳帘 / 天窗开合（信号 `1724` / `1718`）。只在车确实报这个信号时才会用上，
    /// 不报的车构造器直接给 `.unobservable`，见 `LeapCommand.sunshade(open:observable:)`。
    case sunshadeOpen(Bool)
    case sunroofOpen(Bool)
    /// 启停充电（cmdid 193）。确认判据照 leapauto 的实车规则：开始要等充电状态 `1149` 报 1；
    /// 停止接受 0（未在充）/ 2（本次已结束）/ 4（预约等待）/ 6（暂停）——
    /// 3 是故障，不算「停下来了」。
    case charging(Bool)
    /// 车载冰箱。开关必比；开机时再比模式、目标温度、风格，车端没报的项跳过
    /// （照空调那条「缺值不作否决」的宽松判法）。
    case fridge(FridgeSetting)
    /// 鸣笛这类动作车况里没有对应字段，确认不了，只能如实说"已发送"。
    case unobservable

    func isSatisfied(by state: VehicleState) -> Bool {
        switch self {
        case .locked(let expected):
            return state.isLocked == expected

        case .climate(let on, let temperature, let fanLevel, let mode):
            guard state.acOn == on else { return false }
            guard on else { return true }
            // 车端偶尔会夹取或省略某一项，缺值时不作为否决条件——
            // 宁可确认得宽一点，也不要因为一个字段没上报就误报"车辆未响应"。
            if let temperature, let actual = state.acSetting, actual != temperature { return false }
            if let fanLevel, let actual = state.acFanLevel, actual > 0, actual != fanLevel { return false }
            // 模式原来不在判据里。于是「只改模式」那种指令一发出去就立刻判成功——
            // 温度风量本来就没变，第一次轮询就满足了，提示条几秒钟就收，
            // 而车实际要 10 秒左右才动作。用户看着没反应就再按一次，正好赶上第一条生效，
            // 反馈出来就是「每次都要按两次」。
            if let mode, let actual = state.climateMode, actual != mode { return false }
            return true

        case .windowPosition(let expected):
            // 留 ±5 的容差：车窗停位不是数字精确的，T03 实测发 `50` 车报回 `51`，
            // 精确相等会把一次成功的控车判成「未收到车辆确认」。
            // S01 那边刻度本来就是 10 的整倍数，容差对它没有影响。
            guard let actual = state.leftFrontWindow else { return false }
            return abs(actual - expected) <= 5

        case .trunkOpen(let expected):
            return state.trunkOpen == expected

        case .frontTrunkOpen(let expected):
            return state.frontTrunkOpen == expected

        case .sentinel(let expected):
            return state.sentinelOn == expected

        case .sunshadeOpen(let expected):
            return state.sunshadeOpen == expected

        case .sunroofOpen(let expected):
            return state.sunroofOpen == expected

        case .charging(let expected):
            guard let charge = state.chargeState else { return false }
            return expected ? charge == 1 : [0, 2, 4, 6].contains(charge)

        case .seatLevel(let position, let channel, let level):
            guard let actual = state.seatLevel(position, channel) else { return false }
            return actual == level

        case .steeringWheelLevel(let level):
            guard let actual = state.steeringWheelHeatLevel else { return false }
            return actual == level

        case .mirrorHeating(let expected):
            // 三个候选位里只要有一个报到期望值就算确认。全都读不到 / 全都没翻 → 不算。
            let candidates = [
                state.int(.leftMirrorHeating).map { $0 > 0 },
                state.int(.rightMirrorHeating).map { $0 > 0 },
                state.rearWindowHeatingOn
            ]
            return candidates.contains { $0 == expected }

        case .fridge(let setting):
            guard let fridge = state.fridgeState else { return false }
            guard fridge.enabled == setting.enabled else { return false }
            guard setting.enabled else { return true }
            if fridge.mode != setting.mode { return false }
            if let temp = fridge.targetTemp, temp != setting.wireTemperature { return false }
            if fridge.style != setting.style { return false }
            return true

        case .unobservable:
            return false
        }
    }

    var isObservable: Bool { self != .unobservable }
}

struct LeapCommand {
    var cmdid: String
    var stateJSON: String
    var label: String
    /// 目前所有远控都要求操作密码。
    var requiresOperationPassword: Bool = true
    /// 用车况确认这条指令是否真的生效。
    var expectation: ControlExpectation = .unobservable
    /// 只有门锁两条指令有经过实车验证的 BLE 等价值。
    var bleCommand: LeapBLEControlCommand? = nil

    /// 预约类命令走另一个端点，且优先打到 appCenter 而不是 appRegion。
    /// 161=预约电池预热（2026-08-18 实测，见 `apk-analysis/android-battery-charge-interfaces.md` §0.3，
    /// 构造方法 `batteryPreheatAppointment`）；171/361/392 推测为预约充电/预约空调等，含义未确认、
    /// 没有已验证样本，所以还没有对应的构造方法。
    static let appointmentCmdIds: Set<String> = ["161", "171", "361", "392"]

    var isAppointment: Bool { Self.appointmentCmdIds.contains(cmdid) }

    /// 这条指令会动空调设定。取消或失败时界面上的草稿要退回去——
    /// 极速降温、前挡除雾这些也是空调指令，都走 170。
    var changesClimate: Bool { cmdid == "170" }

    static func lock() -> LeapCommand {
        LeapCommand(
            cmdid: "110",
            stateJSON: #"{"value":"lock"}"#,
            label: "上锁",
            expectation: .locked(true),
            bleCommand: .lock
        )
    }

    static func unlock() -> LeapCommand {
        LeapCommand(
            cmdid: "110",
            stateJSON: #"{"value":"unlock"}"#,
            label: "解锁",
            expectation: .locked(false),
            bleCommand: .unlock
        )
    }

    /// 这台车能不能远程关尾门。
    ///
    /// 只有 C11 那套口径的车型能，S01 / T03 不能，三条依据指向同一件事：
    /// 零跑官方 App 在这些车上只给「打开尾门」、没有关闭；真车发过 `cmdid 130` 的
    /// `value=false`，车没有任何反应；车本身也没有能自己合上的电动尾门——
    /// 弹得开、合不上是物理限制，不是接口没适配。
    /// 所以关闭这个选项在这些车上既不该摆在界面上，也不该在后台被替用户发出去。
    static func trunkSupportsClose(carType: String) -> Bool {
        !CarTypeFamily.isLegacyFamily(carType)
    }

    /// 关闭发的 `false` 没有文档依据，是照着开启那条推的。车不认的话指令会静默失败——
    /// 等不到 `trunkOpen` 翻转，App 会如实报「未收到车辆确认」，不会有别的动作。
    /// 界面和卡片都先过 `trunkSupportsClose`，关不了的车型根本走不到这条分支。
    static func trunk(open: Bool = true) -> LeapCommand {
        LeapCommand(
            cmdid: "130",
            stateJSON: open ? #"{"value":"true"}"# : #"{"value":"false"}"#,
            label: open ? "打开尾门" : "关闭尾门",
            expectation: .trunkOpen(open)
        )
    }

    static func horn() -> LeapCommand {
        LeapCommand(cmdid: "120", stateJSON: #"{"value":"true"}"#, label: "鸣笛寻车")
    }

    /// 哨兵模式开 / 关。抓包实测（`apk-analysis/sentinel-mode-interfaces.md` §1）：
    /// `cmdid=400`，state 的 key 是 **`operation`**——开 `{"operation":"on"}`、关 `{"operation":"off"}`，
    /// 注意不是别的命令用的 `value`。和尾门 130 同路，`requiresOperationPassword` 默认 `true`，
    /// 复用现有操作密码流程。开关翻转靠车况信号 3636 确认（见 `VehicleState.sentinelOn`）。
    static func sentinel(_ on: Bool) -> LeapCommand {
        LeapCommand(
            cmdid: "400",
            stateJSON: on ? #"{"operation":"on"}"# : #"{"operation":"off"}"#,
            label: on ? "开启哨兵" : "关闭哨兵",
            expectation: .sentinel(on)
        )
    }

    /// 天幕遮阳帘开 / 关。cmdid 240（实车验证过 cmdid）：
    /// 开 `{"value":"10"}`、关 `{"value":"0"}`。两套口径都没有已接入的遮阳帘状态位
    /// （T03 样本里的 `sunShade` 只有关闭态样本、值域未实测，SignalSchema 没映射），
    /// 确认不了就如实 `.unobservable`，发完只报「已发送」。
    ///
    /// **2026-11-19 起可确认**：遮阳帘开度是信号 `1724`（0…100），实测 C16 在报。
    /// 但不是每台车都报，所以由调用方告诉这条指令「这车报不报」——报就等信号翻转，
    /// 不报仍走 `.unobservable`，发完如实说「已发送」。不能一刀切成可观测：
    /// 不报的车会永远等不到翻转，每次都误报「未收到车辆确认」。
    static func sunshade(open: Bool, observable: Bool = false) -> LeapCommand {
        LeapCommand(
            cmdid: "240",
            stateJSON: open ? #"{"value":"10"}"# : #"{"value":"0"}"#,
            label: open ? "打开遮阳帘" : "关闭遮阳帘",
            expectation: observable ? .sunshadeOpen(open) : .unobservable
        )
    }

    /// 天窗开 / 关。cmdid 300：开 `{"value":"1"}`、关 `{"value":"0"}`。
    ///
    /// 这里原先写着「任何口径的车况里都没有天窗字段」——那是错的：天窗开度是信号 `1718`
    /// （0…10）。只是车主那台 C16 没有可开启天窗、不报这一项，所以同遮阳帘按车决定可不可观测。
    static func sunroof(open: Bool, observable: Bool = false) -> LeapCommand {
        LeapCommand(
            cmdid: "300",
            stateJSON: open ? #"{"value":"1"}"# : #"{"value":"0"}"#,
            label: open ? "打开天窗" : "关闭天窗",
            expectation: observable ? .sunroofOpen(open) : .unobservable
        )
    }

    /// 前备箱开 / 关。cmdid 131：开 `{"value":"100"}`、关 `{"value":"0"}`。
    /// 确认走车况信号 1282（`VehicleState.frontTrunkOpen`，仅 C11 数字口径有——
    /// 支持判据本来就把 legacy 车型挡在门外，见 `Vehicle.supportsFrunk`）。
    /// 关闭那条和尾门一样是照开启推的：车不认就等不到 1282 翻转，如实报「未收到车辆确认」。
    static func frunk(open: Bool) -> LeapCommand {
        LeapCommand(
            cmdid: "131",
            stateJSON: open ? #"{"value":"100"}"# : #"{"value":"0"}"#,
            label: open ? "打开前备箱" : "关闭前备箱",
            expectation: .frontTrunkOpen(open)
        )
    }

    /// `ptcState` 在 demo 的字段表里标着 confidence: low，枚举映射没确认，
    /// 拿它当判据会误报，所以这条不做车况确认。
    static func batteryPreheat(on: Bool) -> LeapCommand {
        LeapCommand(
            cmdid: "160",
            stateJSON: on ? #"{"value":"ptcon"}"# : #"{"value":"ptcoff"}"#,
            label: on ? "电池预热开启" : "电池预热关闭"
        )
    }

    /// 预约电池预热。cmdid 161（2026-08-18 实测，见 `apk-analysis/android-battery-charge-interfaces.md` §0.3）：
    /// 预约接口要求把预约对象包在 `controls` 数组中，`on` 是字符串 `"1"`/`"0"`，
    /// `set_id` 实测格式是「前缀_VIN_创建毫秒」（官方用 `Android_`，这里如实标 `iOS_`——
    /// 服务端大概率只要求唯一性），`update_time` 与 set_id 尾部同为同一个毫秒时间戳。
    /// `days` 用预约类指令共用的星期编码：**0 = 周日**、1 = 周一 … 6 = 周六（见 `AppointmentWeekday`）。
    /// 2026-11-19 之前界面给周日发的是 7，已改。
    static func batteryPreheatAppointment(
        on: Bool,
        startTime: Date,
        days: [Int] = [1, 2, 3, 4, 5],
        vin: String,
        setID: String? = nil
    ) -> LeapCommand {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = Int(Date.now.timeIntervalSince1970 * 1000)
        let appointmentID = setID ?? "iOS_\(vin)_\(timestamp)"
        let control: [String: Any] = [
            "on": on ? "1" : "0",
            "set_id": appointmentID,
            "start_time": formatter.string(from: startTime),
            "update_time": "\(timestamp)",
            "days": days
        ]
        let data = try? JSONSerialization.data(withJSONObject: ["controls": [control]], options: [.sortedKeys])
        let state = data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"controls":[]}"#
        return LeapCommand(cmdid: "161", stateJSON: state, label: on ? "预约电池预热" : "关闭预约预热")
    }

    /// 健康充电开关。cmdid 480（2026-08-18 实测，见 `apk-analysis/android-battery-charge-interfaces.md` §0.1）：
    /// 开 `{"value":"on"}`、关 `{"value":"off"}`，走普通远控端点（同 `sendControl` 的非预约分支）。
    /// 车况里可判定：signalMap 信号 `48`（见 ``VehicleState.healthyChargeOn``），回读靠下次拉车况。
    static func healthyCharge(on: Bool) -> LeapCommand {
        LeapCommand(
            cmdid: "480",
            stateJSON: on ? #"{"value":"on"}"# : #"{"value":"off"}"#,
            label: on ? "开启健康充电" : "关闭健康充电"
        )
    }

    /// 远程开始 / 停止充电。cmdid 193，走普通远控端点。
    ///
    /// **停止发 `finish`，不是 `stop`**：leapauto 2026-10-31 官方抓包确认车端 OBC 只认
    /// `start` / `finish`，发 `stop` 服务端照收、车不理。确认判据见 `ControlExpectation.charging`。
    static func charging(start: Bool) -> LeapCommand {
        LeapCommand(
            cmdid: "193",
            stateJSON: start ? #"{"value":"start"}"# : #"{"value":"finish"}"#,
            label: start ? "开始充电" : "停止充电",
            expectation: .charging(start)
        )
    }

    /// 解锁充电枪。cmdid 192，state 的 key 是 `operation`（同哨兵，不是 `value`）。
    ///
    /// **确认不了**，只能如实说「已发送」。看着能用的信号 `94`（官方读作慢充枪锁止）不行：
    /// 我们 C11 四种情形实测过，停充未拔枪时它已经是 0——拿它当判据，「解锁」一发出就被判成功，
    /// 是假确认。插枪位 `47` 也不行：解锁后枪还插着，要人去拔它才翻。
    static func unlockChargingGun() -> LeapCommand {
        LeapCommand(
            cmdid: "192",
            stateJSON: #"{"operation":"unlock"}"#,
            label: "解锁充电枪"
        )
    }

    /// 充电上限 + 预约充电（合并一条，cmdid 190；2026-08-18 实测见 §0.2）。
    ///
    /// 写入字段名与读取 `config."3"` 不同、且全小写：`percent→chargesoc`、`isEnable→chargeEnable`、
    /// `beginTime→starttime`、`endTime→endtime`，`cycles`/`circulation`/`recharge` 同名。
    /// 只改充电上限、不开预约充电也走这条，`chargeEnable=0`。`circulation`/`recharge` 含义未确认，
    /// 原样回填车辆上报的那份（读不到则按实测样本默认 1/0），不擅自改。车况无判定位，`.unobservable`。
    static func chargePlan(
        limitPercent: Int,
        scheduledEnabled: Bool,
        startTime: String,
        endTime: String,
        cycles: [Bool],
        circulation: Int = 1,
        recharge: Int = 0
    ) -> LeapCommand {
        let cyclesStr = (0..<7).map { ($0 < cycles.count && cycles[$0]) ? "1" : "0" }.joined(separator: ",")
        let dict: [String: Any] = [
            "chargesoc": max(50, min(100, limitPercent)),
            "chargeEnable": scheduledEnabled ? 1 : 0,
            "starttime": startTime,
            "endtime": endTime,
            "cycles": cyclesStr,
            "circulation": circulation,
            "recharge": recharge
        ]
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        let state = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return LeapCommand(cmdid: "190", stateJSON: state, label: "充电计划")
    }

    /// 这台车的车窗远控能做到哪几档。
    ///
    /// 零跑车型分两套口径（见 `SignalSchema`），但**下发刻度三套各不相同**，
    /// 换算全收在 `windowValue` 里：S01 是倒序 0…10、T03 是 0…100 百分比、
    /// C11 那组是正序 0…10。界面这一层只认统一的开度百分比，四档人人都做得到。
    ///
    /// 原先 S01 / T03 少一个「半开」档，只有三个按钮。那是没来由的——
    /// S01 的 `5`（倒序 0…10 的中点）和 T03 的 `50` 都是能发的值，
    /// T03 那个 `50` 车主还真车验过就是开一半。C11 那组一直是四档，现在拉齐。
    static func windowPresets(carType: String) -> [WindowPreset] {
        [
            WindowPreset(label: "关闭", openness: 0),
            WindowPreset(label: "微开", openness: 20),
            WindowPreset(label: "半开", openness: 50),
            WindowPreset(label: "全开", openness: 100)
        ]
    }

    /// 给滑杆的车型：S01 和 T03。
    ///
    /// 能不能给滑杆看两条：刻度得是连续的，且下发和上报得是同一套刻度——
    /// 松手后车报回来的位置要对得上滑杆停的位置，否则就是「拖到哪儿都没有回音」。
    ///
    /// S01 是 0…10 十一个刻度，早就验过。**T03 是 2026-08-10 验的**，而且比 S01 还干净：
    /// 下发 `50` 车报回 `51`（那个 1 是电机停位精度），刻度是真正的 0…100。
    /// 在此之前这里写着「T03 是离散档位，天然给不了」——那是照 demo 抄的 `0/20/50`
    /// 三档映射留下的误解，同一天被真车推翻了两次（点全开只开一半也是它）。
    ///
    /// C11 那组仍然不给：下发 0…10、上报 0…100，两边不是一套
    /// （见 `window(openness:carType:)` 走 `.unobservable` 的原因）。
    static func windowSupportsSlider(carType: String) -> Bool {
        CarTypeFamily.isLegacyFamily(carType)
    }

    /// `openness` 是开度百分比：0 关闭、100 全开。下发时再换算成这台车认的刻度。
    static func window(openness: Int, carType: String) -> LeapCommand {
        let value = LeapCommand.windowValue(openness: openness, carType: carType)
        // S01 和 T03 的下发刻度和上报刻度是同一套，比对上报值才有意义。
        // C11 那套口径两边不是一套：下发 0…10、上报 0…100，发 `2` 之后车报回来是不是
        // 正好 20 至今没验过，拿它比对会误报未响应。这一条和车型分组无关，
        // 是「下发刻度 ≠ 上报刻度」本身决定的，所以整个 C11 口径的车型都走 `.unobservable`。
        let expectation: ControlExpectation = CarTypeFamily.isLegacyFamily(carType)
            ? .windowPosition(min(100, max(0, openness)))
            : .unobservable
        return LeapCommand(
            cmdid: "230",
            stateJSON: #"{"value":"\#(value)"}"#,
            label: "车窗控制",
            expectation: expectation
        )
    }

    static func windowValue(openness: Int, carType: String) -> String {
        let value = min(100, max(0, openness))
        if CarTypeFamily.isS01(carType) {
            // S01 下发和上报是同一套：0…10，且 0 是全开。
            return String(WindowScale.invertedTen.raw(openness: value))
        }
        // T03：下发就是 0…100 的百分比，**线性**，原样发。
        //
        // 这里原先抄 demo 映射成 `0 / 20 / 50` 三档，把 `50` 当成"全开档位码"——
        // 2026-08-10 真车证伪：车主点「全开」（我们发 `50`），**车窗只开了一半**。
        // `50` 就是 50%，不是全开。全开得发 `100`。
        // （也顺带排除了官方 `DigUtils.windowPercentForeHex` 那套 0…10 的可能：
        // 那样发 `50` 会超范围被丢掉、车根本不动，而实际车动了、正好一半。）
        if CarTypeFamily.isT03(carType) {
            return String(value)
        }
        // C11 及其余车型（同一套接口口径）：上报是 0…100 的开度百分比，**下发是 0…10**，
        // 差整整十倍。
        //
        // 一度以为上下行同套（S01 是这样）就把百分比原样发出去，真车上发 `20`、`50`
        // 服务端照收 `code=0` 车却不动——超出 0…10 被直接丢掉。回退到老版的 `2`/`5`
        // 才动，但发 `5` 只开一半，说明 `5` 不是全开而是半开。四个档位真车逐一验过：
        // `0` 关、`2` 微开、`5` 半开、`10` 开到底——刻度和 S01 一样是 0…10，只是不倒序。
        return String(value / 10)
    }

    static func climate(
        on: Bool,
        temperature: Int,
        fanLevel: Int,
        mode: ClimateMode,
        circleIn: Bool,
        windshield: Bool,
        position: String = "all"
    ) -> LeapCommand {
        let state: [String: String] = [
            // 自动走 operate 这一层，真车验证过：发 operate=auto 之后模式原始值
            // `3713` 立刻从 1 变 0、自动位 `1939` 从 0 变 1。
            // mode 那一层是死路——hotcold 车根本不认（车况纹丝不动，服务端还回 code=0），
            // nohotcold 是通风。SDK 预设里 operate 只见过 manual/off，auto 是这次试出来的。
            "operate": on ? (mode == .auto ? "auto" : "manual") : "off",
            "temperature": String(temperature),
            "windlevel": String(fanLevel),
            "mode": on ? mode.wireValue : "nohotcold",
            "circle": circleIn ? "in" : "out",
            "wshld": windshield ? "1" : "0",
            // 出风位置。协议本来支持分区（`all` / `wshld` / 座位位置），我们一直硬编码 `all`——
            // 连前挡除雾都在往全车吹，白耗一半风量。现在由调用方给，默认仍是 `all`。
            "position": position
        ]
        let json = (try? JSONSerialization.data(withJSONObject: state))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return LeapCommand(
            cmdid: "170",
            stateJSON: json,
            label: on ? "空调开启" : "空调关闭",
            // 模式现在也进判据了：各车型的原始值编码已经在真车上确认过（见 ClimateModeCoding），
            // 车不上报模式的车型比对时自动跳过，不会误报。
            expectation: .climate(
                on: on,
                temperature: on ? temperature : nil,
                fanLevel: on ? fanLevel : nil,
                mode: on ? mode : nil
            )
        )
    }

    static func quickCool() -> LeapCommand {
        var command = climate(on: true, temperature: 18, fanLevel: 7, mode: .cold, circleIn: true, windshield: false)
        command.label = "极速降温"
        return command
    }

    static func quickHeat() -> LeapCommand {
        var command = climate(on: true, temperature: 32, fanLevel: 7, mode: .hot, circleIn: true, windshield: false)
        command.label = "极速升温"
        return command
    }

    /// 快速除味（leapauto `QUICK_DEODORIZE_STATE`，2026-11-19 对照补上）：
    /// 通风（`nohotcold`，不制冷也不制热）+ **外循环** + 7 档 + 不开除雾，24 ℃ 只是占位——
    /// 通风模式下温度不起作用，但协议要求字段齐全。
    ///
    /// 判据沿用空调那套（开着 / 7 档 / 通风模式），通风的模式原始值真车验过（见 `ClimateMode.vent`）。
    /// **温度不进判据**：通风模式下车会不会把设定温度改成 24 没验过，车若保留原温度，
    /// 带着温度比对就会把成功误报成「未收到车辆确认」。
    /// 外循环 `1943` 也不进判据：它的取值方向只有一次观察，宁可少判一项也不误报。
    static func deodorize() -> LeapCommand {
        var command = climate(on: true, temperature: 24, fanLevel: 7, mode: .vent, circleIn: false, windshield: false)
        command.label = "快速除味"
        command.expectation = .climate(on: true, temperature: nil, fanLevel: 7, mode: .vent)
        return command
    }

    /// 前挡除雾。
    ///
    /// **2026-11-19 修正两处方向错误**：
    /// - `circle` 原先发 `in`（内循环）。除雾的物理前提是把干燥的外气引进来，
    ///   内循环等于把车里的湿气闷住再吹上玻璃，方向是反的。改 `out`。
    /// - `position` 原先跟着 `climate` 硬编码的 `all` 往全车吹，一半风量白耗。改 `wshld`。
    ///
    /// 温度和模式**故意不跟 leapauto**：它那条发的是 24 ℃ 制冷（靠压缩机除湿），
    /// 在冬天结霜的玻璃上不如热风干得快。我们保留 32 ℃ 制热 7 档——
    /// 热风同样是干燥空气，且冬天更对症。真要除霜（结冰）也是热风才化得开。
    static func defrost() -> LeapCommand {
        var command = climate(
            on: true,
            temperature: 32,
            fanLevel: 7,
            mode: .hot,
            circleIn: false,
            windshield: true,
            position: "wshld"
        )
        command.label = "前挡除雾"
        return command
    }
}

/// 控车下发后服务端返回的回执。
struct ControlReceipt: Equatable {
    var msgID: String
    var label: String
    var sentAt: Date = .now
}

// MARK: - 里程能耗统计

/// 里程能耗接口的时间窗（毫秒时间戳，闭区间）。
struct DrivingStatsRange: Sendable {
    var begintime: Int64
    var endtime: Int64

    init(begintime: Int64, endtime: Int64) {
        self.begintime = begintime
        self.endtime = endtime
    }

    /// 秒级区间。`getLastweekEC` 收的是**秒**，而同一个 drivingrecord 命名空间下的
    /// `mileage/energy/detail` 收毫秒。传错量纲不会报越界、也不返空，服务端一律回
    /// `code:2 请求参数含非法字符`——文案指向字符集，跟真实原因半点关系没有。
    /// 单独开两个属性而不是在调用点现除，是为了让这个坑能被测试守住。
    var begintimeSeconds: Int64 { begintime / 1000 }
    var endtimeSeconds: Int64 { endtime / 1000 }

    /// 最近 7 天（含今天），按北京时间整日边界——和官方「里程能耗」页取的区间一致。
    /// mileage/energy/detail 不带时间范围只回退化数据（没有累计能耗、没有按天明细）。
    static func lastSevenDays(now: Date = Date()) -> DrivingStatsRange {
        let cnOffset: TimeInterval = 8 * 3600
        let day: TimeInterval = 86400
        let cnDayStart = (floor((now.timeIntervalSince1970 + cnOffset) / day) * day) - cnOffset
        return DrivingStatsRange(
            begintime: Int64((cnDayStart - 6 * day) * 1000),
            endtime: Int64((cnDayStart + day) * 1000) - 1
        )
    }

    /// 把 `getLastNweeks100kmECAndRank` 给的 `weekStart`/`weekEnd`（"2026-07-06" 这种日期串）
    /// 折成北京时间的整周闭区间——官方点某根周柱子时，`getLastweekEC` 收的就是这个区间。
    /// `weekEnd` 要补到当天 23:59:59.999，只传日零点会把最后一天整天漏掉。
    init?(weekStart: String?, weekEnd: String?) {
        guard let start = DrivingStatsRange.cnDayStartMs(weekStart),
              let end = DrivingStatsRange.cnDayStartMs(weekEnd) else { return nil }
        self.begintime = start
        self.endtime = end + 86_400_000 - 1
    }

    /// "2026-07-06" → 北京时间当天零点的毫秒时间戳。
    ///
    /// 手工拆串而不是过 `DateFormatter`：后者太宽松，`"2026/07/06"` 这种也照收不误，
    /// 悄悄给出一个能用的区间。日期串一律按北京时间解析——设备时区跟着用户跑，
    /// 用本地时区整段会错位一天。
    private static func cnDayStartMs(_ day: String?) -> Int64? {
        guard let day else { return nil }
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let date = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = date
        guard let resolved = calendar.date(from: components) else { return nil }
        return Int64(resolved.timeIntervalSince1970 * 1000)
    }
}

/// 四个 drivingrecord 接口揉成的规范化统计。任一块缺失（接口失败/该车不返回）都为 nil。
struct DrivingStats: Sendable {
    struct Totals: Sendable {
        var totalMileageKm: Int?
        var totalEnergyKwh: Int?
        var deliveryDays: Int?
        var rangeMileageKm: Int?
    }
    struct DailyMileage: Identifiable, Sendable {
        var day: String
        var mileageKm: Int?
        var energyWh: Int?
        var id: String { day }
    }
    struct EnergyDistribution: Sendable {
        var driverKwh: Double
        var acKwh: Double
        var otherKwh: Double
        var totalKwh: Double
        var driverPct: Double?
        var acPct: Double?
        var otherPct: Double?

        init(driverKwh: Double, acKwh: Double, otherKwh: Double, totalKwh: Double,
             driverPct: Double?, acPct: Double?, otherPct: Double?) {
            self.driverKwh = driverKwh
            self.acKwh = acKwh
            self.otherKwh = otherKwh
            self.totalKwh = totalKwh
            self.driverPct = driverPct
            self.acPct = acPct
            self.otherPct = otherPct
        }

        /// 三块用量推出总量和占比，占比留一位小数——和官方饼图的口径一致。
        init(driverKwh: Double, acKwh: Double, otherKwh: Double) {
            let total = driverKwh + acKwh + otherKwh
            func pct(_ part: Double) -> Double? { total > 0 ? ((part / total) * 1000).rounded() / 10 : nil }
            self.init(
                driverKwh: driverKwh, acKwh: acKwh, otherKwh: otherKwh,
                totalKwh: (total * 10).rounded() / 10,
                driverPct: pct(driverKwh), acPct: pct(acKwh), otherPct: pct(otherKwh)
            )
        }

        /// 从 `getLastweekEC` 整份响应解析。三块都是**字符串**，`doubleValue` 负责转。
        /// 没有 `data` 就是这段区间没数据，返回 nil——界面据此整卡隐藏，不填 0。
        init?(raw: JSONValue?) {
            guard let node = raw?["data"] else { return nil }
            self.init(
                driverKwh: node["driverEC"]?.doubleValue ?? 0,
                acKwh: node["acEC"]?.doubleValue ?? 0,
                otherKwh: node["otherEC"]?.doubleValue ?? 0
            )
        }
    }
    struct WeeklyEC: Identifiable, Sendable {
        var weekStart: String?
        var weekEnd: String?
        var hundredKmEc: Double?
        var id: String { (weekStart ?? "") + "~" + (weekEnd ?? "") }
        /// 这一周对应的请求区间。点柱子拉该周能耗构成时用它当 `getLastweekEC` 的入参；
        /// 日期串缺失/畸形就是 nil，这根柱子点不动。
        var range: DrivingStatsRange? { DrivingStatsRange(weekStart: weekStart, weekEnd: weekEnd) }
    }
    struct Weekly: Sendable {
        var rankPercent: String?
        var rankHundredKmEc: Double?
        var weeks: [WeeklyEC]
    }

    var totals: Totals?
    var daily: [DailyMileage]
    var energyDistribution: EnergyDistribution?
    var weekly: Weekly?
    var range: DrivingStatsRange
    /// `energyDistribution` 是哪根周柱子的（值为 `WeeklyEC.id`）。
    /// 正常就是最后一周（本周）——页面默认选中它。周列表没拉到时退回「近 7 天」窗口，
    /// 这时为 nil，界面得跟着改口，不能顶着某一周的名头显示另一个区间的数。
    var distributionWeekID: String?

    /// 空数据（拉取全失败时的兜底），用于 UI 判空。
    var isEmpty: Bool {
        totals == nil && daily.isEmpty && energyDistribution == nil && weekly == nil
    }

    init(totals: Totals?, daily: [DailyMileage], energyDistribution: EnergyDistribution?,
         weekly: Weekly?, range: DrivingStatsRange, distributionWeekID: String? = nil) {
        self.totals = totals
        self.daily = daily
        self.energyDistribution = energyDistribution
        self.weekly = weekly
        self.range = range
        self.distributionWeekID = distributionWeekID
    }

    init(mileageRaw: JSONValue?, distributionRaw: JSONValue?, weeklyRaw: JSONValue?,
         range: DrivingStatsRange, distributionWeekID: String? = nil) {
        self.range = range
        self.distributionWeekID = distributionWeekID

        let mileage = mileageRaw?["data"]
        totals = mileage.map {
            Totals(
                totalMileageKm: $0["totalmileage"]?.intValue,
                totalEnergyKwh: $0["totalEnergy"]?.intValue,
                deliveryDays: $0["deliveryDays"]?.intValue,
                rangeMileageKm: $0["totalAccumulatedMileage"]?.intValue
            )
        }
        daily = (mileage?["detail"]?.arrayValue ?? []).map { entry in
            DailyMileage(
                day: entry["day"]?.stringValue ?? "",
                mileageKm: entry["accumulatedMileage"]?.intValue,
                energyWh: entry["accumulatedEnergyConsume"]?.intValue
            )
        }

        energyDistribution = EnergyDistribution(raw: distributionRaw)

        if let node = weeklyRaw?["data"] {
            weekly = Weekly(
                rankPercent: node["rankResult"]?["rank"]?.stringValue,
                rankHundredKmEc: node["rankResult"]?["hundredKmEC"]?.doubleValue,
                weeks: (node["weeklyEC"]?.arrayValue ?? []).map {
                    WeeklyEC(
                        weekStart: $0["weekStart"]?.stringValue,
                        weekEnd: $0["weekEnd"]?.stringValue,
                        hundredKmEc: $0["hundredKmEC"]?.doubleValue
                    )
                }
            )
        } else {
            weekly = nil
        }
    }
}

/// 爱车页车模型。官方 `carpicture/3d/key` 一个接口同时覆盖两类车：
/// `modelType == 3` 是真 3D（渲染器 + 模型两个 zip，本地 WebView 离线渲染），
/// 其余（S01、C10 等）用 `srcKey` 换到的是一套分层贴图，见 `CarLayerComposer`。
///
/// 响应里还有个 `shareBindUrl` 静态图直链，我们不用——那是分享绑定用的素材，
/// 和官方爱车页显示的不是同一张，角度更偏，也不会跟着车况动。
struct CarModel: Sendable, Equatable {
    var modelType: Int
    var modelVersion: String
    /// 资源包 key。3D 车 `srcKey` 是模型、`h5Key` 是渲染器；
    /// 2D 车只有 `srcKey`，换到的是分层贴图。都走 `carpicture/key/package?key=…`。
    var srcKey: String
    var h5Key: String
    /// 加密整包指针，官方用来做整包校验；我们按 key 下载，留着备查。
    var srcWhole: String
    var h5Whole: String
    /// 渲染器 `newInit` 要的车型参数，字段名与渲染器 `parseServerJson` 完全对应，
    /// 所以换车型不用我们逐个适配文件名——渲染器自己按 carType/year 拼路径。
    var modelParam: CarModelParam?

    var is3D: Bool { modelType == 3 }
    /// 两个包齐了才渲染得起来。
    var has3DPackages: Bool { is3D && !srcKey.isEmpty && !h5Key.isEmpty }

    init(modelType: Int, modelVersion: String,
         srcKey: String, h5Key: String = "", srcWhole: String = "", h5Whole: String = "",
         modelParam: CarModelParam? = nil) {
        self.modelType = modelType
        self.modelVersion = modelVersion
        self.srcKey = srcKey
        self.h5Key = h5Key
        self.srcWhole = srcWhole
        self.h5Whole = h5Whole
        self.modelParam = modelParam
    }

    /// 从 `carpicture/3d/key` 响应解析。没有 `srcKey` 就什么资源都取不到，返回 nil。
    init?(raw: JSONValue?) {
        guard let data = raw?["data"],
              let srcKey = data["srcKey"]?.stringValue, !srcKey.isEmpty else { return nil }
        self.init(
            modelType: data["modelType"]?.intValue ?? 2,
            modelVersion: data["modelVersion"]?.stringValue ?? "",
            srcKey: srcKey,
            h5Key: data["h5Key"]?.stringValue ?? "",
            srcWhole: data["srcWhole"]?.stringValue ?? "",
            h5Whole: data["h5Whole"]?.stringValue ?? "",
            modelParam: CarModelParam(raw: data["modelParam"])
        )
    }
}

/// 3D 渲染器的车型参数。字段名照抄渲染器 `parseServerJson` 读的那几个键，
/// 序列化出来的 JSON 直接就是 `newInit` 的第一个入参。
struct CarModelParam: Sendable, Equatable {
    var carType: String
    var year: Int
    var carTypeCode: String
    var colorCode: Int
    var roofColorCode: Int?
    var seat: Int?
    /// 左右舵。资源文件名的第一段就是它（`C11_2026_0_0_0_…`），
    /// 不传的话渲染器默认按右舵拼路径，国内车全都会 404，然后卡在「加载颜色信息」那步。
    var rudder: Int

    init?(raw: JSONValue?) {
        guard let raw, let carType = raw["carType"]?.stringValue, !carType.isEmpty else { return nil }
        self.carType = carType
        self.year = raw["year"]?.intValue ?? 2025
        self.carTypeCode = raw["carTypeCode"]?.stringValue ?? ""
        self.colorCode = raw["colorCode"]?.intValue ?? 0
        self.roofColorCode = raw["roofColor"]?.intValue
        self.seat = raw["seat"]?.intValue
        // 接口不返回这项，国内车一律左舵。
        self.rudder = raw["rudder"]?.intValue ?? 0
    }

    /// 资源目录名，`C11_2026` 这种。渲染器按同样规则拼资源路径。
    var assetDirectory: String { "\(carType)_\(year)" }

    /// 渲染器 `newInit(serverJson, appJson)` 的第一个入参。
    ///
    /// `alias` 传解压目录反推出来的真实别名（`CarModelAssets.assetAlias`）。
    /// 渲染器 `confirmVehicleLoad` 先按 carType 拼资源目录，404 了才拿 alias 再试一次——
    /// 这个兜底就是给代号和目录名对不上的车型准备的：B05 的目录叫 `Lafa5_2026`。
    /// 反推不出来就不传，让渲染器用包自带的缺省值，总比填一个必然 404 的 carType 强。
    func serverJSON(alias: String?) -> String {
        var fields: [String] = [
            "\"carType\":\"\(carType)\"",
            "\"year\":\(year)",
            "\"carTypeCode\":\"\(carTypeCode)\"",
            "\"colorCode\":\(colorCode)",
            "\"rudder\":\(rudder)",
            // 相机距离。渲染器默认 20 是给全屏爱车页的，车在首页这块小画布里会显得很小；
            // 首页使用 11，配合渲染器参数透传适配保持车身大小。
            "\"radius\":11",
            // 垂直偏移。车默认落在画布正中偏下，正好撞上下面那排状态徽章；
            // 往上提一点，徽章那一行就空出来了。
            "\"offset\":0.3"
        ]
        if let alias, !alias.isEmpty { fields.append("\"alias\":\"\(alias)\"") }
        if let roofColorCode { fields.append("\"roofColorCode\":\(roofColorCode)") }
        if let seat { fields.append("\"seat\":\(seat)") }
        return "{\(fields.joined(separator: ","))}"
    }
}
