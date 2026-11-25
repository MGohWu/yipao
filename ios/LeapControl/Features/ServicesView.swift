import SwiftUI

/// 服务页里能进去的几件事。
///
/// 单独定义成枚举而不是直接写 `NavigationLink { }`：`.navigationDestination(for:)` 要求
/// 目标值可哈希，用枚举还能顺带支持深链（`MainTabView` 里认 `services` / `trip` / `charge`）。
enum ServiceRoute: Hashable {
    /// 逐趟行程（App 自己切段）。
    case trips
    /// 逐次充电（App 自己切段）。
    case charges
    /// 零跑官方的里程能耗，按天/按周聚合。和上面两项是两套口径，卡片上标明来源。
    case mileage
}

/// 底部第四个 Tab：放「跟车有关的历史记录」。
///
/// 为什么不塞进「功能」页：功能页是**现在能对车做的操作**（开空调、开窗、找车），
/// 而这里放的是**过去发生过什么**。两者的使用节奏完全不同——操作是一进去就按，
/// 记录是偶尔翻出来对账，混在一起会让功能页越来越长，而记录永远排在最后。
struct ServicesView: View {
    @Environment(VehicleStore.self) private var store
    @StateObject private var trips = TripRecorder.shared
    @StateObject private var charges = ChargeRecorder.shared

    var body: some View {
        ZStack {
            LeapBackground(tint: LeapStyle.accent)
            ScrollView {
                VStack(spacing: 14) {
                    GlassCard(radius: LeapStyle.tileRadius) {
                        VStack(spacing: 0) {
                            row(
                                icon: "road.lanes",
                                tint: LeapStyle.accent,
                                title: "行程记录",
                                subtitle: tripSummary,
                                route: .trips
                            )
                            Rectangle().fill(.quaternary).frame(height: 1).padding(.vertical, 12)
                            row(
                                icon: "bolt.car.fill",
                                tint: LeapStyle.warm,
                                title: "充电记录",
                                subtitle: chargeSummary,
                                route: .charges
                            )
                        }
                    }

                    GlassCard(radius: LeapStyle.tileRadius) {
                        row(
                            icon: "chart.bar.xaxis",
                            tint: LeapStyle.cool,
                            title: "里程能耗",
                            subtitle: "零跑官方按天统计",
                            route: .mileage
                        )
                    }

                    explainer
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("服务")
    }

    // MARK: - 行

    private func row(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        route: ServiceRoute
    ) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: .rect(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("关于这些记录")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("行程和充电都是 App 在运行时看着车况自己记的，存在这台手机上，不上传任何服务器。所以 App 没在跑的那段，只会在下次打开时按里程表、电量差补一条「补记」。\n零跑官方的「里程能耗」是另一套口径（按天结算），两边数字不会完全一致。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    // MARK: - 摘要

    /// 近 7 天，和列表页的汇总口径一致。多车账号只算当前这台车。
    private var tripSummary: String {
        let all = store.isDemo ? ReviewDemo.tripLog : trips.trips
        let recent = filterRecent(all.filter { matchesCurrentVehicle($0.vin) }) { $0.startAt }
        guard !recent.isEmpty else { return "还没有记录" }
        let km = recent.reduce(0) { $0 + $1.distanceKm }
        return "近 7 天 \(recent.count) 趟 · \(trimmed(km)) km"
    }

    private var chargeSummary: String {
        let all = store.isDemo ? ReviewDemo.chargeLog : charges.charges
        let recent = filterRecent(all.filter { matchesCurrentVehicle($0.vin) }) { $0.startAt }
        guard !recent.isEmpty else { return "还没有记录" }
        let energy = recent.compactMap(\.energyKwh).reduce(0, +)
        guard energy > 0 else { return "近 7 天 \(recent.count) 次" }
        return "近 7 天 \(recent.count) 次 · \(trimmed(energy)) kWh"
    }

    private func matchesCurrentVehicle(_ vin: String?) -> Bool {
        let current = store.session.selectedVin
        // 老记录没有 vin，一并算进来。
        return vin == nil || vin == current
    }

    private func filterRecent<T>(_ items: [T], by date: (T) -> Date) -> [T] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { return items }
        return items.filter { date($0) >= start }
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
