import Testing
@testable import LeapControl

/// 首页控车条拆出「上锁」「解锁」两格之后，旧排序怎么还原。
@Suite("控车条排序")
struct QuickControlOrderTests {

    @Test("没存过排序时，上锁、解锁排在最前")
    func defaultOrder() {
        #expect(Array(QuickControl.order(from: []).prefix(4)) == [.lock, .unlock, .trunk, .climate])
    }

    @Test("拆分前存的排序：解锁紧跟在原来车锁的位置后面，不是追加到末尾")
    func legacyOrderKeepsLockPairTogether() {
        let order = QuickControl.order(from: ["trunk", "climate", "lock", "horn"])
        #expect(Array(order.prefix(5)) == [.trunk, .climate, .lock, .unlock, .horn])
        #expect(order.count == QuickControl.allCases.count)
    }

    @Test("拆分后存的排序原样还原，用户把两格分开放也不会被拉回一起")
    func newOrderRespected() {
        let saved = ["unlock", "horn", "lock", "trunk", "climate", "sentinel", "sunshade", "sunroof", "frunk"]
        #expect(QuickControl.order(from: saved).map(\.rawValue) == saved)
    }
}
