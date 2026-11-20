import SwiftUI
import WidgetKit

/// 整张卡执行标题所示的上锁或解锁操作，右上角图标标识操作方向。
struct LockWidgetView: View {
    var snapshot: VehicleSnapshot
    /// 官方图层叠出来的那张车图。取不到（3D 资源没下完、关了「显示车模型」、
    /// 演示态）就退回剪影，和首页缺图时是同一个字形。
    var carImage: Image?
    var action: WidgetAction = .toggleLock

    private var cardAction: WidgetAction {
        action == .toggleLock ? (snapshot.lockActionTarget ? .lock : .unlock) : action
    }

    var body: some View {
        if WidgetControlRunner.canDispatchDirectly {
            Button(intent: VehicleControlIntent(action: cardAction)) { label }
                .buttonStyle(.plain)
        } else {
            Button(intent: OpenVehicleActionIntent(action: cardAction)) { label }
                .buttonStyle(.plain)
        }
    }

    private var label: some View {
        VStack(spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cardAction.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Text(snapshot.vehicleName)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                LockBadge(action: cardAction)
            }
            GeometryReader { proxy in
                artwork.frame(width: proxy.size.width, height: proxy.size.height)
            }
            statusLine
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cardAction.title)，\(snapshot.vehicleName)，\(LockWidgetStatus.text(for: snapshot))")
    }

    @ViewBuilder
    private var artwork: some View {
        if let carImage {
            // 已经在写进 App Group 时裁掉了四周透明边，这里直接铺满宽度就行。
            carImage
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "car.side.fill")
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(LockWidgetPalette.silhouette)
        }
    }

    private var statusLine: some View {
        // 门窗未关比"锁没锁"更该被看到：锁着但窗开着，车其实是敞的。
        // 有这类异常时整行让给它，前面加一个警示图标。
        let warning = LockWidgetStatus.warning(for: snapshot)
        return HStack(spacing: 3) {
            if warning != nil {
                // 颜色只交给图标，文字保持可读。
                // 试过把整行染成琥珀：卡片底本来就是一层淡琥珀，同色系的字叠上去
                // 几乎看不见——最该被看到的一行反而成了最不显眼的。
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LeapPalette.warm)
            }
            Text("\(warning ?? snapshot.lockText) · \(snapshot.freshnessText)")
                // 必须写成明确的 `Color`，不能用 `.primary` / `.secondary` 这种层级样式。
                // 整张卡在"直接控车"关着时是个 `Link`，而 `Link` 会把内容的前景色染成强调色；
                // 层级样式解析的正是这个被染过的颜色，于是琥珀色那张卡底下的小字也是绿的。
                .foregroundStyle(Color.primary.opacity(0.7))
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

/// 徽标表达操作方向，当前车况由底部文字表达。
private struct LockBadge: View {
    var action: WidgetAction

    var body: some View {
        Image(systemName: action.symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(action == .unlock ? Color.black.opacity(0.85) : Color.white)
            .frame(width: 26, height: 26)
            .background(action == .unlock ? LeapPalette.caution : LeapPalette.accent, in: .circle)
    }
}

/// 卡片上的文案。视图和无障碍标签共用一份，免得两处慢慢说岔。
enum LockWidgetStatus {
    /// 门窗类异常。没有就返回 nil——这张卡不显示和锁车无关的状态（充电、位置那些
    /// 是「车辆状态」卡的事）。
    static func warning(for snapshot: VehicleSnapshot) -> String? {
        // 刚按过一下却没成，这件事比任何车况都该先说。
        if let failure = WidgetControlFeedback.recentFailure { return failure }
        if snapshot.anyDoorOpen { return "有车门未关闭" }
        if snapshot.trunkOpen == true { return "尾门未关闭" }
        if snapshot.windowsClosed == false { return "车窗未关闭" }
        return nil
    }

    /// 完整状态描述，给无障碍朗读用。
    static func text(for snapshot: VehicleSnapshot) -> String {
        [snapshot.lockText, warning(for: snapshot)]
            .compactMap { $0 }
            .joined(separator: "，")
    }
}

/// 这张卡的配色。卡片扩展在配置里画背景、App 内画廊也要画同一份，所以单独拎出来。
enum LockWidgetPalette {
    static func badge(locked: Bool?) -> Color {
        switch locked {
        case true: LeapPalette.accent
        case false: LeapPalette.caution
        // 读不到就用中性灰。绿色和琥珀在这张卡上都是断言，灰色才是"我不知道"。
        case nil: Color.gray
        }
    }

    /// 没有车图时那辆剪影。比首页那只淡一档——这张卡上它是配角，主角是右上角的徽标。
    static let silhouette = Color.primary.opacity(0.28)

    static func tint(locked: Bool?) -> Color {
        switch locked {
        case true: LeapPalette.accent
        case false: LeapPalette.caution
        case nil: Color.gray
        }
    }
}

/// 随状态变色的卡片底。
///
/// 刻意压得很淡：状态该由右上角的徽标说，底色只是让人余光扫过桌面时能感觉到不对劲。
/// 铺一层饱和色块会把车图整个染掉，那就本末倒置了。
struct LockWidgetBackground: View {
    var snapshot: VehicleSnapshot

    var body: some View {
        let tint = LockWidgetPalette.tint(locked: snapshot.isLocked)
        LinearGradient(
            colors: [tint.opacity(0.18), tint.opacity(0.05)],
            startPoint: .top,
            endPoint: .bottom
        )
        // 渐变本身是半透明的，底下垫一层系统材质，深浅色下都不会露出壁纸。
        .background(.fill.tertiary)
    }
}

/// App 内画廊用的包装：把卡片底和内容按真实层次叠好，核对的才是桌面上那一张。
struct LockWidgetPreview: View {
    var snapshot: VehicleSnapshot
    var carImage: Image?
    var action: WidgetAction = .toggleLock

    var body: some View {
        LockWidgetView(snapshot: snapshot, carImage: carImage, action: action)
            .background { LockWidgetBackground(snapshot: snapshot) }
            // 桌面上这一步由系统做，画廊里得自己来，否则背景会溢出圆角。
            .clipShape(.rect(cornerRadius: 24))
    }
}
