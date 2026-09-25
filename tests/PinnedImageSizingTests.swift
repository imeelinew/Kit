import AppKit
import SwiftUI

/// Run with scripts/test-pinned-images.sh. Exercises the production geometry and real NSPanel
/// with an NSHostingView, without launching Kit or touching clipboard history/preferences.
@main
struct PinnedImageSizingTests {
    static let desktop = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func near(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.000_001) -> Bool {
        abs(a - b) <= tolerance
    }

    static func checkBounds(_ frame: CGRect, in display: CGRect, minimum: Bool = true) {
        expect(frame.width.isFinite && frame.height.isFinite, "Finite size")
        expect(frame.width > 0 && frame.height > 0, "Positive size")
        expect(display.insetBy(dx: -0.001, dy: -0.001).contains(frame), "Card stays on display")
        if minimum {
            expect(frame.width >= 240 - 0.001 && frame.height >= 160 - 0.001, "Usable minimum")
        }
    }

    static func geometryTests() {
        let images = [
            CGSize(width: 1_200, height: 900), CGSize(width: 900, height: 1_200),
            CGSize(width: 1, height: 1), CGSize(width: 100_000, height: 1),
            CGSize(width: 1, height: 100_000), CGSize(width: 0, height: -1),
            CGSize(width: CGFloat.nan, height: CGFloat.infinity),
        ]
        for image in images {
            for preference: CGFloat in [360, 480, 640] {
                var card = PinnedImageGeometry(
                    imageSize: image, visibleFrame: desktop, preferredLongEdge: preference
                )
                checkBounds(card.frame, in: desktop)
                let center = card.center
                card.zoom(by: -1_000, visibleFrame: desktop)
                checkBounds(card.frame, in: desktop)
                let small = card.frame
                card.zoom(by: 0.01, visibleFrame: desktop)
                expect(card.frame.width > small.width, "Immediate reversal from minimum")
                card.zoom(by: 1_000, visibleFrame: desktop)
                checkBounds(card.frame, in: desktop)
                let large = card.frame
                card.zoom(by: -0.01, visibleFrame: desktop)
                expect(card.frame.width < large.width, "Immediate reversal from maximum")
                expect(card.center == center, "Limits never move the center")
                card.reset(visibleFrame: desktop)
                let reset = card.frame
                for _ in 0..<2_000 {
                    card.zoom(by: 0.02, visibleFrame: desktop)
                    card.zoom(by: -0.02, visibleFrame: desktop)
                }
                expect(near(card.frame.width, reset.width), "No accumulated size error")
                expect(card.center == center, "No accumulated position error")
                for delta: CGFloat in [.nan, .infinity, -.infinity] {
                    let before = card.frame
                    card.zoom(by: delta, visibleFrame: desktop)
                    expect(card.frame == before, "Invalid gesture ignored")
                }
            }
        }

        // Every corner, including on a screen to the left/below the primary screen.
        for display in [desktop, CGRect(x: -1_920, y: -400, width: 1_920, height: 1_080)] {
            for x in [display.minX, display.maxX] {
                for y in [display.minY, display.maxY] {
                    var card = PinnedImageGeometry(
                        imageSize: CGSize(width: 1_200, height: 900),
                        visibleFrame: desktop, preferredLongEdge: 480
                    )
                    card.fit(visibleFrame: display, movedCenter: CGPoint(x: x, y: y))
                    let center = card.center
                    let size = card.frame.size
                    for _ in 0..<1_000 {
                        card.zoom(by: 1, visibleFrame: display)
                        card.zoom(by: -1, visibleFrame: display)
                        checkBounds(card.frame, in: display)
                        expect(card.center == center, "No drift at corner")
                    }
                    card.reset(visibleFrame: display)
                    expect(near(card.frame.width, size.width), "Reset at corner")
                }
            }
        }

        var card = PinnedImageGeometry(
            imageSize: CGSize(width: 900, height: 1_200),
            visibleFrame: desktop, preferredLongEdge: 640
        )
        for display in [
            CGRect(x: -800, y: -600, width: 800, height: 600),
            CGRect(x: 20, y: 20, width: 180, height: 100), desktop,
        ] {
            card.fit(visibleFrame: display)
            checkBounds(card.frame, in: display, minimum: display.width > 240)
        }
        print(
            "PASS: geometry, extreme ratios, 42,000 round trips, limits, corners, display changes")
    }

    @MainActor
    static func panelTests() {
        _ = NSApplication.shared
        let visible = NSScreen.main!.visibleFrame
        let geometry = PinnedImageGeometry(
            imageSize: CGSize(width: 1_200, height: 900),
            visibleFrame: visible, preferredLongEdge: 480
        )
        let panel = PinnedImagePanel(
            contentRect: geometry.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.geometry = geometry
        let hosting = NSHostingView(
            rootView: Color.blue.frame(maxWidth: .infinity, maxHeight: .infinity))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.fitToScreen()
        let original = panel.frame
        for _ in 0..<500 {
            panel.zoom(by: 0.1)
            panel.zoom(by: -0.1)
        }
        expect(near(panel.frame.midX, original.midX, tolerance: 1), "AppKit center X stable")
        expect(near(panel.frame.midY, original.midY, tolerance: 1), "AppKit center Y stable")
        expect(near(panel.frame.width, original.width, tolerance: 1), "AppKit size stable")
        panel.zoom(by: -1_000)
        checkBounds(panel.frame, in: visible)
        panel.zoom(by: 1_000)
        checkBounds(panel.frame, in: visible)
        expect(
            near(hosting.frame.width, panel.frame.width, tolerance: 1), "Hosting width follows zoom"
        )
        expect(
            near(hosting.frame.height, panel.frame.height, tolerance: 1),
            "Hosting height follows zoom")
        panel.resetSize()

        // Window Server can move a panel without a mouseUp delivered to the drag view.
        panel.setFrameOrigin(CGPoint(x: visible.minX + 80, y: visible.minY + 80))
        let moved = panel.frame
        panel.zoom(by: -0.1)
        expect(near(panel.frame.midX, moved.midX, tolerance: 1), "Adopt dragged X before zoom")
        expect(near(panel.frame.midY, moved.midY, tolerance: 1), "Adopt dragged Y before zoom")
        panel.resetSize()
        expect(
            near(panel.frame.width, geometry.baseSize.width, tolerance: 1), "Restore initial size")
        expect(!panel.styleMask.contains(.resizable), "Native resizing cannot bypass geometry")
        panel.close()
        print("PASS: real NSPanel + NSHostingView, 500 round trips, drag then zoom, reset")
    }

    @MainActor
    static func main() {
        geometryTests()
        panelTests()
    }
}
