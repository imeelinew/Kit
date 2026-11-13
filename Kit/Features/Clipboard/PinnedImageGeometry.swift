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

    var minimumFrameSize: CGSize {
        CGSize(width: baseSize.width * minimumScale, height: baseSize.height * minimumScale)
    }

    mutating func adopt(_ frame: CGRect) {
        guard frame.width.isFinite, frame.height.isFinite,
            frame.width > 0, frame.height > 0 else { return }
        logarithmicScale = log(frame.width / baseSize.width)
        center = CGPoint(x: frame.midX, y: frame.midY)
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

/// Screen coordinates, positive Y points upward
struct PinnedImageResizeEdge: Equatable {
    let x: CGFloat
    let y: CGFloat
    static let hitWidth: CGFloat = 14

    static func hit(at point: CGPoint, in bounds: CGRect) -> Self? {
        guard bounds.contains(point) else { return nil }
        let x: CGFloat = point.x < bounds.minX + hitWidth ? -1
            : point.x > bounds.maxX - hitWidth ? 1 : 0
        let y: CGFloat = point.y < bounds.minY + hitWidth ? -1
            : point.y > bounds.maxY - hitWidth ? 1 : 0
        return x == 0 && y == 0 ? nil : Self(x: x, y: y)
    }

    func frame(from start: CGRect, delta: CGSize, minimum: CGSize, visible: CGRect) -> CGRect {
        let anchor = CGPoint(x: x < 0 ? start.maxX : x > 0 ? start.minX : start.midX,
                             y: y < 0 ? start.maxY : y > 0 ? start.minY : start.midY)
        let horizontal = x * delta.width / start.width
        let vertical = y * delta.height / start.height
        let change = x == 0 ? vertical : y == 0 ? horizontal
            : (abs(horizontal) > abs(vertical) ? horizontal : vertical)
        let availableWidth = x < 0 ? anchor.x - visible.minX : x > 0
            ? visible.maxX - anchor.x : 2 * min(anchor.x - visible.minX, visible.maxX - anchor.x)
        let availableHeight = y < 0 ? anchor.y - visible.minY : y > 0
            ? visible.maxY - anchor.y : 2 * min(anchor.y - visible.minY, visible.maxY - anchor.y)
        let maximum = max(0.001, min(availableWidth / start.width, availableHeight / start.height))
        let lower = min(max(minimum.width / start.width, minimum.height / start.height), maximum)
        let scale = min(max(1 + change, lower), maximum)
        let size = CGSize(width: start.width * scale, height: start.height * scale)
        return CGRect(x: anchor.x - (x < 0 ? size.width : x == 0 ? size.width / 2 : 0),
                      y: anchor.y - (y < 0 ? size.height : y == 0 ? size.height / 2 : 0),
                      width: size.width, height: size.height)
    }
}
