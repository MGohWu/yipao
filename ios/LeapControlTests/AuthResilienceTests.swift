import Foundation
import Testing
@testable import LeapControl

/// 登录态自愈依赖的跨进程互斥锁；使用独立锁名并串行验证租约。
@Suite("登录态自愈的零件", .serialized)
struct AuthResilienceTests {

    // MARK: - CrossProcessLock

    /// 测试专用锁文件,别和真实的 token-refresh.lock 抢。
    ///
    /// 租约特意压到 2 秒:上一次跑到一半被中断会留下没释放的租约,默认的 90 秒
    /// 会把后面每一次重跑都堵死,2 秒则等下一轮就自愈。挡 0.2~0.3 秒的竞争者仍绰绰有余。
    private let lock = CrossProcessLock(name: "test-auth-resilience.lock", leaseDuration: 2)

    @Test("拿到的锁在释放前挡住第二次获取,释放后放行")
    func lockIsExclusiveUntilReleased() async throws {
        let first = try #require(await lock.acquire(timeout: 1))

        // 租约以文件在不在为准,同进程再拿一次同样会被挡——
        // 正好能在单测里模拟第二个进程。
        let contender = await lock.acquire(timeout: 0.3, pollInterval: .milliseconds(50))
        #expect(contender == nil, "第一把锁还没释放,第二次获取必须等到超时拿不到")

        first.release()
        let second = await lock.acquire(timeout: 1)
        #expect(second != nil, "释放之后就该立刻能拿到")
        second?.release()
    }

    @Test("超时拿不到锁要返回 nil 而不是卡死")
    func lockTimesOutInsteadOfHanging() async throws {
        let holding = try #require(await lock.acquire(timeout: 1))
        defer { holding.release() }

        let started = Date.now
        let loser = await lock.acquire(timeout: 0.2, pollInterval: .milliseconds(50))
        #expect(loser == nil)
        // 上限放宽到 5 秒:只验「没有卡死等 25 秒默认超时」,不苛求调度精度。
        #expect(Date.now.timeIntervalSince(started) < 5)
    }

    /// 持有者进程猝死不会留下一把谁也拿不到的锁——这是租约取代 flock 之后
    /// 唯一需要自己兜的事:内核不再帮忙回收,过期得由下一个来抢的人清掉。
    @Test("持有者没释放就没了,租约过期后下一个能抢到")
    func expiredLeaseIsTakenOver() async throws {
        let shortLived = CrossProcessLock(name: "test-lease-takeover.lock", leaseDuration: 0.3)
        // 拿到就丢掉不释放,模拟持有者被 SIGKILL。
        _ = try #require(await shortLived.acquire(timeout: 1))

        let blocked = await shortLived.acquire(timeout: 0.1, pollInterval: .milliseconds(50))
        #expect(blocked == nil, "租约还没到期,不该被抢走")

        let taken = await shortLived.acquire(timeout: 3, pollInterval: .milliseconds(50))
        #expect(taken != nil, "租约过期后必须能抢到,否则这把锁就永远拿不回来了")
        taken?.release()
    }

}

/// 设备号（`deviceId`）的存放规则。
///
/// 这一组守的是「按什么控制都提示指令下发失败，请稍后重试，只能重新登录」那个坑：
/// 老链路签名把 deviceID 和 token 绑在一起，服务端按请求里的 deviceID 取它记录的
/// token 重算 MD5，对不上就回 `result=39`。而 App 会把 39 当成「该刷新 token 了」——
/// 刷新永远成功、重试永远失败，用户于是被困在一句「请稍后重试」里。
///
/// 设备号漂移的来路是：重启后未解锁的窗口里进程被拉起（BLE 状态恢复、控件预热），
/// 钥匙串读不到 → 会话按空态起步 → 以前空态会**凭空发一个新设备号** → 一次整份
/// 落盘就把它钉进钥匙串，杀 App、重启手机都恢复不了。
///
/// 用的是独立服务名的钥匙串项，不碰真实登录态，也不会和别的 suite 抢。
/// `.serialized`：几个用例共用同一条钥匙串项，并行跑会互相把对方刚写的清掉。
@Suite("设备号的存放规则", .serialized)
struct DeviceIdentityTests {

    private let store = SessionStore(service: "org.yipao.app.session.tests.deviceid")
    private static let deviceId = "0123456789abcdef0123456789abcdef"

    private func cleanUp() {
        store.clear()
        store.clearDeviceId()
    }

    @Test("空态会话不再凭空发设备号")
    func freshSessionHasNoDeviceId() {
        #expect(LeapSession.fresh().deviceId.isEmpty, "空态发新设备号 = 老链路直接全废")
    }

    @Test("整份写回一份没有设备号的会话，盖不掉已经存着的那个")
    func wholeSaveCannotWipeDeviceId() {
        defer { cleanUp() }
        var session = LeapSession.fresh()
        session.deviceId = Self.deviceId
        store.save(session)

        // 模拟那个读不到钥匙串的进程：手里是空态，却照样整份写回。
        store.save(.fresh())

        #expect(store.loadDeviceId() == Self.deviceId, "设备号单独存放，整份写回不该动它")
        #expect(store.load()?.deviceId == Self.deviceId, "读回来的会话要带上真正的那个设备号")
    }

    @Test("退出登录不清设备号，重新登录还是同一台设备")
    func logoutKeepsDeviceId() {
        defer { cleanUp() }
        var session = LeapSession.fresh()
        session.deviceId = Self.deviceId
        store.save(session)

        store.clear()

        #expect(store.load() == nil, "会话本身要清掉")
        #expect(store.loadDeviceId() == Self.deviceId, "设备号是这台手机的身份，不跟着登录态走")
    }

    @Test("老用户的设备号会从会话里搬进单独条目")
    func migratesDeviceIdFromLegacySession() {
        defer { cleanUp() }
        var legacy = LeapSession.fresh()
        legacy.deviceId = Self.deviceId
        store.save(legacy)
        // 只留会话、删掉单独那条，还原升级前的样子。
        store.clearDeviceId()
        #expect(store.loadDeviceId() == nil)

        _ = store.load()

        #expect(store.loadDeviceId() == Self.deviceId, "读一次就该完成搬迁，之后再也盖不着")
    }

    @Test("空设备号一律不写，不会把真的那个抹成空")
    func emptyDeviceIdIsNeverWritten() {
        defer { cleanUp() }
        store.saveDeviceId(Self.deviceId)
        store.saveDeviceId("")
        #expect(store.loadDeviceId() == Self.deviceId)
    }
}

/// 老链路连续 `result=39` 到什么程度才改口说「要重新登录」。
///
/// 修 A 把 39 从「退登」降成了「瞬时错误」，解决了「服务端抖一下就被踢」，
/// 但只降了一半：真救不回来时，用户会永远看到「请稍后重试」，而重试一万次都不会好。
/// 这一组守的是补上的另一半——次数够、且这串连败跨过足够长的时间，两个条件都满足才升级。
@Suite("老链路连败到什么程度才提示重登")
struct OldAuthEscalationTests {

    private let count = LeapConstants.oldAuthFailureEscalationCount
    private let window = LeapConstants.oldAuthFailureEscalationWindow

    @Test("次数不够不升级")
    func notEnoughFailures() {
        #expect(!LeapClient.shouldEscalateOldAuthFailure(streak: count - 1, spanned: window * 10))
    }

    @Test("次数够了但都挤在几秒内，仍按抖动处理")
    func failuresTooCloseTogether() {
        // 用户连按几下，服务端恰好抖了几秒——这不该让人去重新登录。
        #expect(!LeapClient.shouldEscalateOldAuthFailure(streak: count + 5, spanned: 8))
        #expect(!LeapClient.shouldEscalateOldAuthFailure(streak: count, spanned: window - 1))
    }

    @Test("次数够、且持续了足够久，才提示重新登录")
    func persistentFailuresEscalate() {
        #expect(LeapClient.shouldEscalateOldAuthFailure(streak: count, spanned: window))
        #expect(LeapClient.shouldEscalateOldAuthFailure(streak: count + 1, spanned: window * 2))
    }
}

/// 手里是「空快照」的进程，不许把它整份写回钥匙串。
///
/// 设备号是被这个问题咬得最狠的字段（老链路从此全废），但选中车是同一个源头：
/// 启动那帧钥匙串读不到的进程（锁屏期间被 BLE 恢复/控件预热拉起）内存里选中车是空的，
/// 它一次 `persist()` 就把钥匙串里那辆抹掉——界面读内存、别的进程读钥匙串，
/// 两边从此认的不是同一辆车。
///
/// 用独立的钥匙串 service，跑完就清；同 suite 共用一条条目，所以 `.serialized`。
@Suite("空快照不许整份写回", .serialized)
struct PersistGuardTests {

    private let store = SessionStore(service: "org.yipao.app.session.tests.persistguard")
    private static let deviceId = "fedcba9876543210fedcba9876543210"
    private static let vin = "LSJA1234567890001"

    private func cleanUp() {
        store.clear()
        store.clearDeviceId()
    }

    /// 主 App 那份权威会话：有设备号、有选中车。
    private func authoritativeSession() -> LeapSession {
        var session = LeapSession.fresh()
        session.deviceId = Self.deviceId
        session.selectedVin = Self.vin
        session.selectedCarType = "C11"
        return session
    }

    @Test("启动那帧读不到钥匙串的进程，一次落盘盖不掉选中车")
    func emptySnapshotKeepsSelectedVehicle() async {
        cleanUp()
        defer { cleanUp() }

        // 钥匙串此刻是空的，客户端拿到的就是一份空会话——正是那个被锁屏拉起的进程的样子。
        let client = LeapClient(store: store)
        // 主 App 随后写下权威的那份（设备号 + 选中车）。
        store.save(authoritativeSession())

        // 空快照进程做了一件会落盘的小事。
        await client.rememberCarAlias("c11-2023")

        #expect(store.load()?.selectedVin == Self.vin, "手里没有选中车的进程不许整份写回")
        #expect(store.loadDeviceId() == Self.deviceId, "设备号更不能被抹")
    }

    @Test("两边都有选中车，正常落盘照写不误")
    func normalSaveStillGoesThrough() async {
        cleanUp()
        defer { cleanUp() }

        store.save(authoritativeSession())
        let client = LeapClient(store: store)

        await client.rememberCarAlias("c11-2023")

        #expect(store.load()?.selectedCarAlias == "c11-2023", "守卫不该把正常的落盘也拦下来")
        #expect(store.load()?.selectedVin == Self.vin)
    }
}
