import SwiftUI

/// 记录类页面的公共零件（行程、充电，以及将来的保养）。
///
/// 这两页原来各写一套汇总卡、标签和分隔线，改一次要改两遍，而且两边的字号、
/// 间距很快就对不齐了。抽出来的东西只有一个目标：**先看到这一段时间的总量，
/// 再往下翻逐条**——和车主翻这两页时真正想做的事一致。

// MARK: - 时间范围

enum RecordsRange: String, CaseIterable, Identifiable {
    case week, month, all

    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: return "近 7 天"
        case .month: return "近 30 天"
        case .all: return "全部"
        }
    }

    /// 图表画几根柱子。`全部` 也只画最近 30 天——再多柱子就成了噪声。
    var chartDays: Int { self == .week ? 7 : 30 }

    /// 过滤起点。`全部` 返回 nil。
    func start(now: Date = .now) -> Date? {
        guard let days = self == .all ? nil : (self == .week ? 7 : 30) else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today)
    }

    func contains(_ date: Date, now: Date = .now) -> Bool {
        guard let start = start(now: now) else { return true }
        return date >= start
    }
}

/// 胶囊分段控件。用 `matchedGeometryEffect` 让高亮块滑过去，
/// 比系统 `Picker(.segmented)` 更贴合玻璃卡片，也顺手支持了动态字号。
struct RecordsRangePicker: View {
    @Binding var selection: RecordsRange
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RecordsRange.allCases) { range in
                let selected = range == selection
                Button {
                    withAnimation(.snappy(duration: 0.24)) { selection = range }
                } label: {
                    Text(range.title)
                        .font(.footnote.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? LeapStyle.primaryLabel : LeapStyle.secondaryLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(.background.opacity(0.72))
                                    .shadow(color: .black.opacity(0.08), radius: 6, y: 1)
                                    .matchedGeometryEffect(id: "range", in: namespace)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .leapGlass(.regular, in: .capsule)
    }
}

// MARK: - 汇总

/// 图表里的一根柱子。
struct RecordsBar: Identifiable, Equatable {
    let id: Int
    let label: String?
    let value: Double
    let isCurrent: Bool

    /// 把「按天的值」铺成连续 N 天，缺的那天是 0——**不能跳过**，跳过会让柱子的间距
    /// 变成「有数据的那天才占位」，一眼看不出哪天没跑车。
    static func daily(
        _ values: [(date: Date, value: Double)],
        days: Int,
        now: Date = .now
    ) -> [RecordsBar] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEEE"  // 一 / 二 / 三

        return (0..<days).map { index in
            let offset = index - (days - 1)
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let total = values.reduce(0.0) { sum, item in
                calendar.isDate(item.date, inSameDayAs: day) ? sum + item.value : sum
            }
            return RecordsBar(
                id: index,
                label: days <= 7 ? formatter.string(from: day) : nil,
                value: total,
                isCurrent: offset == 0
            )
        }
    }
}

/// 顶部那张大卡：一句标题、一个主数字、一条按天的柱状图、三格次要指标。
struct RecordsHero: View {
    var caption: String
    var value: String
    var unit: String
    var bars: [RecordsBar]
    var footnote: String?
    var metrics: [Metric]

    struct Metric: Identifiable {
        var id: String { title }
        var title: String
        var value: String
        var unit: String = ""
    }

    private var peak: Double { max(bars.map(\.value).max() ?? 0, 0.001) }

    var body: some View {
        GlassCard(radius: LeapStyle.cardRadius) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(caption)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let footnote {
                        Text(footnote)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(unit)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, -6)

                barChart

                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)

                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                        if index > 0 {
                            Rectangle().fill(.quaternary).frame(width: 1, height: 26)
                        }
                        VStack(spacing: 3) {
                            Text(metric.title)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(metric.value)
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                if !metric.unit.isEmpty {
                                    Text(metric.unit)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var barChart: some View {
        HStack(alignment: .bottom, spacing: bars.count > 10 ? 3 : 8) {
            ForEach(bars) { bar in
                VStack(spacing: 5) {
                    Capsule()
                        .fill(
                            bar.isCurrent
                                ? AnyShapeStyle(LinearGradient(
                                    colors: [LeapStyle.accent, LeapStyle.accent.opacity(0.55)],
                                    startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(LeapStyle.accent.opacity(bar.value > 0 ? 0.28 : 0.1))
                        )
                        // 有值最矮也给 4pt，否则「跑了一公里」看起来和没跑一样。
                        .frame(height: max(4, 52 * bar.value / peak))
                    if let label = bar.label {
                        Text(label)
                            .font(.system(size: 9, weight: bar.isCurrent ? .semibold : .regular))
                            // `.tertiary` 是层次样式、不是 `Color`，和 `LeapStyle.accent` 拼在
                            // 三元里会让编译器按 `Color` 推，报「tertiary 不能用在 Color 上」。
                            .foregroundStyle(bar.isCurrent ? LeapStyle.accent : LeapStyle.secondaryLabel)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 66, alignment: .bottom)
        .animation(.snappy(duration: 0.3), value: peak)
    }
}

// MARK: - 标签与元信息

/// 小标签：官方 / 补记 / 快充 / 慢充。统一 10pt 圆角矩形，颜色只表达「可信度」和「类型」。
struct RecordsTag: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: .rect(cornerRadius: 5))
            .foregroundStyle(tint)
    }
}

/// 行下面那排小字。图标 + 值，间距统一，避免各页自己拼 HStack 导致对齐不一致。
struct RecordsMeta: View {
    var items: [(icon: String, text: String)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 3) {
                    Image(systemName: item.icon).font(.system(size: 9))
                    Text(item.text).lineLimit(1)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

// MARK: - 分组标题

struct RecordsDayHeader: View {
    var title: String
    var summary: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
            Text(summary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - 同步状态

enum RecordsSyncState {
    case hidden
    case working
    case done(String)
    case failed(String)

    var icon: String {
        switch self {
        case .hidden: return "icloud"
        case .working: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.icloud"
        case .failed: return "exclamationmark.icloud"
        }
    }

    var text: String {
        switch self {
        case .hidden: return ""
        case .working: return "正在同步零跑云端记录…"
        case .done(let text), .failed(let text): return text
        }
    }

    var tint: Color {
        if case .failed = self { return LeapStyle.caution }
        return LeapStyle.secondaryLabel
    }
}

struct RecordsSyncLine: View {
    var state: RecordsSyncState
    var action: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if case .hidden = state {
            EmptyView()
        } else {
            let content = HStack(spacing: 6) {
                Image(systemName: state.icon).font(.caption2)
                Text(state.text).font(.caption2).lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(state.tint)
            .padding(.horizontal, 6)

            if let action, case .failed = state {
                Button(action: action) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
    }
}

// MARK: - 空态

struct RecordsEmptyCard: View {
    var icon: String
    var title: String
    var message: String

    var body: some View {
        GlassCard(radius: LeapStyle.cardRadius) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(LeapStyle.accent.opacity(0.8))
                Text(title).font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }
}

// MARK: - 正在进行的卡片

/// 页顶那条「正在充电 / 行程进行中」。整页最该被看见的东西，所以给独立的一张卡，
/// 带一点呼吸动效（数值每秒变，静态卡会看着像卡住了）。
struct RecordsLiveCard: View {
    var icon: String
    var tint: Color
    var title: String
    var detail: String
    var trailing: String?

    var body: some View {
        GlassCard(radius: LeapStyle.cardRadius, tint: tint) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint.opacity(0.16)).frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                        .symbolEffect(.pulse, options: .repeating)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }
            }
        }
    }
}
