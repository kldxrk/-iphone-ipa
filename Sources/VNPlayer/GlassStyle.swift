import SwiftUI

/// 统一的「液态玻璃」外观层。
///
/// 两个必须同时存在的门禁：
///  * `#if compiler(>=6.2)` —— **编译期**门禁。玻璃 API 只存在于 Xcode 26（Swift 6.2 / iOS 26 SDK）。
///    `if #available` 只是运行期门禁，旧 Xcode 里那些符号根本不存在，会直接编译失败，
///    所以旧工具链必须靠 `#if` 把整段代码编译掉。
///  * `if #available(iOS 26.0, *)` —— **运行期**门禁，用 Xcode 26 构建但跑在 iOS 16~18 设备上时走降级分支。
///
/// 降级分支不是"随便糊一层模糊"：超薄材质 + 顶部高光描边 + 投影，观感接近，
/// 只是没有真玻璃的折射和随手指/陀螺仪的动态响应。
enum GlassMetrics {
    static let card: CGFloat = 22
    static let control: CGFloat = 16
    static let bubble: CGFloat = 14
}

// MARK: - 玻璃面板

struct GlassSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = GlassMetrics.card
    var tint: Color?
    var interactive = false
    var prominent = false

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var glass: Glass {
        // 链式顺序有讲究：先选基础材质 → 着色 → 再开启交互
        var value: Glass = .regular
        if let tint { value = value.tint(tint) }
        if prominent, tint == nil { value = value.tint(.accentColor) }
        if interactive { value = value.interactive() }
        return value
    }
    #endif

    @ViewBuilder
    private func legacy(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(.ultraThinMaterial)
                    .overlay {
                        if prominent {
                            shape.fill(Color.accentColor.opacity(0.55))
                        }
                        if let tint {
                            shape.fill(tint.opacity(0.25))
                        }
                    }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.5), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }
}

// MARK: - 成组玻璃容器

/// iOS 26 上让相邻玻璃元素互相"融合"；旧系统直接透传。
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    private let content: () -> Content

    /// 显式写 init：不依赖"属性上的 @ViewBuilder 会传递到合成 memberwise init"这个行为。
    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

extension View {
    /// 玻璃面板。
    func glassSurface(cornerRadius: CGFloat = GlassMetrics.card,
                      tint: Color? = nil,
                      interactive: Bool = false,
                      prominent: Bool = false) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, tint: tint,
                                     interactive: interactive, prominent: prominent))
    }

    /// 玻璃按钮样式。iOS 26 用系统玻璃按钮，旧系统用手写的等效实现。
    @ViewBuilder
    func glassButton(prominent: Bool = false,
                     cornerRadius: CGFloat = GlassMetrics.control) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self.buttonStyle(LegacyGlassButtonStyle(prominent: prominent, cornerRadius: cornerRadius))
        }
        #else
        self.buttonStyle(LegacyGlassButtonStyle(prominent: prominent, cornerRadius: cornerRadius))
        #endif
    }

    /// 玻璃轮缘高光：盖在背景图/立绘上，模拟真玻璃的边框折光。
    func glassRimLight(cornerRadius: CGFloat = GlassMetrics.card) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.0), .white.opacity(0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
    }
}

/// 旧系统上的玻璃按钮：超薄材质 + 高光描边 + 按压反馈。
struct LegacyGlassButtonStyle: ButtonStyle {
    var prominent = false
    var cornerRadius: CGFloat = GlassMetrics.control

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, prominent ? 20 : 14)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background {
                if prominent {
                    shape.fill(Color.accentColor.opacity(configuration.isPressed ? 0.7 : 0.95))
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .overlay {
                shape.strokeBorder(.white.opacity(prominent ? 0.28 : 0.4), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// 播放器/游戏库的统一背景：带一点玻璃质感底色的渐变，避免纯黑显得廉价。
struct GlassBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.06, blue: 0.10),
                         Color(red: 0.10, green: 0.11, blue: 0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.accentColor.opacity(0.22), .clear],
                center: .topTrailing,
                startRadius: 4,
                endRadius: 420
            )
        }
    }
}
