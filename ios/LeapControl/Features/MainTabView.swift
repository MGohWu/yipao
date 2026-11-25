import SwiftUI
import UIKit

/// App 的稳定一级结构。车辆页只承载日常高频操作，增长中的能力统一进入功能页，
/// 账号、安全和外观留在设置页，避免以后每新增一项就继续挤压首页。
///
/// 「服务」是第四项，放的是**过去发生过什么**：逐趟行程、每次充电、官方按天统计。
/// 功能页放的是**现在能对车做什么**，两者节奏完全不同——操作是进去就按，记录是
/// 偶尔翻出来对账。混在一起的话记录永远排在功能列表最后，找一次要滚很久。
struct MainTabView: View {
    enum Selection: Hashable {
        case vehicle
        case features
        case services
        case settings
    }

    @Environment(VehicleStore.self) private var store
    @State private var selection: Selection
    @State private var featurePath: [ControlFeature]
    @State private var servicePath: [ServiceRoute]

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let feature: ControlFeature? = {
            guard let index = arguments.firstIndex(of: "-feature"), index + 1 < arguments.count else { return nil }
            return ControlFeature(rawValue: arguments[index + 1])
        }()
        _selection = State(initialValue: arguments.contains("-featurestab") || feature != nil ? .features : .vehicle)
        _featurePath = State(initialValue: feature.map { [$0] } ?? [])
        _servicePath = State(initialValue: [])
    }

    var body: some View {
        TabView(selection: $selection) {
            // 车头正视，不用侧影：侧影和控车条里那几个车形字形（车锁、尾门）撞脸，
            // 一屏里三个大同小异的车侧面，谁是哪个得盯着看。
            Tab("车辆", systemImage: "car.fill", value: .vehicle) {
                HomeView()
            }

            Tab("功能", systemImage: "square.grid.2x2.fill", value: .features) {
                NavigationStack(path: $featurePath) {
                    FeatureCenterView(path: $featurePath)
                        .navigationDestination(for: ControlFeature.self) { feature in
                            ControlFeatureDestination(feature: feature)
                        }
                }
            }

            Tab("服务", systemImage: "wrench.and.screwdriver.fill", value: .services) {
                NavigationStack(path: $servicePath) {
                    ServicesView()
                        .navigationDestination(for: ServiceRoute.self) { route in
                            ServiceDestination(route: route)
                        }
                }
            }

            Tab("设置", systemImage: "gearshape.fill", value: .settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tint(LeapStyle.accent)
        .onChange(of: store.pendingDeepLink, initial: true) { _, link in
            guard let link else { return }
            if link == "settings" {
                selection = .settings
                store.pendingDeepLink = nil
            } else if link == "features" {
                selection = .features
                store.pendingDeepLink = nil
            } else if link == "services" || link == "records" {
                selection = .services
                servicePath = []
                store.pendingDeepLink = nil
            } else if ["tripLog", "trip", "tripsLog"].contains(link) {
                // 行程记录从 1.9 起挂在这个 Tab 下。桌面快捷方式上已经建好的老链接
                // 仍然要能用，所以这几个词继续认，只是目的地换了。
                selection = .services
                servicePath = [.trips]
                store.pendingDeepLink = nil
            } else if ["chargeLog", "chargelog", "chargeRecords"].contains(link) {
                selection = .services
                servicePath = [.charges]
                store.pendingDeepLink = nil
            } else if link == "mileage" || link == "mileageStats" {
                selection = .services
                servicePath = [.mileage]
                store.pendingDeepLink = nil
            } else if let feature = ControlFeature(rawValue: link) {
                // 从能源页的充电计划卡这类地方直接跳到某个功能预览页：切到功能 Tab 再把
                // 那一项推进栈。用深链而不是本地 NavigationLink，是因为能源页可能挂在车辆 Tab
                // 的栈里（HomeRoute），那儿没注册 ControlFeature 目的地，链接会点不动。
                selection = .features
                featurePath = [feature]
                store.pendingDeepLink = nil
            } else {
                selection = .vehicle
            }
        }
    }
}

/// 服务页的几个目的地。抽出来是为了让 `MainTabView`（注册路由）和 `ServicesView`
/// （画列表）之外的第三处——演示与截图用的 `DemoData`——也能复用同一套映射。
struct ServiceDestination: View {
    let route: ServiceRoute

    var body: some View {
        switch route {
        case .trips: TripHistoryView()
        case .charges: ChargeHistoryView()
        case .mileage: MileageStatsView()
        }
    }
}
