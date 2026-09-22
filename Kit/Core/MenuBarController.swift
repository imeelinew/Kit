import AppKit
import AVFoundation
import Combine
import QuartzCore

/// Menu bar status item: `arrow.trianglehead.clockwise` template icon, left-click toggles the palette,
/// right-click offers About, Settings, and Quit. Spins clockwise on new clipboard inserts.
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
        guard let button = statusItem?.button, let image = button.image else { return }
        let rect = (button.cell as? NSButtonCell)?.imageRect(forBounds: button.bounds)
            ?? NSRect(
                x: (button.bounds.width - image.size.width) / 2,
                y: (button.bounds.height - image.size.height) / 2,
                width: image.size.width,
                height: image.size.height
            )
        let spinner = MenuBarIconView(symbol: image)
        spinner.frame = rect
        button.image = nil
        button.addSubview(spinner)
        iconView = spinner
        spinner.spin { [weak self, weak button, weak spinner] in
            spinner?.removeFromSuperview()
            button?.image = image
            button?.imagePosition = .imageOnly
            button?.imageScaling = .scaleNone
            self?.iconView = nil
        }
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }
        button.image = MenuBarIconView.symbolImage
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item
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

        let aboutItem = NSMenuItem(
            title: String(localized: "About Paste", locale: locale),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let settingsItem = NSMenuItem(
            title: String(localized: "Settings…", locale: locale),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        if #available(macOS 27.0, *) {
            settingsItem.preferredImageVisibility = .hidden
        }
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

    @objc private func showAbout() {
        AppCore.shared.showAbout()
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

    init(symbol: NSImage) {
        super.init(frame: .zero)
        wantsLayer = true
        imageView.wantsLayer = true
        imageView.imageScaling = .scaleNone
        imageView.image = symbol
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
        let size = imageView.image?.size ?? .zero
        imageView.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        centerAnchor()
    }

    func spin(completion: @escaping () -> Void) {
        imageView.wantsLayer = true
        centerAnchor()
        guard let layer = imageView.layer else {
            completion()
            return
        }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = -Double.pi * 2
        animation.duration = 0.35
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(animation, forKey: "spin")
        CATransaction.commit()
    }

    private func centerAnchor() {
        guard let layer = imageView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY)
        CATransaction.commit()
    }

    fileprivate static var symbolImage: NSImage {
        guard
            let base = NSImage(
                systemSymbolName: "arrow.trianglehead.clockwise",
                accessibilityDescription: nil
            )
        else { return NSImage() }
        let configuration = NSImage.SymbolConfiguration(
            pointSize: base.size.height * 0.85,
            weight: .medium
        )
        let symbol = base.withSymbolConfiguration(configuration) ?? base
        let image = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            return true
        }
        image.isTemplate = true
        return image
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
