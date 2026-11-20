import SwiftUI

@main
struct LeapControlApp: App {
    @State private var store = VehicleStore()
    /// 只为长按图标那几个快捷方式存在：它们的回调只发给场景代理，
    /// 而 SwiftUI 不给自定义场景代理的入口，只能从这里换进去（见 `LeapAppDelegate`）。
    @UIApplicationDelegateAdaptor(LeapAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                // 挂在根视图上会一路传到窗口，弹出的 sheet 也跟着走。跟随系统时是 nil，不干预。
                .preferredColorScheme(store.appearance.colorScheme)
                // 这是面向国内零跑车主的单语言 App，日期/相对时间都要跟界面一致走中文。
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                .task {
                    await store.bootstrap()
                    #if DEBUG
                    // `-retrytoast` 直接挂一条带重试的失败提示，配合 `-demo` 核对这张卡片的排版。
                    if ProcessInfo.processInfo.arguments.contains("-retrytoast") {
                        store.toast = ToastMessage(
                            text: "关闭尾门未收到车辆确认",
                            detail: "车可能仍在唤醒，可稍后重试",
                            isError: true,
                            showsRetry: true,
                            seconds: 600
                        )
                    }
                    #endif
                }
                .onOpenURL { url in
                    // 桌面卡片点进来：leapcontrol://charge 之类。
                    guard url.scheme == LeapDeepLink.scheme else { return }
                    // 卡片上的控车按钮走 leapcontrol://action?a=toggleLock，
                    // 落到共享偏好里，由 App 走完整的 Face ID + 操作密码流程。
                    if let action = WidgetAction(deepLink: url) {
                        SharedSettings.pendingWidgetAction = action.rawValue
                        // 冷启动时这里可能早于 bootstrap 拿到 session，那时会自动留到 bootstrap 里消费。
                        Task { await store.refreshThenConsumePendingAction() }
                        return
                    }
                    store.pendingDeepLink = url.host()
                }
                // 长按桌面图标按下的那一下。App 已经在跑时 `scenePhase` 未必会变，
                // 从后台回来那一下的先后顺序也不保证，所以这条信号是独立的。
                .onReceive(NotificationCenter.default.publisher(for: .leapQuickAction)) { _ in
                    Task { await store.refreshThenConsumePendingAction() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .leapWidgetAction)) { _ in
                    Task { await store.refreshThenConsumePendingAction() }
                }
        }
    }
}

struct RootView: View {
    @Environment(VehicleStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var store = store

        Group {
            #if DEBUG
            if let screen = DemoData.initialScreen, store.isLoggedIn {
                DemoScreenHost(screen: screen)
            } else if store.isLoggedIn {
                MainTabView()
                    .id(store.loginEpoch)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                LoginView()
                    .transition(.opacity)
            }
            #else
            if store.isLoggedIn {
                MainTabView()
                    .id(store.loginEpoch)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                LoginView()
                    .transition(.opacity)
            }
            #endif
        }
        .animation(.smooth(duration: 0.45), value: store.isLoggedIn)
        .overlay(alignment: .bottom) { ToastOverlay() }
        .sheet(item: $store.challenge) { challenge in
            switch challenge {
            case .operationPassword(let prompt):
                OperationPasswordSheet(prompt: prompt)
                    .presentationDetents([.height(520)])
                    .presentationBackground(.clear)
                    .interactiveDismissDisabled(false)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            store.updateApplicationActivity(phase == .active)
            // 退到后台就把这次的验证作废——`perform` 里那句「回到后台会作废」
            // 一直没人兑现，于是验证过一次之后，`verifiedPassword` 会在内存里活到
            // 进程被杀，中间任何一次 `leapcontrol://action?a=...` 唤起都能静默控车。
            //
            // 判的是 `.background` 而不是 `!= .active`：Face ID 弹出、下拉控制中心、
            // 通知横幅都会让 App 变成 `.inactive`，那时清掉就成了「刚验完又要验」。
            if phase == .background {
                store.endForegroundVerification()
            }
            // 回到前台时先探一次登录态（被挤下线只有主动探控车 token 才发现），
            // 有效再静默刷新车况并开始轮询；失效则 validateSession 已把人送回登录页。
            //
            // **这四步的顺序是要紧的。** 卡片按钮和桌面快捷方式都只把动作寄存下来，
            // 真正下发在 `consumePendingWidgetAction`，而车锁、尾门、空调都是
            // 照手上这份车况取反的；退到后台就停了轮询，`state` 冻在退后台那一刻。
            // 原来这里是先消费再刷新——中午锁好车、晚上按一下「开关车锁」，
            // 取反读到的还是中午那份「已锁」，发出去的会是解锁。
            // 轮询放最后开：`refresh()` 撞上正在飞的请求会直接返回，先开轮询等于自找撞车。
            if phase == .active, store.isLoggedIn {
                Task {
                    guard await store.validateSession() else { return }
                    await store.refresh()
                    store.consumePendingWidgetAction()
                    store.startPolling()
                }
            } else if phase == .active {
                // 停在登录页也可能是启动那帧钥匙串没读到（重启未解锁被拉起、
                // prewarming），前台已解锁，给一次重读自愈的机会。
                Task { await store.restoreSessionIfNeeded() }
            } else {
                store.stopPolling()
            }
        }
    }
}

/// 全局轻提示。指令下发返回的 msgID 放在副标题里，便于对照服务端日志。
struct ToastOverlay: View {
    @Environment(VehicleStore.self) private var store

    var body: some View {
        if let toast = store.toast {
            Group {
                if toast.showsRetry {
                    retryCard(toast)
                } else {
                    capsule(toast)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
            .task(id: toast.id) {
                // 这个 App 的全部意义就是「指令发出去了，车到底动没动」。
                // 结果只写在这条一闪而过的提示里，VoiceOver 用户等于收不到——
                // 所以出现时主动播报一次。
                AccessibilityNotification.Announcement(
                    [toast.text, toast.detail].compactMap { $0 }.joined(separator: "，")
                ).post()
                try? await Task.sleep(for: .seconds(toast.seconds))
                withAnimation(.smooth) { store.toast = nil }
            }
            .animation(.bouncy(duration: 0.45), value: toast.id)
        }
    }

    /// 普通轻提示：居中小胶囊，几秒后自己消失。
    private func capsule(_ toast: ToastMessage) -> some View {
        VStack(spacing: 2) {
            Label {
                Text(toast.text)
                    .font(.subheadline.weight(.medium))
            } icon: {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? LeapStyle.caution : LeapStyle.accent)
            }
            if let detail = toast.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .leapGlass(.regular, in: .capsule)
        .padding(.bottom, 120)
    }

    /// 控车失败要重试的提示：贴着控车条的全宽卡片。
    /// 「重试」是用户此刻最可能按的一个键，做成整行宽，别让人眯着眼找小胶囊。
    private func retryCard(_ toast: ToastMessage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(LeapStyle.caution)
                VStack(alignment: .leading, spacing: 3) {
                    Text(toast.text)
                        .font(.headline)
                    if let detail = toast.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                store.retryLastCommand()
            } label: {
                Text("重试")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .leapGlassButton(prominent: true)
            .tint(LeapStyle.accent)
        }
        .padding(18)
        .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
        .padding(.horizontal, 16)
        .padding(.bottom, 108)
    }
}
