import CoreGraphics
import Foundation
@testable import Kit

enum WindowGeometryTests {
    @MainActor
    static func run() async throws {
        try paletteDefaultFrames()
        try paletteSnapping()
        try pinnedImageSizing()
        try pinnedImageInvalidInputs()
        try pinnedImageZoom()
        try pinnedImageAdoptionAndDisplayChanges()
        print("PASS: palette frames, snapping, pinned sizing, zoom, adoption, and display changes")
    }

    @MainActor
    private static func paletteDefaultFrames() throws {
        let main = PaletteSnapGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_200),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_160)
        )
        let defaultFrame = main.defaultFrame(preferredSize: CGSize(width: 640, height: 600))
        try TestSupport.expect(close(defaultFrame, CGRect(x: 640, y: 351.2, width: 640, height: 600)),
                               "The default frame is centered and hangs below the top guide")

        let oversized = main.defaultFrame(preferredSize: CGSize(width: 2_400, height: 1_800))
        try TestSupport.expect(close(oversized, CGRect(x: 16, y: 0, width: 1_888, height: 1_128)),
                               "An oversized default frame preserves a 16 point horizontal margin and fits vertically")

        let secondary = PaletteSnapGeometry(
            screenFrame: CGRect(x: 1_920, y: -1_200, width: 2_560, height: 1_200),
            visibleFrame: CGRect(x: 1_920, y: -1_200, width: 2_560, height: 1_160)
        )
        let secondaryFrame = secondary.defaultFrame(
            preferredSize: CGSize(width: 4_096, height: 4_096)
        )
        try TestSupport.expect(close(secondaryFrame, CGRect(x: 1_936, y: -1_200, width: 2_528, height: 1_128)),
                               "A clamped frame on a negative-coordinate secondary display stays in its visible area")

        let negative = PaletteSnapGeometry(
            screenFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_200),
            visibleFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_160)
        )
        let negativeFrame = negative.defaultFrame(preferredSize: CGSize(width: 640, height: 600))
        try TestSupport.expect(close(negativeFrame, CGRect(x: -1_280, y: 351.2, width: 640, height: 600)),
                               "Default placement translates to a display with a negative origin")
    }

    @MainActor
    private static func paletteSnapping() throws {
        let geometry = PaletteSnapGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_200),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_160)
        )
        let size = CGSize(width: 400, height: 300)
        let awayFromTop: CGFloat = 500
        var state = PaletteSnapGeometry.State()

        let enteredLeft = geometry.snap(
            CGRect(x: geometry.left + 8, y: awayFromTop, width: size.width, height: size.height),
            state: &state
        )
        try TestSupport.expect(close(enteredLeft.frame.minX, geometry.left),
                               "The left guide snaps at the inclusive 8 point entry threshold")
        try TestSupport.expect(enteredLeft.entered == [.left] && state.horizontal == .left,
                               "Entering the left guide is reported once and retained in state")

        let heldLeft = geometry.snap(
            CGRect(x: geometry.left + 14, y: awayFromTop, width: size.width, height: size.height),
            state: &state
        )
        try TestSupport.expect(close(heldLeft.frame.minX, geometry.left) && heldLeft.entered.isEmpty,
                               "An active horizontal guide stays attached through its 14 point hysteresis threshold")

        let releasedLeft = geometry.snap(
            CGRect(x: geometry.left + 14.125, y: awayFromTop, width: size.width, height: size.height),
            state: &state
        )
        try TestSupport.expect(close(releasedLeft.frame.minX, geometry.left + 14.125)
                                 && state.horizontal == nil && releasedLeft.entered.isEmpty,
                               "Moving beyond the hysteresis threshold releases the horizontal guide")

        let reenteredLeft = geometry.snap(
            CGRect(x: geometry.left + 7.875, y: awayFromTop, width: size.width, height: size.height),
            state: &state
        )
        try TestSupport.expect(close(reenteredLeft.frame.minX, geometry.left)
                                 && reenteredLeft.entered == [.left],
                               "The released horizontal guide re-enters within the lower threshold")

        state = .init()
        let rightTarget = geometry.right - size.width
        let enteredRight = geometry.snap(
            CGRect(x: rightTarget - 8, y: awayFromTop, width: size.width, height: size.height),
            state: &state
        )
        try TestSupport.expect(close(enteredRight.frame.minX, rightTarget)
                                 && enteredRight.entered == [.right] && state.horizontal == .right,
                               "The right guide aligns the trailing edge within the entry threshold")

        state = .init()
        let enteredTop = geometry.snap(
            CGRect(
                x: 700,
                y: geometry.top - size.height + 8,
                width: size.width,
                height: size.height
            ),
            state: &state
        )
        try TestSupport.expect(close(enteredTop.frame.maxY, geometry.top)
                                 && enteredTop.entered == [.top] && state.vertical,
                               "The top guide snaps the trailing edge at the inclusive entry threshold")

        let heldTop = geometry.snap(
            CGRect(
                x: 700,
                y: geometry.top - size.height + 14,
                width: size.width,
                height: size.height
            ),
            state: &state
        )
        try TestSupport.expect(close(heldTop.frame.maxY, geometry.top) && heldTop.entered.isEmpty,
                               "The top guide retains an active snap through its hysteresis threshold")

        let releasedTop = geometry.snap(
            CGRect(
                x: 700,
                y: geometry.top - size.height + 14.125,
                width: size.width,
                height: size.height
            ),
            state: &state
        )
        try TestSupport.expect(close(releasedTop.frame.maxY, geometry.top + 14.125)
                                 && !state.vertical && releasedTop.entered.isEmpty,
                               "The top guide releases beyond its hysteresis threshold")

        state = .init()
        let both = geometry.snap(
            CGRect(
                x: geometry.left + 4,
                y: geometry.top - size.height + 4,
                width: size.width,
                height: size.height
            ),
            state: &state
        )
        try TestSupport.expect(both.entered == [.left, .top],
                               "Independent horizontal and vertical guides can enter together")

        let centeredVisibleFrame = PaletteSnapGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_200),
            visibleFrame: CGRect(x: 600, y: 0, width: 600, height: 1_160)
        )
        for guide in [PaletteSnapGeometry.Guide.left, .right] {
            var outsideState = PaletteSnapGeometry.State(horizontal: guide, vertical: false)
            let outsideTarget = guide == .left
                ? centeredVisibleFrame.left
                : centeredVisibleFrame.right - 200
            let outside = centeredVisibleFrame.snap(
                CGRect(x: outsideTarget, y: 500, width: 200, height: 300),
                state: &outsideState
            )
            try TestSupport.expect(outsideState.horizontal == nil && outside.entered.isEmpty,
                                   "A guide outside the usable area is not reported as entered")
            try TestSupport.expect(inside(centeredVisibleFrame.visibleFrame, outside.frame),
                                   "A guide outside the usable area cannot pull the frame offscreen")
        }

        var constrainedState = PaletteSnapGeometry.State()
        let constrained = geometry.snap(
            CGRect(x: -200, y: -200, width: 300, height: 250),
            state: &constrainedState
        )
        try TestSupport.expect(close(constrained.frame, CGRect(x: 0, y: 0, width: 300, height: 250)),
                               "Snapping clamps a frame wholly outside the visible area")
    }

    @MainActor
    private static func pinnedImageSizing() throws {
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let wide = PinnedImageGeometry(
            imageSize: CGSize(width: 4_000, height: 2_000),
            visibleFrame: visible,
            preferredLongEdge: 480
        )
        try TestSupport.expect(close(wide.baseSize, CGSize(width: 480, height: 240)),
                               "A wide image fits its preferred long edge")
        try TestSupport.expect(close(wide.frame, CGRect(x: 480, y: 330, width: 480, height: 240)),
                               "A new pinned image is centered in the usable display bounds")
        try TestSupport.expect(close(wide.minimumFrameSize, CGSize(width: 320, height: 160)),
                               "A normal image retains its aspect ratio while respecting both control minima")

        let tall = PinnedImageGeometry(
            imageSize: CGSize(width: 2_000, height: 4_000),
            visibleFrame: visible,
            preferredLongEdge: 480
        )
        try TestSupport.expect(close(tall.baseSize, CGSize(width: 240, height: 480)),
                               "A tall image fits its preferred long edge")
        try TestSupport.expect(close(tall.minimumFrameSize, CGSize(width: 240, height: 480)),
                               "A tall image cannot shrink below either control minimum")

        let panorama = PinnedImageGeometry(
            imageSize: CGSize(width: 4_000, height: 1_000),
            visibleFrame: visible,
            preferredLongEdge: 480
        )
        try TestSupport.expect(close(panorama.baseSize, CGSize(width: 480, height: 160)),
                               "The height control minimum limits an extreme panorama")
        try TestSupport.expect(close(panorama.minimumFrameSize, panorama.baseSize),
                               "An aspect-ratio-limited panorama starts at its minimum frame")

        let tiny = PinnedImageGeometry(
            imageSize: CGSize(width: 20, height: 10),
            visibleFrame: visible,
            preferredLongEdge: 480
        )
        try TestSupport.expect(close(tiny.baseSize, PinnedImageGeometry.minimumSize),
                               "A tiny image is raised to the minimum control size")

        let extremeWide = PinnedImageGeometry(
            imageSize: CGSize(width: 1_000_000_000_000, height: 1),
            visibleFrame: visible,
            preferredLongEdge: 480
        )
        try TestSupport.expect(close(extremeWide.baseSize, CGSize(width: 480, height: 160)),
                               "An extreme wide image keeps a finite preferred width and the height minimum")

        let extremeTall = PinnedImageGeometry(
            imageSize: CGSize(width: 1, height: 1_000_000_000_000),
            visibleFrame: visible,
            preferredLongEdge: 480
        )
        try TestSupport.expect(close(extremeTall.baseSize, CGSize(width: 240, height: 480)),
                               "An extreme tall image keeps a finite preferred height and the width minimum")

        let displayLimited = PinnedImageGeometry(
            imageSize: CGSize(width: 10_000, height: 10_000),
            visibleFrame: visible,
            preferredLongEdge: 10_000
        )
        try TestSupport.expect(close(displayLimited.baseSize, CGSize(width: 876, height: 876)),
                               "A preferred size larger than the display is limited by the usable bounds")
    }

    @MainActor
    private static func pinnedImageInvalidInputs() throws {
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let fallback = PinnedImageGeometry(
            imageSize: CGSize(width: 1_200, height: 900),
            visibleFrame: visible,
            preferredLongEdge: 480
        )
        let invalidImageSizes: [(CGSize, CGSize)] = [
            (.zero, CGSize(width: 480, height: 360)),
            (CGSize(width: -1, height: 900), CGSize(width: 480, height: 360)),
            (CGSize(width: CGFloat.nan, height: 900), CGSize(width: 480, height: 360)),
            (CGSize(width: 1_200, height: CGFloat.infinity), CGSize(width: 480, height: 360)),
        ]
        for (imageSize, expectedSize) in invalidImageSizes {
            let geometry = PinnedImageGeometry(
                imageSize: imageSize,
                visibleFrame: visible,
                preferredLongEdge: 480
            )
            try TestSupport.expect(close(geometry.baseSize, expectedSize),
                                   "Invalid image dimensions use deterministic fallbacks per component")
        }

        for preferredLongEdge in [CGFloat.zero, -1, .nan, .infinity, -.infinity] {
            let geometry = PinnedImageGeometry(
                imageSize: CGSize(width: 1_200, height: 900),
                visibleFrame: visible,
                preferredLongEdge: preferredLongEdge
            )
            try TestSupport.expect(close(geometry.baseSize, fallback.baseSize),
                                   "Invalid preferred long edges use the deterministic fallback")
        }

        var geometry = fallback
        let beforeInvalidZoom = geometry.frame
        geometry.zoom(by: .nan, visibleFrame: visible)
        geometry.zoom(by: .infinity, visibleFrame: visible)
        try TestSupport.expect(close(geometry.frame, beforeInvalidZoom),
                               "Non-finite zoom deltas leave the frame unchanged")
    }

    @MainActor
    private static func pinnedImageZoom() throws {
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let original = PinnedImageGeometry(
            imageSize: CGSize(width: 4_000, height: 2_000),
            visibleFrame: visible,
            preferredLongEdge: 480
        )

        var reversible = original
        reversible.zoom(by: 0.25, visibleFrame: visible)
        reversible.zoom(by: -0.25, visibleFrame: visible)
        try TestSupport.expect(close(reversible.frame, original.frame),
                               "Equal opposite zoom deltas are reversible")

        var minimum = original
        minimum.zoom(by: -100, visibleFrame: visible)
        try TestSupport.expect(close(minimum.frame.size, CGSize(width: 320, height: 160)),
                               "Zoom clamps at the image minimum frame size")
        minimum.zoom(by: 0.1, visibleFrame: visible)
        let expectedMinimumReversal = exp(CGFloat(0.1))
        try TestSupport.expect(
            close(minimum.frame.size, CGSize(
                width: 320 * expectedMinimumReversal,
                height: 160 * expectedMinimumReversal
            )),
            "Reversing immediately after the lower zoom limit responds without accumulated overshoot"
        )

        var maximum = original
        maximum.zoom(by: 100, visibleFrame: visible)
        try TestSupport.expect(close(maximum.frame.size, CGSize(width: 1_416, height: 708)),
                               "Zoom clamps at the largest frame that fits the usable bounds")
        maximum.zoom(by: -0.1, visibleFrame: visible)
        let expectedMaximumReversal = exp(CGFloat(-0.1))
        try TestSupport.expect(
            close(maximum.frame.size, CGSize(
                width: 1_416 * expectedMaximumReversal,
                height: 708 * expectedMaximumReversal
            )),
            "Reversing immediately after the upper zoom limit responds without accumulated overshoot"
        )
        try TestSupport.expect(inside(visible.insetBy(dx: 12, dy: 12), maximum.frame),
                               "Zooming keeps the frame inside the usable display bounds")
    }

    @MainActor
    private static func pinnedImageAdoptionAndDisplayChanges() throws {
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        var geometry = PinnedImageGeometry(
            imageSize: CGSize(width: 4_000, height: 2_000),
            visibleFrame: visible,
            preferredLongEdge: 480
        )
        let originalFrame = geometry.frame
        let invalidFrames = [
            CGRect(x: 100, y: 100, width: 0, height: 200),
            CGRect(x: 100, y: 100, width: CGFloat.nan, height: 200),
            CGRect(x: 100, y: 100, width: CGFloat.infinity, height: 200),
            CGRect(x: 100, y: 100, width: 400, height: CGFloat.infinity),
        ]
        for frame in invalidFrames {
            geometry.adopt(frame)
            try TestSupport.expect(close(geometry.frame, originalFrame),
                                   "Adopting a frame with invalid dimensions leaves geometry unchanged")
        }

        let resized = CGRect(x: 400, y: 200, width: 800, height: 400)
        geometry.adopt(resized)
        try TestSupport.expect(close(geometry.frame, resized),
                               "Adopting a valid frame updates both scale and center")

        var moved = geometry
        moved.fit(visibleFrame: visible, movedCenter: CGPoint(x: -500, y: 10_000))
        try TestSupport.expect(close(moved.frame, CGRect(x: 12, y: 488, width: 800, height: 400)),
                               "Fit clamps an externally moved center into the current display")

        let secondaryVisible = CGRect(x: -800, y: -600, width: 800, height: 600)
        var displayChange = PinnedImageGeometry(
            imageSize: CGSize(width: 4_000, height: 2_000),
            visibleFrame: visible,
            preferredLongEdge: 480
        )
        displayChange.zoom(by: 100, visibleFrame: visible)
        displayChange.fit(visibleFrame: secondaryVisible)
        let secondaryBounds = secondaryVisible.insetBy(dx: 12, dy: 12)
        try TestSupport.expect(close(displayChange.frame.size, CGSize(width: 776, height: 388)),
                               "A display change limits the previous zoom to the new usable width")
        try TestSupport.expect(inside(secondaryBounds, displayChange.frame),
                               "A display change repositions a pinned image into the new negative-coordinate display")
        try TestSupport.expect(close(displayChange.frame.midY, secondaryBounds.maxY - 194),
                               "A display change preserves the requested side when the new height allows it")
    }

    private static func close(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 0.000_001
    ) -> Bool {
        close(lhs.minX, rhs.minX, tolerance: tolerance)
            && close(lhs.minY, rhs.minY, tolerance: tolerance)
            && close(lhs.width, rhs.width, tolerance: tolerance)
            && close(lhs.height, rhs.height, tolerance: tolerance)
    }

    private static func close(
        _ lhs: CGSize,
        _ rhs: CGSize,
        tolerance: CGFloat = 0.000_001
    ) -> Bool {
        close(lhs.width, rhs.width, tolerance: tolerance)
            && close(lhs.height, rhs.height, tolerance: tolerance)
    }

    private static func close(
        _ lhs: CGFloat,
        _ rhs: CGFloat,
        tolerance: CGFloat = 0.000_001
    ) -> Bool {
        lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= tolerance
    }

    private static func inside(
        _ bounds: CGRect,
        _ frame: CGRect,
        tolerance: CGFloat = 0.000_001
    ) -> Bool {
        frame.minX >= bounds.minX - tolerance
            && frame.maxX <= bounds.maxX + tolerance
            && frame.minY >= bounds.minY - tolerance
            && frame.maxY <= bounds.maxY + tolerance
    }
}
