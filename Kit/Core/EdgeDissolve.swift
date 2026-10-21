import AppKit
import QuartzCore

/// Edge masks are applied to the clip view so the indicator remains outside the dissolve
enum EdgeDissolve {
    case none
    case palette
    case bottom(CGFloat)

    @MainActor
    func apply(to clip: NSClipView, mask: CAGradientLayer, content: CGFloat, offset: CGFloat) {
        let bounds = clip.bounds
        guard bounds.height > 0, content > bounds.height + 1 else {
            clip.layer?.mask = nil
            return
        }
        let alphas: [CGFloat]
        let locations: [CGFloat]
        switch self {
        case .none:
            clip.layer?.mask = nil
            return
        case .palette:
            let top = min(Theme.Size.headerHeight + Theme.Size.headerPadding + 32, bounds.height / 2)
            let bottom = min(Theme.Size.bottomBarHeight + 28, bounds.height / 2)
            let topAlpha = 1 - 0.85 * min(offset / top, 1)
            let bottomAlpha = 1 - 0.75 * min(max(0, content - bounds.height - offset) / bottom, 1)
            alphas = [0, topAlpha, 1, 1, bottomAlpha, 0]
            locations = [0, top / 2 / bounds.height, top / bounds.height,
                         1 - bottom / bounds.height, 1 - bottom / 2 / bounds.height, 1]
        case .bottom(let height):
            alphas = [1, 1, 0]
            locations = [0, 1 - min(height, bounds.height) / bounds.height, 1]
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        mask.startPoint = CGPoint(x: 0.5, y: clip.isFlipped ? 0 : 1)
        mask.endPoint = CGPoint(x: 0.5, y: clip.isFlipped ? 1 : 0)
        mask.colors = alphas.map { NSColor.black.withAlphaComponent($0).cgColor }
        mask.locations = locations.map { NSNumber(value: Double($0)) }
        clip.layer?.mask = mask
        CATransaction.commit()
    }
}
