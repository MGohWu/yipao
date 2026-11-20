import ActivityKit
import Foundation
import SwiftUI

/// 一次控车从按下到出结果，在灵动岛上走完的那一条。
///
/// 存在的理由只有一个：**扩展进程里按下按钮之后，屏幕上什么都不会发生。**
/// 卡片弹不了 toast，控件也拉不起 App（原因写在 `LockControlIntent` 上），
/// 而锁车这种动作本身没有声音——按下去和没按下去长得一模一样，用户只能等几秒
/// 看卡片自己刷新来间接确认。灵动岛是扩展进程唯一能当场说话的地方。
///
/// 这条只服务于"直接控车"那条路。
struct ControlActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var action: ControlActivityAction
        var phase: ControlActivityPhase
        /// 失败原因。只有 `.failed` 有，其余一律 nil。
        var detail: String?
    }

    /// 起这条时车叫什么。全程不变，所以放在静态属性里而不是 ContentState。
    var vehicleName: String

    /// 按下的那一刻。进度条靠它画。
    ///
    /// 灵动岛里**不能用不确定进度**（`ProgressView()`）：WidgetKit 不跑它的动画，
    /// 只画一个不会动的静止圆环，尺寸还由它自己说了算，能把同一格里的其它内容挤出去。
    /// 会动的只有"按时间推进"那一类（`ProgressView(timerInterval:)`），
    /// 而它要一个起止时刻——起点就是这里，终点是 `expectedFinish`。
    var startedAt: Date

    /// 一次控车大概要多久：发指令等服务端，成功后还固定睡 3 秒再回读车况，正常 5～8 秒。
    /// 这是个**估计**，不是承诺——真的先跑完了，进度条会被结果那一帧直接替掉；
    /// 跑过头了，它停在满格，由 `staleDate` 那条路去说"结果未知"。
    var expectedFinish: Date { startedAt.addingTimeInterval(9) }
}

/// 灵动岛上说的是哪个动作。
///
/// 不直接复用 `WidgetAction`：那个枚举里 `toggleLock`、`toggleClimate` 是"切换"，
/// 而灵动岛上要说的是**这一次到底在做什么**——「正在锁车」和「正在解锁」是两句话，
/// 一个 toggle 说不清。目标态在按下的那一刻就定了，这里存的就是那个结果。
enum ControlActivityAction: String, Codable, Hashable, Sendable {
    case lock
    case unlock
    case trunk
    case horn
    case climateOn
    case climateOff

    /// 和 `VehicleSnapshot.lockSymbol` 同一家族，同一件事在两处不该长成两个样子。
    var symbol: String {
        switch self {
        case .lock: "car.side.lock.fill"
        case .unlock: "car.side.lock.open.fill"
        case .trunk: "car.side.rear.open"
        case .horn: "speaker.wave.2.fill"
        case .climateOn: "fan.fill"
        case .climateOff: "fan"
        }
    }

    var runningText: String {
        switch self {
        case .lock: "正在锁车"
        case .unlock: "正在解锁"
        case .trunk: "正在打开尾门"
        case .horn: "正在鸣笛"
        case .climateOn: "正在开启空调"
        case .climateOff: "正在关闭空调"
        }
    }

    /// 下发之后**回读到车况、且车况和目标一致**才能说这句。
    var confirmedText: String {
        switch self {
        case .lock: "已锁车"
        case .unlock: "已解锁"
        case .trunk: "尾门已打开"
        case .horn: "已鸣笛"
        case .climateOn: "空调已开启"
        case .climateOff: "空调已关闭"
        }
    }

    /// 车端收下了指令，但这一侧没能回读到车况。
    ///
    /// 这一档不是凑数：控车指令是异步执行的，回读那一下拿不到（网络抖、车在休眠）
    /// 是常事。这时候说「已锁车」就是替车端断言一件我们并不知道的事——
    /// 而这条消息出现的场景恰恰是用户已经走远、只能靠它判断要不要折回去。
    var sentText: String {
        switch self {
        case .lock: "锁车指令已发出"
        case .unlock: "解锁指令已发出"
        case .trunk: "尾门指令已发出"
        case .horn: "鸣笛指令已发出"
        case .climateOn, .climateOff: "空调指令已发出"
        }
    }

    var failureText: String {
        switch self {
        case .lock: "锁车失败"
        case .unlock: "解锁失败"
        case .trunk: "尾门操作失败"
        case .horn: "鸣笛失败"
        case .climateOn, .climateOff: "空调操作失败"
        }
    }

    /// 完成态的主色。跟着 `LockWidgetPalette.tint` 那份判据：绿=锁好了，琥珀=车开着。
    /// 解锁成功用琥珀不用绿，是因为"车现在是开的"这件事本身就该被看见。
    var doneTint: Color {
        switch self {
        case .lock, .climateOff: LeapPalette.accent
        case .unlock, .trunk: LeapPalette.caution
        case .horn, .climateOn: LeapPalette.cool
        }
    }
}

enum ControlActivityPhase: String, Codable, Hashable, Sendable {
    case running
    /// 回读到车况，且和目标一致。
    case confirmed
    /// 指令送到了，但没回读到车况。
    case sent
    case failed

    var symbol: String {
        switch self {
        case .running: "circle.dashed"
        case .confirmed: "checkmark.circle.fill"
        case .sent: "paperplane.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }
}

extension ControlActivityAttributes.ContentState {
    /// 灵动岛和锁屏上那句大字。
    var title: String {
        switch phase {
        case .running: action.runningText
        case .confirmed: action.confirmedText
        case .sent: action.sentText
        case .failed: action.failureText
        }
    }

    /// 大字下面那行小字。没有可说的就返回 nil，不摆一行占位。
    var subtitle: String? {
        switch phase {
        case .running: nil
        case .confirmed: nil
        case .sent: "未回读到车况"
        case .failed: detail
        }
    }

    var tint: Color {
        switch phase {
        case .running: LeapPalette.cool
        case .confirmed: action.doneTint
        case .sent: LeapPalette.cool
        case .failed: LeapPalette.warm
        }
    }
}

// MARK: - 起止

/// 一条正在走的灵动岛控车动画。
///
/// **这里存的是活动的 id，不是 `Activity` 本身。** `Activity` 是个非 Sendable 的类，
/// 而 `end`/`update` 都是 async 的——把它存成属性再在 async 方法里用，Swift 6 会判
/// "sending 'self.activity' risks causing data races"，编不过。存 id、收尾时按 id 找回来，
/// 拿到的是一个全新的局部值，没有这个问题；顺带还处理了"这条已经被别处收掉了"。
struct ControlActivitySession {
    private let id: String

    /// 进行中那一档挂多久还没结果就算"不知道了"。
    ///
    /// 下发本身要等服务端，成功后还固定睡 3 秒再回读，正常一次 5～8 秒。留 30 秒是给
    /// 慢网络的余量。超过之后视图会自己改口说"结果未知"（见 `context.isStale`）——
    /// 扩展进程随时可能被系统收走，收走时这条会永远停在"正在锁车…"上转圈，
    /// 那比不显示更糟：它在暗示事情还在进行。
    private static let staleAfter: TimeInterval = 30

    /// 出结果之后在灵动岛上再留多久。
    private static let lingerAfter: TimeInterval = 6

    /// 起一条。用户在系统设置里关掉了实时活动，就一条也不起。
    ///
    /// **每次都先把旧的立刻收掉。** 连按两下锁车会留下两条活动，系统把它们摞在
    /// 灵动岛里轮播，而它们说的是同一件事的两个版本——后按的那次结果还可能先出来。
    static func begin(_ action: ControlActivityAction, vehicleName: String) async -> ControlActivitySession? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }

        for stale in Activity<ControlActivityAttributes>.activities {
            await stale.end(nil, dismissalPolicy: .immediate)
        }

        let content = ActivityContent(
            state: ControlActivityAttributes.ContentState(action: action, phase: .running, detail: nil),
            staleDate: .now.addingTimeInterval(staleAfter)
        )
        guard let activity = try? Activity.request(
            attributes: ControlActivityAttributes(vehicleName: vehicleName, startedAt: .now),
            content: content
        ) else {
            // 起不来就是起不来（超出系统同时活动数上限、用户刚好关掉）。
            // 控车本身不该因为一条动画失败，所以这里只是返回 nil，不抛。
            return nil
        }
        return ControlActivitySession(id: activity.id)
    }

    /// 共享车图更新后，让正在展示的灵动岛重新渲染一次。
    ///
    /// 车图不放进 `ContentState`：裁过的 PNG 仍远超 ActivityKit 的推送载荷限制，
    /// 扩展只能从 App Group 读取。文件内容变化不会自动触发 Live Activity 重绘，
    /// 所以沿用当前状态发一次 update，让 `ActivityFace` 重新读取 `car-widget.png`。
    static func refreshArtwork() async {
        for activity in Activity<ControlActivityAttributes>.activities {
            await activity.update(activity.content)
        }
    }

    /// 收尾：把结果写上去，停留几秒再让系统收走。
    ///
    /// 用 `.after` 而不是自己 sleep 完再 `.immediate`：收起这一下由系统排期，
    /// 就算扩展进程在 `perform()` 返回后立刻被收走，这条也会照常消失。
    func finish(_ phase: ControlActivityPhase, action: ControlActivityAction, detail: String?) async {
        guard let activity = Activity<ControlActivityAttributes>.activities.first(where: { $0.id == id })
        else { return }
        let content = ActivityContent(
            state: ControlActivityAttributes.ContentState(action: action, phase: phase, detail: detail),
            staleDate: nil
        )
        await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(Self.lingerAfter)))
    }
}
