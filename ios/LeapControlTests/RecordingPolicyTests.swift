import Foundation
import Testing

@testable import LeapControl

/// 后台记录的轮询节奏。
///
/// 这几个数字看着像随手写的，其实每一个都对应一个具体后果：
///
/// - 前台放慢 → 界面上那行车况、以及控车后的回执都跟不上；
/// - 后台不放大 → 一天八九千次云端读请求，拿电池和服务端换一堆没人看的数字；
/// - 后台记录关着还继续轮询 → 用户以为关掉了，其实一直在耗电，这是最坏的一种。
///
/// 所以把「什么时候该停」也当成逻辑来测，而不是留在 `VehicleStore` 里当 if 分支。
@Suite("后台轮询节奏")
struct RecordingPolicyTests {

    @Test("前台固定 10 秒，跟后台记录开关无关")
    func foregroundIgnoresBackgroundSwitch() {
        for keeps in [true, false] {
            #expect(
                RecordingPolicy.pollInterval(isForeground: true, keepsRecordingInBackground: keeps)
                    == RecordingPolicy.foregroundInterval
            )
        }
    }

    @Test("后台记录开着：降到 60 秒继续跑")
    func backgroundKeepsPolling() {
        let interval = RecordingPolicy.pollInterval(
            isForeground: false,
            keepsRecordingInBackground: true
        )
        #expect(interval == .seconds(60))
    }

    @Test("后台记录关着：干脆不轮询")
    func backgroundStopsWhenSwitchOff() {
        #expect(
            RecordingPolicy.pollInterval(isForeground: false, keepsRecordingInBackground: false) == nil
        )
    }

    @Test("后台必须明显比前台慢，否则这个开关只剩下耗电")
    func backgroundIsMuchSlower() {
        // 60 秒 vs 10 秒。定这条是为了拦住「后台也 10 秒」这种改动——
        // 那样一天就是 8600 次请求，而记录精度只提高几秒，完全不值。
        #expect(RecordingPolicy.backgroundInterval >= .seconds(30))
        #expect(RecordingPolicy.backgroundInterval > RecordingPolicy.foregroundInterval)
    }

    @Test("前台不能比 10 秒更快，零跑云端接口扛不住也无必要")
    func foregroundNotTooFast() {
        #expect(RecordingPolicy.foregroundInterval >= .seconds(5))
    }
}
