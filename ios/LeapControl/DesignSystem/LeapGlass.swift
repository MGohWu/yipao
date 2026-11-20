import SwiftUI

/// 液态玻璃的兼容层。
///
/// `glassEffect` / `GlassEffectContainer` / `.buttonStyle(.glass)` 这一整套都是 iOS 26 起才有的，
/// 而 app 的部署目标是 iOS 18。直接写在各个页面里会到处散落 `if #available`，
/// 所以把分支收在这一个文件里：调用点只认 `leapGlass` 系列，跑在哪个系统上由这里决定。
///
/// 降级方案是毛玻璃（`.ultraThinMaterial`）+ 手描边缘线。它换不来折射和形变，
/// 但保住了"底下的内容能透上来"这一条——`LeapBackground` 的光晕正是给这个用的。

// MARK: - 玻璃材质描述

/// `Glass` 本身带 iOS 26 标注，没法出现在跨版本的函数签名里，这里做一份等价的描述，
/// 到了 iOS 26 再翻译成真的 `Glass`。
struct LeapGlass {
    var tintColor: Color?
    var isInteractive = false

    static let regular = LeapGlass()

    func tint(_ color: Color) -> LeapGlass {
        var copy = self
        copy.tintColor = color
        return copy
    }

    func interactive() -> LeapGlass {
        var copy = self
        copy.isInteractive = true
        return copy
    }

    @available(iOS 26.0, *)
    fileprivate var system: Glass {
        var glass = Glass.regular
        if let tintColor { glass = glass.tint(tintColor) }
        if isInteractive { glass = glass.interactive() }
        return glass
    }
}

// MARK: - 视图修饰

extension View {
    /// `glassEffect(_:in:)` 的跨版本版本。
    @ViewBuilder
    func leapGlass(_ glass: LeapGlass = .regular, in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(glass.system, in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    // tint 的透明度在调用点就乘好了，这里直接铺，叠在毛玻璃上。
                    if let tintColor = glass.tintColor {
                        shape.fill(tintColor)
                    }
                }
            }
            .overlay {
                shape.stroke(LeapStyle.glassEdge, lineWidth: 0.8)
            }
        }
    }

    /// `glassEffectID(_:in:)` 的跨版本版本。低版本没有玻璃融合，这个标识没有意义，原样返回。
    @ViewBuilder
    func leapGlassID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` 的跨版本版本。
    /// 两个分支都尊重调用点的 `.tint(...)`，所以调用点不用改。
    @ViewBuilder
    func leapGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            buttonStyle(LeapFallbackGlassButtonStyle(prominent: prominent))
        }
    }
}

// MARK: - 容器

/// `GlassEffectContainer` 的跨版本版本。
/// 低版本没有玻璃融合可言，容器退化成纯透传——注意这意味着底部控车条那五个按钮
/// 在 iOS 18 上是五块独立的毛玻璃，不会连成一条。
struct LeapGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - 降级按钮样式

/// iOS 26 以下的玻璃按钮。形状固定成胶囊，和系统 `.glass` 的默认形状保持一致。
private struct LeapFallbackGlassButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        LeapFallbackGlassButtonBody(
            prominent: prominent,
            isPressed: configuration.isPressed,
            label: configuration.label
        )
    }
}

/// 单拎一层 View 出来是为了读 `isEnabled`：`ButtonStyle` 本身不是 View，拿不到环境值，
/// 而系统的玻璃按钮在 disabled 时是会自己压暗的（登录页的倒计时按钮全靠这个）。
private struct LeapFallbackGlassButtonBody<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    var prominent: Bool
    var isPressed: Bool
    var label: Label

    var body: some View {
        label
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            .background {
                if prominent {
                    Capsule().fill(.tint)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay {
                Capsule().stroke(LeapStyle.glassEdge, lineWidth: 0.8)
            }
            .contentShape(.capsule)
            .opacity(isEnabled ? (isPressed ? 0.72 : 1) : 0.4)
            .animation(.easeOut(duration: 0.15), value: isPressed)
    }
}
