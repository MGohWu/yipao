import Foundation
import Testing
@testable import LeapControl

/// 换账号之后，过期进程续期不能把上一辆车写回钥匙串。
///
/// 这一组直接打真实的钥匙串，不是纯函数测试——要复现的正是「钥匙串里的选中车」和
/// 「界面上显示的选中车」不是同一份数据这类问题，把存储换成假的就什么也测不出来了。
///
/// 跑完会把写进去的东西清掉。
@Suite("换账号后的选中车", .serialized)
struct SessionSwitchAccountTests {

    private static let vinA = "LSJA1234567890TEST"
    private static let vinB = "LSJB9876543210OTHER"

    /// 造一份带凭证的会话，给跨进程那条时序用。
    private func makeSession(vin: String, revision: Double) -> LeapSession {
        var session = LeapSession.fresh()
        session.phone = "13800138000"
        session.selectedVin = vin
        session.authRevision = revision
        session.oldAuth = OldAuth(
            accountId: "acc-\(vin)",
            token: "token-\(vin)",
            refreshToken: "refresh-\(vin)",
            nickname: "",
            tokenExpired: "21600",
            tokenObtainedAt: revision,
            tokenExpiresAt: revision + 21_600_000
        )
        return session
    }

    // MARK: - 跨进程覆盖

    /// 把当初那条链子从头走一遍，确认它现在断了。
    @Test("换账号后卡片续期，钥匙串里的选中车不再被写回上一辆")
    func staleProcessNoLongerOverwritesSelectedVehicle() throws {
        defer { SessionStore().clear() }
        let store = SessionStore()

        // 1. A 车时期，卡片进程起来，拿到一份快照。
        store.save(makeSession(vin: Self.vinA, revision: 1_000))
        var widget = try #require(store.load())
        #expect(widget.selectedVin == Self.vinA)

        // 2. 用户登出、登录 B 账号。App 是这一步的权威，走整份写。
        store.save(makeSession(vin: Self.vinB, revision: 2_000))

        // 3. 卡片续期前先同步：发现 App 换发过，采纳凭证后让路。
        //    注意它内存里的选中车仍是 A 车——同步只搬凭证，这一点没变。
        let stored = try #require(store.load())
        widget.oldAuth = stored.oldAuth
        widget.authRevision = stored.authRevision
        #expect(widget.selectedVin == Self.vinA)

        // 4. 版本号追平之后，下一次到期就轮到卡片自己续期并落盘。
        //    以前这里是整份写回，A 车就是在这一步被写回去的。
        widget.authRevision = 3_000
        let current = try #require(store.load())
        let merged = try #require(LeapClient.merging(tokensFrom: widget, into: current))
        store.save(merged)

        #expect(store.load()?.selectedVin == Self.vinB, "选中车必须还是 B 车")
        #expect(store.load()?.selectedVin == Self.vinB, "选中车必须还是 B 车")
    }
}
