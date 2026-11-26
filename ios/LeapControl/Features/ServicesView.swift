import SwiftUI

/// 服务页里能进去的几件事。
///
/// 单独定义成枚举而不是直接写 `NavigationLink { }`：`.navigationDestination(for:)` 要求
/// 目标值可哈希，用枚举还能顺带支持深链（`MainTabView` 里认 `services` / `trip` / `charge`）。
enum ServiceRoute: Hashable {
    /// 逐趟行程。
    case trips
    /// 逐次充电。
    case charges
    /// 零跑官方的里程能耗，按天/按周聚合。和上面两项是两套口径，卡片上标明来源。
    case mileage
}

/// 底部第四个 Tab：放「跟车有关的历史记录」。Tab 上写「记录」——
/// 里面全是过去发生过的事，叫「服务」会让人以为这里能约保养。
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
                VStack(spacing: 16) {
                    overview
                    entries
                    explainer
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                // 服务页是「总览」，下拉时把两份记录一起对齐——省得进去再等一次。
                await store.syncTripLog()
                await store.syncChargeLog()
            }
        }
        .navigationTitle("记录")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await store.syncTripLog()
            await store.syncChargeLog()
        }
    }

    // MARK: - 概览

    /// 近 7 天两个数：跑了多少、充了多少。就这两件车主想先知道的事，
    /// 其他指标留给各自的详情页——总览页堆满小字就没人看了。
    private var overview: some View {
        let weekTrips = recentTrips
        let weekCharges = recentCharges
        let km = weekTrips.reduce(0) { $0 + $1.distanceKm }
        let kwh = weekCharges.compactMap(\.energyKwh).reduce(0, +)
        return GlassCard(radius: LeapStyle.cardRadius) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("近 7 天").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text("零跑云端 + 本机")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack(alignment: .top, spacing: 0) {
                    bigStat(
                        title: "行驶",
                        value: trimmed(km),
                        unit: "km",
                        detail: weekTrips.isEmpty ? "没有行程" : "\(weekTrips.count) 趟",
                        tint: LeapStyle.accent
                    )
                    Rectangle().fill(LeapStyle.hairline).frame(width: 1, height: 46)
                        .padding(.horizontal, 4)
                    bigStat(
                        title: "充电",
                        value: weekCharges.isEmpty ? "—" : String(format: "%.1f", kwh),
                        unit: "kWh",
                        detail: weekCharges.isEmpty ? "没有充电" : "\(weekCharges.count) 次",
                        tint: LeapStyle.warm
                    )
                }
            }
        }
    }

    private func bigStat(
        title: String, value: String, unit: String, detail: String, tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(tint)
                Text(unit).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 入口

    private var entries: some View {
        GlassCard(radius: LeapStyle.cardRadius) {
            VStack(spacing: 0) {
                row(icon: "road.lanes", tint: LeapStyle.accent, title: "行程记录",
                    subtitle: tripSummary, route: .trips)
                separator
                row(icon: "bolt.car.fill", tint: LeapStyle.warm, title: "充电记录",
                    subtitle: chargeSummary, route: .charges)
                separator
                row(icon: "chart.bar.xaxis", tint: LeapStyle.cool, title: "里程能耗",
                    subtitle: "零跑官方按天 / 按周统计", route: .mileage)
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(LeapStyle.hairline).frame(height: 1).padding(.vertical, 12)
    }

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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
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
        VStack(alignment: .leading, spacing: 6) {
            Text("这些数字是怎么来的")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("行程与充电都会先拉零跑云端的结算记录（近 30 天，App 没开过也有），本机再补上云端没有的两项：行程的起终点地名、充电的起止电量与峰值功率。两边都没有的那段才按里程表 / 电量差补一条「补记」。\n官方「里程能耗」是另一套口径（按天结算），和逐趟的数字不会完全一致。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
    }

    // MARK: - 摘要

    /// 近 7 天，和列表页的汇总口径一致。多车账号只算当前这台车。
    private var tripSummary: String {
        let recent = recentTrips
        guard !recent.isEmpty else { return "还没有记录" }
        let km = recent.reduce(0) { $0 + $1.distanceKm }
        return "近 7 天 \(recent.count) 趟 · \(trimmed(km)) km"
    }

    private var chargeSummary: String {
        let recent = recentCharges
        guard !recent.isEmpty else { return "还没有记录" }
        let energy = recent.compactMap(\.energyKwh).reduce(0, +)
        guard energy > 0 else { return "近 7 天 \(recent.count) 次" }
        return "近 7 天 \(recent.count) 次 · \(trimmed(energy)) kWh"
    }

    private var recentTrips: [TripRecord] {
        let all = store.isDemo ? ReviewDemo.tripLog : trips.trips
        return filterRecent(all.filter { matchesCurrentVehicle($0.vin) }) { $0.startAt }
    }

    private var recentCharges: [ChargeRecord] {
        let all = store.isDemo ? ReviewDemo.chargeLog : charges.charges
        return filterRecent(all.filter { matchesCurrentVehicle($0.vin) }) { $0.startAt }
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
