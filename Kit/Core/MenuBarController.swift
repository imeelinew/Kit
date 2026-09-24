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
    private var spinTimer: Timer?
    private var spinningImage: NSImage?
    private var spinStartedAt: CFTimeInterval = 0
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
        guard spinTimer == nil, let button = statusItem?.button, let image = button.image else {
            return
        }
        spinningImage = image
        spinStartedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self,
                          selector: #selector(advanceSpin(_:)), userInfo: nil, repeats: true)
        spinTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func advanceSpin(_ timer: Timer) {
        guard let button = statusItem?.button, let image = spinningImage else {
            timer.invalidate()
            spinTimer = nil
            spinningImage = nil
            return
        }
        let progress = min((CACurrentMediaTime() - spinStartedAt) / 0.35, 1)
        if progress >= 1 {
            button.image = image
            timer.invalidate()
            spinTimer = nil
            spinningImage = nil
            return
        }
        let eased = 1 - pow(1 - progress, 3)
        button.image = MenuBarIcon.rotatedImage(image, degrees: -360 * eased)
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
        button.image = MenuBarIcon.symbolImage
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
        spinTimer?.invalidate()
        spinTimer = nil
        spinningImage = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func applyLocalizedChrome() {
        let title = AppLocalization.string("Kit", locale: settings.language.locale)
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
            title: AppLocalization.string("About Kit", locale: locale),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let settingsItem = NSMenuItem(
            title: AppLocalization.string("Settings…", locale: locale),
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
                title: AppLocalization.string("Resume Kit", locale: locale),
                action: #selector(resumeClipboard),
                keyEquivalent: ""
            )
            resumeItem.target = self
            menu.addItem(resumeItem)
        } else {
            let pauseItem = NSMenuItem(
                title: AppLocalization.string("Pause Kit", locale: locale),
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
            title: AppLocalization.string("Quit Kit…", locale: locale),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    private func pauseOption(
        _ title: String, duration: TimeInterval?, locale: Locale
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: AppLocalization.string(title, locale: locale),
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

/// Keep every animation frame in the status button's image canvas so its placement never changes.
private enum MenuBarIcon {
    private static let verticalOffset: CGFloat = 0.5

    static func rotatedImage(_ image: NSImage, degrees: Double) -> NSImage {
        let rotated = NSImage(size: image.size, flipped: false) { bounds in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.midX, yBy: bounds.midY + Self.verticalOffset)
            transform.rotate(byDegrees: degrees)
            transform.translateX(by: -bounds.midX, yBy: -bounds.midY - Self.verticalOffset)
            transform.concat()
            image.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        rotated.isTemplate = true
        return rotated
    }

    static var symbolImage: NSImage {
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
        let side = max(symbol.size.width, symbol.size.height)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            let symbolRect = NSRect(
                x: (bounds.width - symbol.size.width) / 2,
                y: (bounds.height - symbol.size.height) / 2 + Self.verticalOffset,
                width: symbol.size.width,
                height: symbol.size.height
            )
            symbol.draw(in: symbolRect)
            return true
        }
        image.isTemplate = true
        return image
    }
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
