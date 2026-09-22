import AppKit
import AVFoundation
import Combine
import QuartzCore

/// Menu bar status item: `arrow.clockwise` template icon, left-click toggles the palette,
/// right-click offers Show Paste / Settings / Quit. Spins clockwise on new clipboard inserts.
@MainActor
final class MenuBarController: NSObject {
    private let settings: AppSettings
    private var statusItem: NSStatusItem?
    private var iconView: MenuBarIconView?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        settings.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] show in
                self?.setVisible(show)
            }
            .store(in: &cancellables)
        settings.$language
            .sink { [weak self] _ in
                self?.applyLocalizedChrome()
            }
            .store(in: &cancellables)
    }

    func start() {
        setVisible(settings.showMenuBarIcon)
    }

    func spin() {
        iconView?.spin()
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            installIfNeeded()
        } else {
            remove()
        }
    }

    private func installIfNeeded() {
        if statusItem != nil { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }
        button.image = nil
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let icon = MenuBarIconView(frame: button.bounds)
        icon.autoresizingMask = [.width, .height]
        button.addSubview(icon)

        statusItem = item
        iconView = icon
        applyLocalizedChrome()
    }

    private func remove() {
        guard let statusItem else { return }
        iconView?.removeFromSuperview()
        iconView = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func applyLocalizedChrome() {
        let title = String(localized: "Paste", locale: settings.language.locale)
        statusItem?.button?.setAccessibilityLabel(title)
        statusItem?.button?.toolTip = title
    }

    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            AppCore.shared.togglePalette()
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .rightMouseUp || modifiers.contains(.control) {
            popMenu(event)
        } else {
            AppCore.shared.togglePalette()
        }
    }

    private func popMenu(_ event: NSEvent) {
        guard let button = statusItem?.button else { return }
        let locale = settings.language.locale
        let menu = NSMenu()

        let showItem = NSMenuItem(
            title: String(localized: "Show Paste", locale: locale),
            action: #selector(showPaste),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(
            title: String(localized: "Settings", locale: locale),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "Quit Paste", locale: locale),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func showPaste() {
        AppCore.shared.showPalette()
    }

    @objc private func openSettings() {
        AppCore.shared.showSettings()
    }

    @objc private func quit() {
        AppCore.shared.requestQuit()
    }
}

/// Template SF Symbol that rotates independently of the status button highlight.
private final class MenuBarIconView: NSView {
    private let imageView = PassthroughImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageView.wantsLayer = true
        imageView.imageScaling = .scaleProportionallyDown
        imageView.image = Self.symbolImage
        imageView.contentTintColor = .labelColor
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        imageView.contentTintColor = .labelColor
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        centerAnchor()
    }

    func spin() {
        imageView.wantsLayer = true
        centerAnchor()
        guard let layer = imageView.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = -Double.pi * 2
        animation.duration = 0.35
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "spin")
    }

    private func centerAnchor() {
        guard let layer = imageView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY)
        CATransaction.commit()
    }

    private static var symbolImage: NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image =
            NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
            ?? NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        image?.isTemplate = true
        return image ?? NSImage()
    }
}

private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Plays the four bundled copy-feedback MP3s. Keeps the player alive for the clip duration.
@MainActor
final class CopySoundPlayer {
    private var player: AVAudioPlayer?

    func play(_ effect: CopySoundEffect) {
        guard let url = Bundle.main.url(forResource: effect.resourceName, withExtension: "mp3")
        else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.volume = 0.85
            player.play()
            self.player = player
        } catch {
            self.player = nil
        }
    }
}
