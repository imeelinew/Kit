import QuartzCore
import SwiftUI

/// Central design tokens for Kit's adaptive palette UI.
enum Theme {
    enum Motion {
        static let menuDuration = 0.14
        static let menuScale: CGFloat = 0.92
        static let contentDuration = 0.24
        static let button: Animation = .spring(response: 0.24, dampingFraction: 0.72)
        static let menu: Animation = .spring(response: 0.30, dampingFraction: 0.78)
        /// Lively but settled spring shared by content swaps, with a hint of overshoot.
        static let content: Animation = .spring(response: 0.36, dampingFraction: 0.82)

        /// Spring constants mirrored by Core Animation so AppKit and SwiftUI move alike.
        static let springStiffness: CGFloat = 320
        static let springDamping: CGFloat = 26
        static var springTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        }
        /// Fast curve for content or menus that are leaving.
        static let exitDuration = 0.11
        static var exitTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        }
        /// Delay between successive rows when a list cascades in.
        static let cascadeStagger = 0.018
        static let cascadeMaxRows = 10
        static let cascadeOffset: CGFloat = 12
        static let cascadeScale: CGFloat = 0.97

        static func transition(anchor: UnitPoint = .center) -> AnyTransition {
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: menuScale, anchor: anchor))
                    .combined(with: .blur(radius: 6)),
                removal: .opacity.combined(with: .scale(scale: 0.96, anchor: anchor))
                    .combined(with: .blur(radius: 4)))
        }

        /// Empty states drift up from a soft blur and sink back when replaced.
        static var emptyState: AnyTransition {
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.9))
                    .combined(with: .offset(y: 10)).combined(with: .blur(radius: 8)),
                removal: .opacity.combined(with: .scale(scale: 0.94))
                    .combined(with: .offset(y: -6)).combined(with: .blur(radius: 5)))
        }

        static func spring(
            _ keyPath: String, from: Any?, to: Any?, velocity: CGFloat = 0,
            in layer: CALayer? = nil, delay: CFTimeInterval = 0
        ) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = 1
            animation.stiffness = springStiffness
            animation.damping = springDamping
            animation.initialVelocity = velocity
            animation.fromValue = from
            animation.toValue = to
            animation.duration = animation.settlingDuration
            if delay > 0 {
                let now = layer.map { $0.convertTime(CACurrentMediaTime(), from: nil) }
                    ?? CACurrentMediaTime()
                animation.beginTime = now + delay
                animation.fillMode = .backwards
            }
            return animation
        }

        /// Rises a layer into place: opacity, a vertical lift and a slight scale settle on one spring.
        /// `lift` is in screen points, positive means the layer starts below its resting spot.
        static func rise(
            _ layer: CALayer, lift: CGFloat, scale: CGFloat, fromOpacity: Float = 0,
            delay: CFTimeInterval = 0, key: String = "kitRise"
        ) {
            let down: CGFloat = layer.superlayer?.contentsAreFlipped() == true ? 1 : -1
            let start = scaled(layer, by: scale, offsetY: lift * down)
            let opacity = spring(
                "opacity", from: fromOpacity, to: 1, velocity: 12, in: layer, delay: delay)
            // Opacity should finish early, a full spring tail would read as a slow fade.
            opacity.stiffness = springStiffness * 1.8
            opacity.damping = springDamping * 1.5
            opacity.duration = opacity.settlingDuration
            let transform = spring(
                "transform", from: NSValue(caTransform3D: start),
                to: NSValue(caTransform3D: CATransform3DIdentity), velocity: 10, in: layer,
                delay: delay)
            transform.isAdditive = false
            layer.add(opacity, forKey: key + ".opacity")
            layer.add(transform, forKey: key + ".transform")
        }

        /// Scales around the layer's visual center, AppKit backing layers anchor at their origin.
        static func scaled(_ layer: CALayer, by scale: CGFloat, offsetY: CGFloat = 0) -> CATransform3D {
            let size = layer.bounds.size
            let pivot = CGPoint(x: (0.5 - layer.anchorPoint.x) * size.width,
                                y: (0.5 - layer.anchorPoint.y) * size.height)
            var transform = CATransform3DMakeTranslation(
                pivot.x * (1 - scale), pivot.y * (1 - scale) + offsetY, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            return transform
        }
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
        /// Space above every category header except the first.
        static let sectionSpacing: CGFloat = 12
    }

    enum Radius {
        static let panel: CGFloat = 26
        static let row: CGFloat = 10
        /// Hover highlight behind a popover menu row.
        static let menuRow: CGFloat = 10
        static let menuPanel: CGFloat = 16
        static let thumbnail: CGFloat = 6
        static let card: CGFloat = 10
        static let keyCap: CGFloat = 6
    }

    enum Size {
        static let panelWidth: CGFloat = 750
        static let panelHeight: CGFloat = 475
        static let headerHeight: CGFloat = 44
        /// Vertical breathing room above the search row — constant across compact/expanded so the bar never shifts when typing flips the state; also the compact bar's symmetric top/bottom slack.
        static let headerPadding: CGFloat = 10
        static let bottomBarHeight: CGFloat = 52
        static let rowIcon: CGFloat = 24
        static let keyCap: CGFloat = 18
        static let menuButton: CGFloat = 36
        static let clipboardListWidth: CGFloat = 290
        static let menuWidth: CGFloat = 276
        /// Square slot for a popover-menu row's leading glyph. 20 (not the 16 the artwork suggests) because an `IconCache` app icon only paints ~85% of its canvas: at 20 its visible artwork is 17pt, matching the 17–18pt a `.body` SF Symbol renders at, so symbol and app-icon rows read the same size.
        static let menuIcon: CGFloat = 20
    }

    /// System text styles (not hardcoded sizes) so the UI honors Dynamic Type.
    enum Typography {
        static let sectionHeader = Font.subheadline.weight(.medium)
        static let keyCap = Font.caption
        static let bar = Font.callout.weight(.medium)
        static let menuRow = Font.body
        static let menuIcon = Font.body
    }

    enum Colors {
        /// Selection fill: a soft neutral translucent layer shared by launcher and clipboard so both lists look identical.
        static let selection = Color.primary.opacity(0.10)
        /// Mouse hover — a fainter layer that follows the cursor, visually distinct from selection.
        static let rowHover = Color.primary.opacity(0.05)
        static let menuHover = Color.primary.opacity(0.10)
        static let separator = Color.primary.opacity(0.10)
        /// Small control surfaces: kbd chips, glyph tiles.
        static let controlSurface = Color.primary.opacity(0.08)
        /// Control borders: outlined kbd chips.
        static let border = Color.primary.opacity(0.20)
        static let textSecondary = Color.primary.opacity(0.60)
        static let cardStroke = Color.primary.opacity(0.10)
        /// Whitish tint layered into the Liquid Glass floating controls (action group + menu circle) so the glass reads frosted rather than clear.
        static let glassFrost = Color.white.opacity(0.05)
    }
}

/// A single keycap chip: `.outline` for hotkey hints on rows, `.filled` for footer shortcuts.
struct KeyCapChip: View {
    enum Style {
        case outline
        case filled
    }

    let text: String
    var style: Style = .filled

    /// "↵" is absent from SF Pro and falls back to Lucida Grande UI, which seats it 1.1pt higher in the line box than the SF caps — visibly top-heavy in a chip. Nudging via `offset` is render-only, so the chip keeps the same footprint as every other cap.
    private static let returnGlyphDrop: CGFloat = 1.1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
        Text(text)
            .font(Theme.Typography.keyCap)
            .foregroundStyle(Theme.Colors.textSecondary)
            .offset(y: text == "↵" ? Self.returnGlyphDrop : 0)
            .padding(.horizontal, Theme.Spacing.xs)
            .frame(minWidth: Theme.Size.keyCap, minHeight: Theme.Size.keyCap)
            .background {
                switch style {
                case .filled: shape.fill(Theme.Colors.controlSurface)
                case .outline: shape.strokeBorder(Theme.Colors.border, lineWidth: 1)
                }
            }
    }
}

extension View {
    /// A floating Liquid Glass control surface (action group + menu button), interactive for native lensing with a subtle frost tint.
    func frosted(in shape: some Shape) -> some View {
        glassEffect(.regular.interactive().tint(Theme.Colors.glassFrost), in: shape)
            .tint(.clear)
    }
}

private struct BlurTransitionModifier: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

extension AnyTransition {
    /// Softens content into focus as it arrives and out of focus as it leaves.
    static func blur(radius: CGFloat) -> AnyTransition {
        .modifier(
            active: BlurTransitionModifier(radius: radius),
            identity: BlurTransitionModifier(radius: 0))
    }
}
