import SwiftUI

/// 操作密码输入。用自绘键盘而不是系统键盘：密码是定长数字，
/// 自绘可以做到"输满即发"，也避免键盘弹出把玻璃层顶飞。
struct OperationPasswordSheet: View {
    @Environment(VehicleStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var prompt: String

    @State private var digits = ""
    @State private var remember = true
    @State private var shake = 0

    private let keys: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"]

    /// 零跑的操作密码是 4 位。输满即发，不用再点确认。
    private static let passwordLength = 4

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 0) {
                header
                dots
                keypad
                rememberToggle
                cancelButton
            }
            .padding(.top, 22)
            .padding(.bottom, 28)
            .padding(.horizontal, 26)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34)
                    .fill(.regularMaterial)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .onDisappear {
            // 侧滑关掉时要把待发指令一起丢弃，否则下次输密码会发出上一条。
            if !digits.isEmpty || store.challenge != nil { store.cancelChallenge() }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("输入操作密码")
                .font(.headline)
            Text("用于验证「\(prompt)」操作")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dots: some View {
        HStack(spacing: 16) {
            ForEach(0..<Self.passwordLength, id: \.self) { index in
                Circle()
                    .fill(index < digits.count ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(.secondary, lineWidth: 1.5))
                    .animation(.snappy, value: digits.count)
            }
        }
        .padding(.top, 22)
        .phaseAnimator([0, -8, 8, -5, 5, 0], trigger: shake) { content, offset in
            content.offset(x: offset)
        } animation: { _ in .easeInOut(duration: 0.06) }
    }

    private var keypad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                if key.isEmpty {
                    Color.clear.frame(height: 54)
                } else {
                    Button { tap(key) } label: {
                        Group {
                            if key == "⌫" {
                                Image(systemName: "delete.left")
                                    .font(.system(size: 19, weight: .medium))
                            } else {
                                Text(key)
                                    .font(.system(size: 22, weight: .medium, design: .rounded))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .contentShape(.rect(cornerRadius: 18))
                    }
                    .leapGlassButton()
                    .tint(key == "⌫" ? LeapStyle.secondaryLabel : LeapStyle.primaryLabel)
                }
            }
        }
        .padding(.top, 24)
        .sensoryFeedback(.selection, trigger: digits)
    }

    private var rememberToggle: some View {
        Toggle(isOn: $remember) {
            Text(store.biometricKind == .none
                 ? "在本机记住操作密码"
                 : "记住密码，之后用\(store.biometricKind.label)验证")
                .font(.footnote)
        }
        .tint(LeapStyle.accent)
        .padding(.top, 18)
    }

    private var cancelButton: some View {
        Button("取消") {
            store.cancelChallenge()
            dismiss()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.top, 14)
    }

    private func tap(_ key: String) {
        if key == "⌫" {
            if !digits.isEmpty { digits.removeLast() }
            return
        }
        guard digits.count < Self.passwordLength else { return }
        digits.append(key)
        guard digits.count == Self.passwordLength else { return }

        let password = digits
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            store.submitOperationPassword(password, remember: remember)
            dismiss()
        }
    }
}
