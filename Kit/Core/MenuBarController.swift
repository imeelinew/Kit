import AppKit
import AVFoundation
import Combine
import QuartzCore

/// Menu bar status item: `arrow.trianglehead.clockwise` template icon, left-click toggles the palette,
/// right-click offers About, Settings, clipboard monitoring pause, and Quit. Spins clockwise on new clipboard inserts.
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
        guard iconView == nil, let button = statusItem?.button, let image = button.image else {
            return
        }
        let cellRect = (button.cell as? NSButtonCell)?.imageRect(forBounds: button.bounds)
        let rect = cellRect.flatMap { $0.isEmpty ? nil : $0 }
            ?? NSRect(
                x: (button.bounds.width - image.size.width) / 2,
                y: (button.bounds.height - image.size.height) / 2,
                width: image.size.width,
                height: image.size.height
            )
        let spinner = MenuBarIconView(symbol: image)
        spinner.frame = rect
        // Keep the variable-length status item at its original width while its icon spins.
        button.image = NSImage(size: image.size, flipped: false) { _ in true }
        button.addSubview(spinner)
        iconView = spinner
        spinner.spin { [weak self, weak button, weak spinner] in
            guard let self, let button, let spinner,
                self.statusItem?.button === button, self.iconView === spinner
            else { return }
            spinner.removeFromSuperview()
            button.image = image
            self.iconView = nil
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

        if AppCore.shared.isClipboardPaused {
            let resumeItem = NSMenuItem(
                title: String(localized: "Resume Paste", locale: locale),
                action: #selector(resumeClipboard),
                keyEquivalent: ""
            )
            resumeItem.target = self
            menu.addItem(resumeItem)
        } else {
            let pauseItem = NSMenuItem(
                title: String(localized: "Pause Paste", locale: locale),
                action: nil,
                keyEquivalent: ""
            )
            let pauseMenu = NSMenu()
            pauseMenu.addItem(pauseOption("Pause", duration: nil, locale: locale))
            pauseMenu.addItem(.separator())
            pauseMenu.addItem(pauseOption("For 15 Minutes", duration: 15 * 60, locale: locale))
            pauseMenu.addItem(pauseOption("For 30 Minutes", duration: 30 * 60, locale: locale))
            pauseMenu.addItem(pauseOption("For 1 Hour", duration: 60 * 60, locale: locale))
            pauseMenu.addItem(pauseOption("For 3 Hours", duration: 3 * 60 * 60, locale: locale))
            pauseMenu.addItem(pauseOption("For 8 Hours", duration: 8 * 60 * 60, locale: locale))
            pauseItem.submenu = pauseMenu
            menu.addItem(pauseItem)
        }

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

    private func pauseOption(
        _ title: String.LocalizationValue, duration: TimeInterval?, locale: Locale
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: title, locale: locale),
            action: #selector(pauseClipboard(_:)),
            keyEquivalent: ""
        )
        item.target = self
        if let duration { item.representedObject = NSNumber(value: duration) }
        return item
    }

    @objc private func pauseClipboard(_ sender: NSMenuItem) {
        let duration = (sender.representedObject as? NSNumber)?.doubleValue
        AppCore.shared.pauseClipboard(until: duration.map { Date().addingTimeInterval($0) })
    }

    @objc private func resumeClipboard() {
        AppCore.shared.resumeClipboard()
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
        imageView.frame = NSRect(origin: .zero, size: symbol.size)
        addSubview(imageView)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
    }

    func spin(completion: @escaping () -> Void) {
        layoutSubtreeIfNeeded()
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
