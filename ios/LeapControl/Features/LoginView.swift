import SwiftUI

struct LoginView: View {
    @Environment(VehicleStore.self) private var store

    @State private var phone = ""
    @State private var code = ""
    @State private var isWorking = false
    @State private var countdown = 0
    /// 同意用户协议和隐私政策，不勾不能登录。默认不勾——同意得是用户的主动动作。
    @State private var agreed = false
    /// 未勾选就点按钮时，让勾选框抖一下提示。
    @State private var agreementNudge = false
    @State private var agreementScrollRequest = 0
    @State private var presentedDoc: LegalDoc?
    @FocusState private var focus: Field?

    private enum Field { case phone, code }

    private var phoneValid: Bool { phone.count == 11 && phone.allSatisfy(\.isNumber) }
    private var codeValid: Bool { code.count == 6 && code.allSatisfy(\.isNumber) }

    var body: some View {
        ZStack {
            // 点空白处收键盘：numberPad 没有回车键，靠这个 + 键盘上的「完成」两条路。
            LeapBackground(tint: LeapStyle.accent)
                .contentShape(Rectangle())
                .onTapGesture { focus = nil }

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            header

                            phoneField
                                .padding(.top, 34)

                            codeField
                                .padding(.top, 12)

                            smsButton
                                .padding(.top, 12)

                            agreementRow
                                .id("login-agreement")

                            Spacer(minLength: 34)

                            demoHint

                            submitButton

                            Text("手机号加密后发送，登录状态只保存在本机。")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 10)
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 90)
                        .padding(.bottom, 34)
                        .frame(minHeight: geometry.size.height, alignment: .top)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: agreementScrollRequest) {
                        withAnimation {
                            proxy.scrollTo("login-agreement", anchor: .center)
                        }
                    }
                }
            }
        }
        .task(id: countdown) {
            guard countdown > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            countdown -= 1
        }
        .sheet(item: $presentedDoc) { LegalDocView(doc: $0) }
    }

    /// 勾选同意协议。协议紧跟表单，键盘弹起时仍可滚动到它。
    private var agreementRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                agreed.toggle()
            } label: {
                Image(systemName: agreed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(agreed ? LeapStyle.accent : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("同意用户协议和隐私政策")
            .accessibilityAddTraits(agreed ? [.isSelected] : [])

            // 协议名是 markdown 链接，点击交给 openURL 处理，正文其余是说明文字。
            // 用自定义 scheme（leap://）而不是真 URL，拦下来在 App 内弹文档，不出网。
            Text(agreementText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .tint(LeapStyle.accent)
                .environment(\.openURL, OpenURLAction { url in
                    switch url.absoluteString {
                    case "leap://user-agreement": presentedDoc = .userAgreement
                    case "leap://privacy": presentedDoc = .privacy
                    default: break
                    }
                    return .handled
                })
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .center)
        // 整行可点：勾选框太小不好戳。点行内空白/说明文字都切换勾选，
        // 两个协议名仍走各自的链接（Text 的链接命中优先于这层手势），复选框按钮也照旧。
        .contentShape(Rectangle())
        .onTapGesture { agreed.toggle() }
        .symbolEffect(.wiggle, options: .nonRepeating, value: agreementNudge)
    }

    /// 「我已阅读并同意《用户协议》和《隐私政策》」，两份协议名是可点链接。
    private var agreementText: AttributedString {
        let markdown = "我已阅读并同意[《用户协议》](leap://user-agreement)和[《隐私政策》](leap://privacy)"
        return (try? AttributedString(markdown: markdown))
            ?? AttributedString("我已阅读并同意《用户协议》和《隐私政策》")
    }

    /// 没勾就点主按钮：抖一下勾选框、把它推到眼前，而不是默默无反应。
    private func requireAgreement() -> Bool {
        guard agreed else {
            store.show(
                text: "请先同意协议",
                detail: "请阅读并勾选同意《用户协议》和《隐私政策》",
                isError: true
            )
            agreementNudge.toggle()
            agreementScrollRequest += 1
            focus = nil
            return false
        }
        return true
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("壹跑")
                .font(.caption.weight(.medium))
                .tracking(6)
                .foregroundStyle(.tertiary)
            Text("你好，\n欢迎回来")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
            Text("使用手机验证码登录")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var phoneField: some View {
        HStack(spacing: 12) {
            Text("+86")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("手机号", text: $phone)
                .keyboardType(.numberPad)
                .textContentType(.telephoneNumber)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .focused($focus, equals: .phone)
                .onChange(of: phone) { _, new in
                    phone = String(new.filter(\.isNumber).prefix(11))
                }
        }
        .padding(16)
        .leapGlass(.regular, in: .rect(cornerRadius: 18))
    }

    private var codeField: some View {
        HStack(spacing: 12) {
            Image(systemName: "message.badge.filled.fill")
                .foregroundStyle(.secondary)
            TextField("6 位验证码", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .monospaced()
                .focused($focus, equals: .code)
                .onChange(of: code) { _, new in
                    code = String(new.filter(\.isNumber).prefix(6))
                }
        }
        .padding(16)
        .leapGlass(.regular, in: .rect(cornerRadius: 18))
    }

    private var smsButton: some View {
        Button {
            guard requireAgreement() else { return }
            Task {
                isWorking = true
                if await store.sendSMS(phone: phone) {
                    countdown = 60
                    focus = .code
                }
                isWorking = false
            }
        } label: {
            Text(countdown > 0 ? "重新发送 (\(countdown)s)" : "获取验证码")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
        }
        .leapGlassButton()
        .disabled(!phoneValid || countdown > 0 || isWorking)
    }

    /// 没有车主账号的人（审核员、想先看看的朋友）需要一个入口，否则打开就是一堵登录墙。
    /// 但这是次要路径，做成一行小字就够——真正要用这个 App 的人是来登录的。
    /// 轻点直接把演示账号填好，不用手抄。
    private var demoHint: some View {
        Button("没有账号？试试演示模式") {
            phone = ReviewDemo.phone
            code = ReviewDemo.code
            focus = nil
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 14)
    }

    private var submitButton: some View {
        Button {
            guard requireAgreement() else { return }
            Task {
                isWorking = true
                _ = await store.login(phone: phone, code: code)
                isWorking = false
            }
        } label: {
            Group {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("登录").font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .leapGlassButton(prominent: true)
        .tint(LeapStyle.accent)
        .disabled(!phoneValid || !codeValid || isWorking)
    }
}
