import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// 控车过程那条灵动岛 / 锁屏横幅。
///
/// 这条不显示车况，只讲刚按下的那一次控车走到哪一步了。车况有卡片和控件负责，
/// 而它们都是"过一会儿才刷新"的东西——按下去那几秒里，屏幕上原本一片死寂。
///
/// 三种呈现共用同一份判据（`ActivityFace`）：紧凑态只剩两个字形的位置，
/// 展开态和锁屏能多说一行。分头写的话，同一次锁车在收起和展开时会说两种话。
struct ControlActivityWidget: Widget {
    /// 灵动岛展开态左边那一列车图的宽度。
    private static let carWidth: CGFloat = 104
    /// 两列之间的空隙。
    private static let columnGap: CGFloat = 12

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ControlActivityAttributes.self) { context in
            LockScreenView(face: ActivityFace(context))
                // 背景交给系统：深浅两套锁屏它自己会给合适的半透明材质。
                // 以前固定压一层 45% 黑，浅色锁屏上像贴了块炭，白字也没了层次。
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground).opacity(0.55))
                .activitySystemActionForegroundColor(Color(uiColor: .label))
        } dynamicIsland: { context in
            let face = ActivityFace(context)
            return DynamicIsland {
                // 左上角空着。
                //
                // 车图挪进了下面那一格，和文字排成同一行——**展开态的三个格子里，
                // 只有 `.bottom` 在摄像头下面**，`.leading` / `.trailing` 被钉在摄像头
                // 两侧那条带子上。也就是说没有任何一个格子能同时占住上下两排，
                // 想让车在整条岛里垂直居中，它就只能和文字待在同一格里。
                //
                // 代价是这一格空了。三块内容（车、文字、车况）填不满四个位置，
                // 总要空一个；空这儿是最不刺眼的——它正好在车的正上方，
                // 读起来像车顶上的留白，而不是一个洞。
                DynamicIslandExpandedRegion(.leading) {
                    EmptyView()
                }
                // 右上角放电量和续航。
                //
                // 这里先后试过转圈的环和车名，都不合适：环和下面那条进度横条绑的是
                // 同一个计时，同一件事画两遍；车名又太短，撑不住这一格。
                //
                // **两行短字，右对齐，留 10pt 边距**——这一格右边就是岛的圆角，
                // 之前那个「S01」贴到 2pt 就被圆角齐着切掉了半个字。宁可窄一点。
                //
                // 读不到车况、或车况已经陈旧（超过半小时）时整格不画：一条四十分钟前的
                // 电量挂在这儿，比空着更容易让人据此做决定。
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        if let socText = face.socText {
                            Text(socText)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        if let rangeText = face.rangeText {
                            Text(rangeText)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .lineLimit(1)
                    .padding(.trailing, 10)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // `.center` 让车和文字块互相居中。车比文字块高，所以是文字
                    // 贴着车的中线走——车在这一整格里就是垂直居中的。
                    HStack(alignment: .center, spacing: Self.columnGap) {
                        // 宽度写死，不让 `scaledToFit` 自己算：这一列的宽度一浮动，
                        // 文字列的左边界就会跟着晃。
                        CarThumb(face: face, width: Self.carWidth, height: 56)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                // 进行中不画字形：进度已经由下面那条横条说了。
                                // 出了结果才画 ✓ / ✗，而且贴着文案——挂在角上孤零零一个，
                                // 得让人自己把它和文字连起来读。
                                if !face.isRunning {
                                    Image(systemName: face.phaseSymbol)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(face.tint)
                                        .contentTransition(.symbolEffect(.replace))
                                }
                                Text(face.title)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            if face.window != nil {
                                ProgressBar(face: face)
                            } else if let subtitle = face.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.trailing, 8)
                }
            } compactLeading: {
                ActionGlyph(face: face)
            } compactTrailing: {
                PhaseGlyph(face: face, size: 16)
            } minimal: {
                // 只剩一个字形的位置时留哪个：留进度。
                // 动作是用户几秒前自己按的，他记得；不知道的是"成了没有"。
                PhaseGlyph(face: face, size: 16)
            }
            .keylineTint(face.tint)
        }
    }
}

// MARK: - 三种呈现共用的那份判据

/// 这一刻该画成什么样。
///
/// 单独拎出来是因为它要吃掉两个不写在 `ContentState` 里的东西：`context.isStale`，
/// 和 App Group 里那张车图。
///
/// `isStale`：扩展进程随时可能被系统收走，收走时这条会永远停在"正在锁车"上，
/// 那比什么都不显示更糟，它在暗示事情还在进行。超过保鲜期就改口说"结果未知"。
private struct ActivityFace {
    var title: String
    var subtitle: String?
    var vehicleName: String
    var actionSymbol: String
    var phaseSymbol: String
    var tint: Color
    var isRunning: Bool
    /// 进度条画哪一段。只有进行中才有。
    var window: ClosedRange<Date>?
    /// 官方图层叠出来的那张车图，主 App 每次叠完写进 App Group。
    /// 取不到（3D 资源没下完、关了「显示车模型」、演示态）就退回剪影，
    /// 和首页、锁车卡缺图时是同一个字形。
    var carImage: Image?
    /// 顺手带的电量和续航。**读不到、或快照已经陈旧时一律是 nil**，
    /// 由视图整块不画——这一条本来只讲控车，捎带的车况要是过期的，
    /// 比空着更容易让人据此做决定（和卡片上「读不到就整行隐藏」是同一条规矩）。
    var socText: String?
    var rangeText: String?

    init(_ context: ActivityViewContext<ControlActivityAttributes>) {
        let state = context.state
        vehicleName = context.attributes.vehicleName
        actionSymbol = state.action.symbol

        let stalled = state.phase == .running && context.isStale
        isRunning = state.phase == .running && !stalled
        title = stalled ? "结果未知" : state.title
        subtitle = stalled ? "打开 App 看当前车况" : state.subtitle
        phaseSymbol = stalled ? "questionmark.circle.fill" : state.phase.symbol
        tint = stalled ? LeapPalette.warm : state.tint

        let started = context.attributes.startedAt
        let finish = context.attributes.expectedFinish
        window = isRunning && started < finish ? started...finish : nil

        carImage = CarImageCache.shared().map { Image(uiImage: $0) }

        if let snapshot = SnapshotStore().read(), !snapshot.isStale {
            socText = snapshot.soc.map { "\($0)%" }
            rangeText = snapshot.rangeKm.map { "\($0) km" }
        }
    }
}

/// 那条在走的进度横条。
///
/// **按时间推进**（`ProgressView(timerInterval:)`），不是不确定进度——后者在
/// WidgetKit 里根本不动。它也不假装知道真实进度：画的是"一次控车通常要这么久"，
/// 跑完之前结果先回来了就被那一帧直接替掉。比起一个静止的圈，
/// 一条肉眼可见在走的横条至少回答了"它还在动没有"。
private struct ProgressBar: View {
    var face: ActivityFace

    var body: some View {
        if let window = face.window {
            ProgressView(timerInterval: window, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(face.tint)
        }
    }
}

/// 锁屏那条大字下面那一行：进行中画进度条，出了结果画补充说明。
///
/// 只给锁屏用。灵动岛那边的同一行是分开写的——两套呈现的布局本来就互相独立，
/// 强行共用一个 `Detail` 的话，将来只想动一边就得先把它拆开。
private struct LockScreenDetail: View {
    var face: ActivityFace

    var body: some View {
        if face.window != nil {
            ProgressBar(face: face)
        } else {
            // 锁屏这条上没有单独放车名的地方，所以没别的话说时由它顶上。
            Text(face.subtitle ?? face.vehicleName)
                .font(.caption)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .lineLimit(1)
        }
    }
}

/// 车模图。紧凑态放不下它，只在展开态和锁屏上出现。
private struct CarThumb: View {
    var face: ActivityFace
    var width: CGFloat
    var height: CGFloat
    /// 没有车图时的剪影颜色。灵动岛里永远是黑底，用白；锁屏跟着系统明暗走。
    var glyphColor: Color = .white

    var body: some View {
        Group {
            if let carImage = face.carImage {
                // 写进 App Group 时已经裁掉了四周的透明边，这里按框缩就行。
                carImage
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "car.side.fill")
                    .font(.system(size: height * 0.7, weight: .thin))
                    .foregroundStyle(glyphColor.opacity(0.55))
            }
        }
        // 宽高都框死。只给高度的话宽度由车图自己的比例说了算，
        // 而灵动岛那边文字列的左内边距是照着这个宽度对齐的——一浮动就对不齐。
        .frame(width: width, height: height)
    }
}

/// 紧凑态左边那个"在做什么"。进行中让它轻微搏动——
/// 收起来只剩两个字形的位置，这是唯一放得下的动效。
private struct ActionGlyph: View {
    var face: ActivityFace

    var body: some View {
        Image(systemName: face.actionSymbol)
            .foregroundStyle(face.tint)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, isActive: face.isRunning)
    }
}

/// "到哪一步了"。
///
/// **尺寸必须写死。** 这里原先用 `ProgressView()` 表示进行中，它在灵动岛里
/// 会自己撑到六十多点高，把展开态的下半格挤出岛外——底下那行车名被岛的下边缘
/// 齐腰裁断，就是这么来的。现在进行中画的是一个跟着时间转的小环，尺寸自己定。
private struct PhaseGlyph: View {
    var face: ActivityFace
    var size: CGFloat

    var body: some View {
        Group {
            if let window = face.window {
                ProgressView(timerInterval: window, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
                .tint(face.tint)
            } else {
                Image(systemName: face.phaseSymbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(face.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: size + 4, height: size + 4)
    }
}

/// 锁屏 / 横幅那一条。没有灵动岛的机型、或屏幕锁着时走这里，
/// 所以它得自己说全：哪台车、在做什么、到哪一步。
private struct LockScreenView: View {
    var face: ActivityFace

    var body: some View {
        HStack(spacing: 14) {
            CarThumb(
                face: face,
                width: 76,
                height: 40,
                glyphColor: Color(uiColor: .secondaryLabel)
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(face.title)
                    .font(.headline)
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                LockScreenDetail(face: face)
            }

            Spacer(minLength: 0)

            PhaseGlyph(face: face, size: 24)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
