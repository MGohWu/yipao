import Foundation
import Testing
@testable import LeapControl

/// 里程能耗页的按周下钻。
///
/// 存在的理由是这条链上有两个静默错法：周区间算错一天，`getLastweekEC` 会安静地回一份
/// 少一天（或多一天）的构成，界面照样画得出来；把「最后一周」认错，默认选中的柱子和
/// 环形图就对不上号，同样不报错。两个都只能靠数字盯出来。
@Suite("里程能耗按周下钻")
struct DrivingStatsTests {

    /// 周区间按**北京时间**闭区间算，与设备时区无关。
    /// 2026-07-06 00:00:00 +08:00 = 1783267200000；周末尾补到 23:59:59.999。
    @Test("周区间按北京时间取整周")
    func weekRangeUsesBeijingBoundaries() throws {
        let range = try #require(DrivingStatsRange(weekStart: "2026-07-06", weekEnd: "2026-07-12"))
        #expect(range.begintime == 1783267200000)
        #expect(range.endtime == 1783871999999)
        // 闭区间正好七天。
        #expect(range.endtime - range.begintime + 1 == 7 * 86_400_000)
    }

    /// 日期串缺失或畸形时不能瞎猜一个区间——上层据此让那根柱子点不动。
    @Test("日期串缺失或畸形不给区间")
    func malformedWeekYieldsNoRange() {
        #expect(DrivingStatsRange(weekStart: nil, weekEnd: "2026-07-12") == nil)
        #expect(DrivingStatsRange(weekStart: "2026-07-06", weekEnd: nil) == nil)
        #expect(DrivingStatsRange(weekStart: "2026/07/06", weekEnd: "2026-07-12") == nil)
        #expect(DrivingStatsRange(weekStart: "", weekEnd: "") == nil)
    }

    /// `WeeklyEC.id` 同时是选中标识和按周缓存的键，两根柱子不能撞。
    @Test("周标识按起止日区分")
    func weekIDsAreDistinct() {
        let first = DrivingStats.WeeklyEC(weekStart: "2026-07-06", weekEnd: "2026-07-12", hundredKmEc: 16.4)
        let second = DrivingStats.WeeklyEC(weekStart: "2026-07-13", weekEnd: "2026-07-19", hundredKmEc: 15.5)
        #expect(first.id != second.id)
        #expect(first.id == "2026-07-06~2026-07-12")
    }

    /// 构成三块是**字符串**下发的，且占比要跟着一起算出来。
    @Test("能耗构成按三块算占比")
    func distributionComputesPercentages() throws {
        let raw = JSONValue.object([
            "data": .object(["driverEC": .string("22.5"), "acEC": .string("3.7"), "otherEC": .string("2.2")])
        ])
        let distribution = try #require(DrivingStats.EnergyDistribution(raw: raw))
        #expect(distribution.totalKwh == 28.4)
        #expect(distribution.driverPct == 79.2)
        #expect(distribution.acPct == 13.0)
        #expect(distribution.otherPct == 7.7)
    }

    /// 这段区间没数据时整块为 nil——界面据此隐藏整张卡，不能填 0 顶上。
    @Test("没有 data 节点就没有构成")
    func distributionMissingDataIsNil() {
        #expect(DrivingStats.EnergyDistribution(raw: JSONValue.object([:])) == nil)
        #expect(DrivingStats.EnergyDistribution(raw: nil) == nil)
    }

    /// 演示模式下六根柱子点下去必须真的换数——否则看着像点坏了。
    /// 同一周反复点开又得是同一组数。
    @Test("演示构成跟着周变且同周稳定")
    func demoDistributionVariesByWeek() throws {
        let first = try #require(DrivingStatsRange(weekStart: "2026-07-06", weekEnd: "2026-07-12"))
        let second = try #require(DrivingStatsRange(weekStart: "2026-07-13", weekEnd: "2026-07-19"))
        let a = ReviewDemo.energyDistribution(for: first)
        let b = ReviewDemo.energyDistribution(for: second)
        #expect(a.driverKwh != b.driverKwh)
        #expect(ReviewDemo.energyDistribution(for: first).driverKwh == a.driverKwh)
    }

    /// 演示数据的构成必须挂在最后一周上：页面默认选中那根柱子，
    /// 挂错了环形图和高亮的柱子就是两码事。
    @Test("演示数据默认挂在本周")
    func demoDistributionBelongsToLastWeek() throws {
        let stats = ReviewDemo.drivingStats
        let lastWeek = try #require(stats.weekly?.weeks.last)
        #expect(stats.distributionWeekID == lastWeek.id)
        let expected = try #require(lastWeek.range.map(ReviewDemo.energyDistribution(for:)))
        #expect(stats.energyDistribution?.driverKwh == expected.driverKwh)
    }

    /// `getLastweekEC` 收秒级时间戳，传毫秒服务端回 `code:2 请求参数含非法字符`——
    /// 错误文案指向字符集，实际是量纲错了，2026-08-18 真机逐参数试探才定位到。
    /// 这条测试守的就是「别再传毫秒」，顺带钉死右端不能被 /1000 抹掉最后一秒。
    @Test("能耗构成的时间戳是秒级")
    func energyDistributionUsesSeconds() throws {
        let range = try #require(DrivingStatsRange(weekStart: "2026-08-10", weekEnd: "2026-08-16"))
        #expect(range.begintimeSeconds == 1_786_291_200)
        // 毫秒右端是 ...999，整除后仍落在 8-16 当天 23:59:59，不能跨到次日零点。
        #expect(range.endtimeSeconds == 1_786_895_999)
        #expect(range.endtimeSeconds - range.begintimeSeconds == 7 * 86_400 - 1)
        // 秒级值必须比毫秒值短三位——传错量纲一眼看得出来。
        #expect(String(range.begintimeSeconds).count == String(range.begintime).count - 3)
    }
}
