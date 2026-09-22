import SwiftUI

/// Central design tokens for Paste's adaptive palette UI.
enum Theme {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
        /// Gap under a category header before its first row.
        static let sectionHeaderBottom: CGFloat = 4
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
        /// Fraction of the active screen's visible height between the top of the visible area and the palette's top edge; the window grows downward from this edge (Spotlight-style upper placement).
        static let paletteTopMarginFraction: CGFloat = 0.18
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
        static let searchField = Font.system(size: 20, weight: .regular)
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
        static let textTertiary = Color.primary.opacity(0.40)
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
