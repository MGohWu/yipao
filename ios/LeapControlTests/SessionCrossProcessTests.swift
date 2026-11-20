import Foundation
import Testing
@testable import LeapControl

/// 多进程写同一份会话时，谁的「选中车」说了算。
///
/// App、卡片、控件是三个进程，各自 new 一个 `LeapClient`，手里那份 `LeapSession`
/// 是各自进程启动时从钥匙串读的快照。凭证那一半有 `authRevision` 仲裁，
/// **选中车这一半没有**——所以落盘时整份写回，就会把别的进程刚改的选中车盖掉。
///
/// 曾经的表现：A 车时期起来的卡片进程，在换成 B 账号之后续期，把 A 车写回钥匙串；
/// 设置页显示的是 B 车（读内存），读钥匙串的那一边拿到的却是 A 车。
///
/// 这一组只测纯函数。**走真实钥匙串的那条完整时序在 `SessionSwitchAccountTests`
/// 里**——两个 suite 会并行跑，都去写同一份钥匙串就会互相把对方的会话冲掉。
@Suite("跨进程的会话合并规则")
struct SessionCrossProcessTests {

    private static let vinA = "LSJA1111111111AAAA"
    private static let vinB = "LSJB2222222222BBBB"

    private func makeSession(vin: String, revision: Double, loggedIn: Bool = true) -> LeapSession {
        var session = LeapSession.fresh()
        session.phone = "13800138000"
        session.selectedVin = vin
        session.authRevision = revision
        if loggedIn {
            session.oldAuth = OldAuth(
                accountId: "acc-\(vin)",
                token: "token-\(vin)",
                refreshToken: "refresh-\(vin)",
                nickname: "",
                tokenExpired: "21600",
                tokenObtainedAt: revision,
                tokenExpiresAt: revision + 21_600_000
            )
        }
        return session
    }

    // MARK: - 合并规则

    @Test("续期落盘时，选中车用钥匙串里的，凭证用本进程的")
    func mergeKeepsStoredVehicleAndTakesFreshTokens() throws {
        // 卡片进程手里是几小时前的快照：A 车 + 它刚换到的新凭证。
        let widget = makeSession(vin: Self.vinA, revision: 3_000)
        // 钥匙串里是 App 刚写的：用户已经换到 B 车了。
        let stored = makeSession(vin: Self.vinB, revision: 2_000)

        let merged = try #require(LeapClient.merging(tokensFrom: widget, into: stored))
        #expect(merged.selectedVin == Self.vinB, "选中车必须留钥匙串里那份")
        #expect(merged.oldAuth?.token == widget.oldAuth?.token, "凭证要用本进程刚换来的")
        #expect(merged.authRevision == widget.authRevision)
    }

    @Test("车辆列表和路由也不能被旧快照盖掉")
    func mergeKeepsStoredVehicleList() throws {
        var widget = makeSession(vin: Self.vinA, revision: 3_000)
        widget.vehicles = [Vehicle(vin: Self.vinA, carType: "C11", name: "旧车")]
        var stored = makeSession(vin: Self.vinB, revision: 2_000)
        stored.vehicles = [Vehicle(vin: Self.vinB, carType: "S01", name: "新车")]

        let merged = try #require(LeapClient.merging(tokensFrom: widget, into: stored))
        #expect(merged.vehicles.map(\.vin) == [Self.vinB])
    }

    @Test("续期期间用户退了登，就不该把凭证写回去")
    func mergeRefusesWhenLoggedOut() {
        let widget = makeSession(vin: Self.vinA, revision: 3_000)
        // `logout()` 写的是一份空会话——没有任何凭证。
        let loggedOut = makeSession(vin: "", revision: 4_000, loggedIn: false)

        #expect(LeapClient.merging(tokensFrom: widget, into: loggedOut) == nil,
                "把刚退出的用户装回登录态是最糟的一种写回")
    }
}
