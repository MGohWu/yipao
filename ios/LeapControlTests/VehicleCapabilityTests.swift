import Foundation
import Testing
@testable import LeapControl

/// 能力码支持位的判定。
///
/// 这层存在的理由是一次真实故障：`vehicle/list` **根本没有 `permission` 字段**，能力码全在
/// `abilities` 里（服务端原始短码），而 `loadVehicles` 当时读的是不存在的 `permission` → 恒空
/// → 哨兵/遮阳帘/天窗/前备箱四个支持位对所有真实用户全判假、控制栏第二栏永不展开（只有手填
/// 能力码的体验模式看得到）。修复是把原始 `abilities` 经 `CarPerManager` 那张表翻成内部码。
///
/// 断言用的 `abilities` 直接取自真车 `vehicle/list` 抓包（C16「小灰灰」+ 共享 B10），
/// 翻译表出处见 `apk-analysis/permission-codes-map.md` §5。
@Suite("能力码支持位")
struct VehicleCapabilityTests {

    /// C16「小灰灰」实测 abilities：含 13(遮阳帘)、50(哨兵)，不含 25(天窗)、79(前备箱)。
    private let c16Abilities = ["1","2","3","5","6","7","10","11","12","13","14","15","19","20","21",
        "22","23","24","29","30","31","32","34","35","38","39","41","42","43","45","46","47","48","49",
        "50","51","52","53","55","56","57","58","59","60","61","65","66","67","68","71","72","73","74",
        "75","82","87","88","89"]

    /// B10 共享车实测 abilities：同样含 13、50，不含 25、79。
    private let b10Abilities = ["1","2","3","5","6","7","10","11","12","13","14","15","19","20","21",
        "23","24","29","30","31","32","34","35","38","41","42","45","47","48","50","51","52","53","55",
        "59","60","61","65","68","72","77","82","87","88","89"]

    @Test("原始短码按 CarPerManager 翻成内部码")
    func translatesRawAbilities() {
        // 四条关键映射（三路交叉验证过）：50→400 哨兵、13→240 遮阳帘、25→300 天窗、79→131 前备箱。
        #expect(Vehicle.abilityToPermission["50"] == "400")
        #expect(Vehicle.abilityToPermission["13"] == "240")
        #expect(Vehicle.abilityToPermission["25"] == "300")
        #expect(Vehicle.abilityToPermission["79"] == "131")

        let codes = Vehicle.permissionCodes(fromAbilities: c16Abilities)
        // C16 含 13、50 → 翻出 240、400；不含 25、79 → 没有 300、131。
        #expect(codes.contains("240"))
        #expect(codes.contains("400"))
        #expect(!codes.contains("300"))
        #expect(!codes.contains("131"))
    }

    @Test("C16 支持位：遮阳帘 + 哨兵有，天窗 + 前备箱无")
    func c16SupportFlags() {
        let permission = Vehicle.permissionCodes(fromAbilities: c16Abilities)
        #expect(Vehicle.supportsSunshade(permission: permission))
        #expect(Vehicle.supportsSentinel(carType: "C16", permission: permission))
        #expect(!Vehicle.supportsSunroof(carType: "C16", permission: permission))
        #expect(!Vehicle.supportsFrunk(carType: "C16", permission: permission))
    }

    @Test("B10 支持位：与 C16 一致（遮阳帘 + 哨兵）")
    func b10SupportFlags() {
        let permission = Vehicle.permissionCodes(fromAbilities: b10Abilities)
        #expect(Vehicle.supportsSunshade(permission: permission))
        #expect(Vehicle.supportsSentinel(carType: "B10", permission: permission))
        #expect(!Vehicle.supportsSunroof(carType: "B10", permission: permission))
        #expect(!Vehicle.supportsFrunk(carType: "B10", permission: permission))
    }

    @Test("空 abilities 不再误判为支持（回归：旧代码读不存在的 permission 恒空）")
    func emptyAbilitiesSupportNothing() {
        let permission = Vehicle.permissionCodes(fromAbilities: [])
        #expect(permission.isEmpty)
        #expect(!Vehicle.supportsSunshade(permission: permission))
        #expect(!Vehicle.supportsSentinel(carType: "C16", permission: permission))
    }

    @Test("车型排除：S01/T03 即便翻出内部码也挡哨兵/天窗/前备箱")
    func carTypeExclusion() {
        // 构造一份含全部四个内部码的 permission，验证车型门槛独立生效。
        let full = ["400", "240", "300", "131"]
        for carType in ["S01", "T03"] {
            #expect(!Vehicle.supportsSentinel(carType: carType, permission: full))
            #expect(!Vehicle.supportsSunroof(carType: carType, permission: full))
            #expect(!Vehicle.supportsFrunk(carType: carType, permission: full))
            // 遮阳帘不排除车型，S01/T03 照常按码判。
            #expect(Vehicle.supportsSunshade(permission: full))
        }
    }
}

/// 老会话解码的兜底标志 `abilitiesStale`。
///
/// 和 `SentinelSupportTests.legacySessionMarksStale` 是同一套双保险的另一半（那半盯哨兵、
/// 这半盯增程），两者各有一个 `!container.contains(...)`，是两条独立的代码路径，
/// 所以下面专门有一条交叉验证「只缺一个键」时另一个不跟着变。
///
/// 这层要挡的事故：升级用户持久化的车列表里没有 `isExtendRange` 键，`decodeIfPresent ?? false`
/// 兜出来的 `false` 和「服务端真说了这车是纯电」在解码后长得一模一样，光看值分不出来。
/// 分不出来就不会重拉 `vehicle/list`，增程车被永久判成纯电、油量整块消失且永不自愈。
@Suite("老会话能力码兜底")
struct VehicleLegacyDecodingTests {

    private func decode(_ json: String) throws -> Vehicle {
        try JSONDecoder().decode(Vehicle.self, from: Data(json.utf8))
    }

    @Test("缺 isExtendRange 键 = 老会话，兜底 false 但标记待重拉")
    func legacySessionMarksStale() throws {
        let old = try decode(#"{"vin":"OLD00000000000001","carType":"C11","name":"C11"}"#)
        #expect(old.isExtendRange == false)
        #expect(old.abilitiesStale == true)
    }

    /// 这条是整套双保险的立足点：**显式的 `false` 不算 stale**。
    /// 只看解码后的值，它和上面那条老会话的结果一模一样；能分开，靠的就是键在不在。
    @Test("显式 false 是刷新过的真值，不重拉")
    func explicitFalseIsNotStale() throws {
        let pure = try decode(
            #"{"vin":"LFZ63AZ50SD000001","carType":"C11","name":"C11","isExtendRange":false}"#
        )
        #expect(pure.isExtendRange == false)
        #expect(pure.abilitiesStale == false)
    }

    @Test("显式 true 照常解出增程，也不重拉")
    func explicitTrueIsNotStale() throws {
        let reev = try decode(
            #"{"vin":"LFZ63AL55RD100000","carType":"C11","name":"C11","isExtendRange":true}"#
        )
        #expect(reev.isExtendRange == true)
        #expect(reev.abilitiesStale == false)
    }

    /// 两个 stale 各判各的键，别因为共用了一条 `contains` 就一起亮或一起灭。
    @Test("只缺一个键时另一个 stale 不跟着变")
    func staleFlagsAreIndependent() throws {
        // 有增程键、没哨兵键：只 sentinelStale。
        let noSentinel = try decode(
            #"{"vin":"V1","carType":"C11","name":"C11","isExtendRange":true}"#
        )
        #expect(noSentinel.abilitiesStale == false)
        #expect(noSentinel.sentinelStale == true)

        // 有哨兵键、没增程键：只 abilitiesStale。
        let noAbilities = try decode(
            #"{"vin":"V2","carType":"C11","name":"C11","isSentinelSupported":true}"#
        )
        #expect(noAbilities.abilitiesStale == true)
        #expect(noAbilities.sentinelStale == false)

        // 两个键都在：都不 stale。
        let complete = try decode(
            #"{"vin":"V3","carType":"C11","name":"C11","isExtendRange":false,"isSentinelSupported":false}"#
        )
        #expect(complete.abilitiesStale == false)
        #expect(complete.sentinelStale == false)
    }

    /// stale 是运行时标志，不进 `CodingKeys`：写回会话时不该多出这两个键，
    /// 否则老会话的判据（键在不在）就被这两个键本身搅乱了。
    @Test("stale 不参与持久化")
    func staleIsNotEncoded() throws {
        let old = try decode(#"{"vin":"OLD00000000000001","carType":"C11","name":"C11"}"#)
        #expect(old.abilitiesStale == true)

        let json = try #require(String(data: JSONEncoder().encode(old), encoding: .utf8))
        #expect(!json.contains("abilitiesStale"))
        #expect(!json.contains("sentinelStale"))
        // 编码补齐了两个键，所以再解回来就不再 stale——这不是丢标记：
        // `didLoadVehiclesThisLaunch` 每次启动都从 false 起，首刷本来就会重拉一次 vehicle/list。
        let reencoded = try JSONDecoder().decode(Vehicle.self, from: Data(json.utf8))
        #expect(reencoded.abilitiesStale == false)
    }

    /// `Equatable`/`Hashable` 都是合成的，会把两个 stale 一起算进去：业务字段完全一样、
    /// 只是来源不同的两辆车判不等。钉在这里是为了别把它当 bug 改掉——真要让它们相等，
    /// 就得手写 `==`，而那反过来会让「stale 变了但值没变」的刷新被吃掉。
    @Test("stale 参与 Equatable，两辆同车不同来源判不等")
    func staleAffectsEquality() throws {
        let fresh = Vehicle(vin: "V1", carType: "C11", name: "C11")
        let legacy = try decode(#"{"vin":"V1","carType":"C11","name":"C11"}"#)
        #expect(fresh.isExtendRange == legacy.isExtendRange)
        #expect(fresh != legacy)
    }
}
