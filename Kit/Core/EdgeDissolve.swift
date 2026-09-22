import SwiftUI

struct EdgeDissolveScrollState: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var canScroll = false
}

/// Scroll-driven edge dissolve for a scroll view underlapping the palette's floating bars, a port of Raycast's scroll-area mask (see `docs/ui.md` → The edge dissolve).
struct EdgeDissolveMask: ViewModifier {
    var externalState: EdgeDissolveScrollState

    /// Band lengths: the bar's occupied height plus Raycast's overshoot into the list (32px below the header, 28px above the footer).
    var topFade: CGFloat = Theme.Size.headerHeight + Theme.Size.headerPadding + 32
    var bottomFade: CGFloat = Theme.Size.bottomBarHeight + 28
    private static let topMinAlpha: CGFloat = 0.15
    private static let bottomMinAlpha: CGFloat = 0.25

    /// How much content is hidden beyond each edge, 0 when the list rests against it.
    @State private var topDistance: CGFloat = 0
    @State private var bottomDistance: CGFloat = 0
    @State private var canScroll = false

    func body(content: Content) -> some View {
        masked(
            content
                .onAppear { apply(externalState) }
                .onChange(of: externalState) { _, new in apply(new) }
        )
    }

    private func masked<Content: View>(_ content: Content) -> some View {
        content.mask(
            // Must span the scroll view's *full* frame — the bars' safe-area insets would otherwise shift the gradient inward, clipping the underlap regions to black.
            GeometryReader { geo in
                LinearGradient(
                    stops: stops(height: geo.size.height),
                    startPoint: .top, endPoint: .bottom
                )
            }
            .ignoresSafeArea()
        )
    }

    private func apply(_ state: EdgeDissolveScrollState) {
        topDistance = max(0, state.top)
        bottomDistance = max(0, state.bottom)
        canScroll = state.canScroll
    }

    private func stops(height: CGFloat) -> [Gradient.Stop] {
        guard canScroll, height > 0 else { return [.init(color: .black, location: 0)] }
        // Midpoint alpha eases from 1 toward the floor as a full band of content scrolls past (Raycast: opacity = 1 − (1 − min) · clamp(scrollDistance / fadeHeight, 0, 1)).
        let topAlpha = 1 - (1 - Self.topMinAlpha) * min(topDistance / topFade, 1)
        let bottomAlpha = 1 - (1 - Self.bottomMinAlpha) * min(bottomDistance / bottomFade, 1)
        return [
            .init(color: .black.opacity(0), location: 0),
            .init(color: .black.opacity(topAlpha), location: topFade / 2 / height),
            .init(color: .black, location: topFade / height),
            .init(color: .black, location: 1 - bottomFade / height),
            .init(color: .black.opacity(bottomAlpha), location: 1 - bottomFade / 2 / height),
            .init(color: .black.opacity(0), location: 1),
        ]
    }
}

extension View {
    /// AppKit scroll views report geometry through their representable coordinator.
    func edgeDissolve(state: EdgeDissolveScrollState) -> some View {
        modifier(EdgeDissolveMask(externalState: state))
    }
}
