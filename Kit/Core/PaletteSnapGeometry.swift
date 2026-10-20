import CoreGraphics
import Foundation

struct PaletteSnapGeometry {
    enum Guide: Hashable { case left, right, top }

    struct State {
        var horizontal: Guide?
        var vertical = false
    }

    struct Result {
        let frame: CGRect
        let entered: Set<Guide>
    }

    let screenFrame: CGRect
    let visibleFrame: CGRect

    // Vertical guides follow the reference recording, the top guide follows the original placement
    var left: CGFloat { screenFrame.minX + screenFrame.width * 0.28 }
    var right: CGFloat { screenFrame.minX + screenFrame.width * 0.72 }
    var top: CGFloat { visibleFrame.maxY - visibleFrame.height * 0.18 }

    func defaultFrame(preferredSize: CGSize) -> CGRect {
        let width = min(preferredSize.width, max(1, visibleFrame.width - 32))
        let height = min(preferredSize.height, max(1, visibleFrame.height - 32))
        return constrained(CGRect(
            x: visibleFrame.midX - width / 2, y: top - height,
            width: width, height: height))
    }

    func snap(_ proposed: CGRect, state: inout State) -> Result {
        var frame = constrained(proposed)
        let previous = state
        let targets: [(Guide, CGFloat)] = [(.left, left), (.right, right - frame.width)]
        if let active = state.horizontal,
            let target = targets.first(where: { $0.0 == active }),
            abs(frame.minX - target.1) <= 14
        {
            frame.origin.x = target.1
        } else if let nearest = targets.min(by: {
            abs(frame.minX - $0.1) < abs(frame.minX - $1.1)
        }), abs(frame.minX - nearest.1) <= 8 {
            state.horizontal = nearest.0
            frame.origin.x = nearest.1
        } else {
            state.horizontal = nil
        }

        let verticalDistance = abs(frame.maxY - top)
        state.vertical = verticalDistance <= (state.vertical ? 14 : 8)
        if state.vertical { frame.origin.y = top - frame.height }

        // A guide outside the usable area must never pull the window offscreen
        frame = constrained(frame)
        if let horizontal = state.horizontal,
            let target = targets.first(where: { $0.0 == horizontal }),
            abs(frame.minX - target.1) > 0.5
        {
            state.horizontal = nil
        }
        if abs(frame.maxY - top) > 0.5 { state.vertical = false }

        var entered: Set<Guide> = []
        if let horizontal = state.horizontal, horizontal != previous.horizontal {
            entered.insert(horizontal)
        }
        if state.vertical && !previous.vertical { entered.insert(.top) }
        return Result(frame: frame, entered: entered)
    }

    private func constrained(_ proposed: CGRect) -> CGRect {
        var frame = proposed
        frame.size.width = min(frame.width, visibleFrame.width)
        frame.size.height = min(frame.height, visibleFrame.height)
        frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        return frame
    }
}
