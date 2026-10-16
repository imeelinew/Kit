import AppKit

/// Run with scripts/test-pinned-images.sh. Exercises the production geometry,
/// without launching Kit or touching clipboard history/preferences.
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
            CGSize(width: 1_200, height: 900), CGSize(width: 1, height: 1),
            CGSize(width: 100_000, height: 1), CGSize(width: 1, height: 100_000),
            CGSize(width: 0, height: -1), CGSize(width: CGFloat.nan, height: CGFloat.infinity),
        ]
        for image in images {
            var card = PinnedImageGeometry(
                imageSize: image, visibleFrame: desktop, preferredLongEdge: 480
            )
            checkBounds(card.frame, in: desktop)
            let initial = card.frame
            for _ in 0..<8 {
                card.zoom(by: 0.02, visibleFrame: desktop)
                card.zoom(by: -0.02, visibleFrame: desktop)
            }
            expect(near(card.frame.width, initial.width), "No accumulated size error")
            card.zoom(by: -1_000, visibleFrame: desktop)
            checkBounds(card.frame, in: desktop)
            let small = card.frame
            card.zoom(by: 0.01, visibleFrame: desktop)
            expect(card.frame.width > small.width, "Immediate reversal from minimum")
            card.zoom(by: 1_000, visibleFrame: desktop)
            checkBounds(card.frame, in: desktop)
        }

        // Every corner, including on a screen to the left/below the primary screen.
        for display in [
            desktop, CGRect(x: -1_920, y: -400, width: 1_920, height: 1_080),
            CGRect(x: 20, y: 20, width: 180, height: 100),
        ] {
            for x in [display.minX, display.maxX] {
                for y in [display.minY, display.maxY] {
                    var card = PinnedImageGeometry(
                        imageSize: CGSize(width: 1_200, height: 900),
                        visibleFrame: desktop, preferredLongEdge: 480
                    )
                    card.fit(visibleFrame: display, movedCenter: CGPoint(x: x, y: y))
                    checkBounds(card.frame, in: display, minimum: display.width > 240)
                }
            }
        }
        print("PASS: initial fit, extreme ratios, minimum size, zoom limits, multi-display clamping")
    }

    static func main() {
        geometryTests()
    }
}
