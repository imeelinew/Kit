import AppKit
import QuartzCore

@MainActor
final class PaletteWindowDrag {
    private weak var window: NSWindow?
    private let initialFrame: CGRect
    private let initialPointer: CGPoint
    private var screen: NSScreen?
    private var snapState = PaletteSnapGeometry.State()
    private var guides: PaletteSnapGuides?
    private var isDragging = false

    init(window: NSWindow, pointer: CGPoint) {
        self.window = window
        initialFrame = window.frame
        initialPointer = pointer
    }

    func update(pointer: CGPoint) {
        guard let window else { return }
        let delta = CGPoint(x: pointer.x - initialPointer.x, y: pointer.y - initialPointer.y)
        guard isDragging || hypot(delta.x, delta.y) >= 3 else { return }
        isDragging = true
        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? window.screen
        else { return }
        let geometry = PaletteSnapGeometry(
            screenFrame: targetScreen.frame, visibleFrame: targetScreen.visibleFrame)
        if screen !== targetScreen {
            guides?.dismiss()
            guides = PaletteSnapGuides(geometry: geometry, below: window)
            screen = targetScreen
            snapState = .init()
        }
        let proposed = initialFrame.offsetBy(dx: delta.x, dy: delta.y)
        let result = geometry.snap(proposed, state: &snapState)
        window.setFrame(result.frame, display: false)
        if !result.entered.isEmpty {
            guides?.pulse(result.entered)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func end() {
        guides?.dismiss()
        guides = nil
        screen = nil
    }
}

@MainActor
private final class PaletteSnapGuides {
    private let panel: NSPanel
    private var lines: [PaletteSnapGeometry.Guide: CAShapeLayer] = [:]
    private let neutral = NSColor.gray.withAlphaComponent(0.55).cgColor

    init(geometry: PaletteSnapGeometry, below window: NSWindow) {
        panel = NSPanel(
            contentRect: geometry.screenFrame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = window.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: geometry.screenFrame.size))
        view.wantsLayer = true
        panel.contentView = view

        for guide in [PaletteSnapGeometry.Guide.left, .right, .top] {
            let path = CGMutablePath()
            switch guide {
            case .left, .right:
                let x = (guide == .left ? geometry.left : geometry.right) - geometry.screenFrame.minX
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: geometry.screenFrame.height))
            case .top:
                let y = geometry.top - geometry.screenFrame.minY
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: geometry.screenFrame.width, y: y))
            }
            let line = CAShapeLayer()
            line.path = path
            line.fillColor = nil
            line.strokeColor = neutral
            line.lineWidth = 2
            line.lineDashPattern = [8, 12]
            line.contentsScale = window.backingScaleFactor
            view.layer?.addSublayer(line)
            lines[guide] = line
        }
        panel.order(.below, relativeTo: window.windowNumber)
    }

    func pulse(_ entered: Set<PaletteSnapGeometry.Guide>) {
        var flashing = entered
        if !entered.isDisjoint(with: [.left, .right]) {
            flashing.formUnion([.left, .right])
        }
        for guide in flashing {
            let animation = CAKeyframeAnimation(keyPath: "strokeColor")
            animation.values = [neutral, NSColor.systemBlue.cgColor, neutral]
            animation.keyTimes = [0, 0.15, 1]
            animation.duration = 0.32
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut),
            ]
            lines[guide]?.add(animation, forKey: "snap")
        }
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}
