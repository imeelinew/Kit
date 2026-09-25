import Foundation

/// The sole sizing policy for pinned cards. The image fits inside the card; its aspect ratio
/// never overrides the minimum space needed for the controls.
struct PinnedImageGeometry {
    static let minimumSize = CGSize(width: 240, height: 160)

    let baseSize: CGSize
    private(set) var center: CGPoint
    private(set) var logarithmicScale: CGFloat = 0

    init(imageSize: CGSize, visibleFrame: CGRect, preferredLongEdge: CGFloat) {
        let bounds = Self.usableBounds(visibleFrame)
        let natural = CGSize(
            width: Self.positive(imageSize.width, fallback: 1_200),
            height: Self.positive(imageSize.height, fallback: 900)
        )
        let preferred = Self.positive(preferredLongEdge, fallback: 480)
        let factor = min(
            preferred / max(natural.width, natural.height),
            bounds.width / natural.width, bounds.height / natural.height, 1
        )
        baseSize = CGSize(
            width: min(max(natural.width * factor, Self.minimumSize.width), bounds.width),
            height: min(max(natural.height * factor, Self.minimumSize.height), bounds.height)
        )
        center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    var frame: CGRect {
        let scale = exp(logarithmicScale)
        let size = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
        return CGRect(
            x: center.x - size.width / 2, y: center.y - size.height / 2,
            width: size.width, height: size.height)
    }

    /// Additive gesture deltas make equal opposite movements reversible. Clamp the stored
    /// scale as well as the frame, so reversing at a boundary responds immediately.
    mutating func zoom(by delta: CGFloat, visibleFrame: CGRect) {
        guard delta.isFinite else { return }
        let bounds = Self.usableBounds(visibleFrame)
        let maximum = max(
            min(
                2 * min(center.x - bounds.minX, bounds.maxX - center.x) / baseSize.width,
                2 * min(center.y - bounds.minY, bounds.maxY - center.y) / baseSize.height
            ), .leastNormalMagnitude)
        let minimum = min(minimumScale, maximum)
        logarithmicScale = min(max(logarithmicScale + delta, log(minimum)), log(maximum))
    }

    /// Reposition only after a deliberate drag or a display change, never during zooming.
    mutating func fit(visibleFrame: CGRect, movedCenter: CGPoint? = nil) {
        let bounds = Self.usableBounds(visibleFrame)
        let maximum = min(bounds.width / baseSize.width, bounds.height / baseSize.height)
        logarithmicScale = min(max(logarithmicScale, log(min(minimumScale, maximum))), log(maximum))
        let size = frame.size
        let requested = movedCenter ?? center
        center = CGPoint(
            x: min(max(requested.x, bounds.minX + size.width / 2), bounds.maxX - size.width / 2),
            y: min(max(requested.y, bounds.minY + size.height / 2), bounds.maxY - size.height / 2)
        )
    }

    private var minimumScale: CGFloat {
        max(Self.minimumSize.width / baseSize.width, Self.minimumSize.height / baseSize.height)
    }

    private static func usableBounds(_ visible: CGRect) -> CGRect {
        // Preserve usable bounds even for a temporarily tiny display during reconfiguration.
        let inset = min(12, max((min(visible.width, visible.height) - 1) / 2, 0))
        return visible.insetBy(dx: inset, dy: inset)
    }

    private static func positive(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : fallback
    }
}
