import Foundation

/// 后台记录的节奏。
///
/// 车端没有推送，行程和充电全靠轮询切段（见 `TripTracker` / `ChargeTracker`）。
/// 前台 10 秒一帧是为了让界面跟得上，那点间隔对电量影响可以忽略。
///
/// 进后台以后间隔必须放大——一直 10 秒一次，一天就是 8600 次云端请求，纯属拿电池
/// 换一堆没人看的数字。但也不能放到几分钟：两个状态机都是「连续 3 帧停稳/断流才
/// 收尾」，帧越稀，收尾判得越迟。60 秒一帧时一次收尾约 2~3 分钟，还在可用范围；
/// 再往上放就该改判定逻辑了（改成按时间而不是按帧数），不是调个常量的事。
enum RecordingPolicy {

    /// 前台。界面上那行「刚刚更新」要跟得上。
    static let foregroundInterval: Duration = .seconds(10)

    /// 后台。60 秒一次读请求，一天约 1440 次，对电量和零跑服务端都还算客气。
    static let backgroundInterval: Duration = .seconds(60)

    /// 这一轮该等多久；返回 `nil` 表示根本不该轮询。
    ///
    /// - Parameters:
    ///   - isForeground: App 是否在前台。
    ///   - keepsRecordingInBackground: 用户开了「后台记录」，且保活确实在跑。
    ///     光开开关不算——没有「始终允许」的定位权限，进后台活不过几秒，
    ///     这时候继续轮询只是在骗自己。
    static func pollInterval(
        isForeground: Bool,
        keepsRecordingInBackground: Bool
    ) -> Duration? {
        if isForeground { return foregroundInterval }
        return keepsRecordingInBackground ? backgroundInterval : nil
    }
}
