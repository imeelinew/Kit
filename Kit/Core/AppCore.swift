import AppKit
import KeyboardShortcuts

@MainActor
final class AppCore {
    static let shared = AppCore()

    let settings = AppSettings()
    let updateService = UpdateService()
    let clipboardStore = ClipboardStore()
    let clipboardManager: ClipboardManager
    lazy var palette = PaletteViewModel(core: self)
    let systemClipboardHistory = SystemClipboardHistory()
    private(set) var isClipboardPaused = false

    private lazy var windowController = PaletteWindowController(core: self)
    private let activationPolicy = ActivationPolicyCoordinator()
    private lazy var pinnedImageWindows = PinnedImageWindowController()
    private lazy var settingsWindowController = KitSettingsWindowController(
        activationPolicy: activationPolicy
    )
    private lazy var menuBarController = MenuBarController(settings: settings)
    private let copySoundPlayer = CopySoundPlayer()
    private var transferTask: Task<Void, Never>?
    private var transferGeneration = UUID()
    private var clipboardResumeTask: Task<Void, Never>?
    private var clipboardShortcutIsDown = false

    private init() {
        clipboardManager = ClipboardManager(store: clipboardStore, settings: settings)
    }

    func start() {
        NerdSymbolsFont.register()
        activationPolicy.reset()
        settings.appearance.apply()
        updateService.start()
        clipboardStore.maxAge = settings.clipboardRetention.maxAge
        clipboardStore.load()
        clipboardStore.onItemInserted = { [weak self] in
            self?.handleClipboardItemInserted()
        }
        clipboardManager.start()
        let savedPause = settings.savedClipboardPause
        if savedPause.isPaused {
            if let until = savedPause.until, until <= Date() {
                settings.clearClipboardPause()
            } else {
                pauseClipboard(until: savedPause.until)
            }
        }
        menuBarController.start()
        windowController.prewarm()

        KeyboardShortcuts.onKeyDown(for: .toggleClipboard) { [weak self] in
            guard let self, !clipboardShortcutIsDown else { return }
            clipboardShortcutIsDown = true
            togglePalette()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleClipboard) { [weak self] in
            self?.clipboardShortcutIsDown = false
        }
    }

    func togglePalette() {
        if windowController.isVisible || windowController.isPresenting {
            hidePalette()
        } else {
            showPalette()
        }
    }

    func showPalette() {
        windowController.show()
    }

    func hidePalette(restoreFocus: Bool = true, cancelTransfer: Bool = true) {
        if cancelTransfer {
            transferTask?.cancel()
            transferTask = nil
            transferGeneration = UUID()
        }
        palette.imageQuickLookOpen = false
        ImageQuickLook.close()
        windowController.hide(restoreFocus: restoreFocus)
    }

    func handleReopen() {
        if settingsWindowController.isVisible {
            settingsWindowController.focus()
            return
        }
        showPalette()
    }

    func showSettings(tab: SettingsTab = .general) {
        settingsWindowController.show(tab: tab)
    }

    func showAbout() {
        showSettings(tab: .about)
    }

    func pauseClipboard(until date: Date?) {
        clipboardResumeTask?.cancel()
        isClipboardPaused = true
        settings.saveClipboardPause(until: date)
        clipboardManager.setPaused(true)

        guard let date else { return }
        clipboardResumeTask = Task { [weak self] in
            let interval = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.resumeClipboard()
        }
    }

    func resumeClipboard() {
        clipboardResumeTask?.cancel()
        clipboardResumeTask = nil
        isClipboardPaused = false
        settings.clearClipboardPause()
        clipboardManager.setPaused(false)
    }

    func previewCopySound() {
        guard settings.soundEffectsEnabled else { return }
        copySoundPlayer.play(settings.copySoundEffect)
    }

    func checkForUpdates() {
        updateService.checkForUpdates()
    }

    func runModalAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        windowController.runModalAlert(alert)
    }

    func requestQuit() {
        let locale = settings.language.locale
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppLocalization.string("Quit Kit?", locale: locale)
        alert.informativeText = AppLocalization.string(
            "Kit will stop monitoring the clipboard until you open it again.", locale: locale)
        alert.addButton(withTitle: AppLocalization.string("Quit", locale: locale))
        alert.addButton(withTitle: AppLocalization.string("Cancel", locale: locale))
        alert.buttons.first?.hasDestructiveAction = true

        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    func paste(_ item: ClipboardItem) {
        guard let previous = windowController.pasteTargetApp else { return }
        startHidingTransfer(item) { [clipboardStore] willDeliver in
            await Paster.paste(
                item, store: clipboardStore, previousApp: previous, willDeliver: willDeliver)
        }
    }

    var hasPasteTarget: Bool { windowController.pasteTargetApp != nil }

    func pasteKeepingWindowOpen(_ item: ClipboardItem) {
        guard let previous = windowController.pasteTargetApp else { return }
        startTransfer { [weak self] generation in
            guard let self else { return }
            if await Paster.pasteInPlace(item, store: self.clipboardStore, into: previous) {
                self.palette.select(item.id)
            }
            self.finishTransfer(generation)
        }
    }

    func copyToClipboard(_ item: ClipboardItem) {
        startHidingTransfer(item) { [clipboardStore] willWrite in
            await Paster.copy(item, store: clipboardStore, willWrite: willWrite)
        }
    }

    private func startHidingTransfer(
        _ item: ClipboardItem,
        operation: @escaping @MainActor (_ willHide: () -> Void) async -> Bool
    ) {
        startTransfer { [weak self] generation in
            guard let self else { return }
            var hidden = false
            let succeeded = await operation {
                hidden = true
                self.hidePalette(restoreFocus: false, cancelTransfer: false)
            }
            guard !Task.isCancelled else {
                if hidden { self.windowController.show() }
                return
            }
            if succeeded {
                self.palette.select(item.id)
            } else if hidden {
                self.windowController.show()
            }
            self.finishTransfer(generation)
        }
    }

    func revealClipboardItem(_ item: ClipboardItem, dismissPalette: Bool = true) {
        let url: URL
        switch item.kind {
        case .image:
            guard let imageURL = clipboardStore.imageURL(for: item) else { return }
            url = imageURL
        case .path:
            guard let text = item.text, let pathURL = ClipboardTextClassifier.fileURL(for: text)
            else { return }
            url = pathURL
        default:
            return
        }
        if dismissPalette { hidePalette(restoreFocus: false) }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            _ = NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func pinToScreen(_ item: ClipboardItem, dismissPalette: Bool = true) {
        guard item.kind == .image, let url = clipboardStore.imageURL(for: item) else { return }
        let title = item.displayTitle(locale: settings.language.locale)
        if dismissPalette { hidePalette() }
        pinnedImageWindows.show(
            itemID: item.id,
            url: url,
            title: title,
            preferredLongEdge: { [weak settings] in
                settings?.pinnedImageSize.longestEdge ?? PinnedImageSize.medium.longestEdge
            }
        )
    }

    private func handleClipboardItemInserted() {
        if settings.soundEffectsEnabled {
            copySoundPlayer.play(settings.copySoundEffect)
        }
        if settings.showMenuBarIcon && settings.animateMenuBarIconOnCopy {
            menuBarController.spin()
        }
    }

    private func startTransfer(
        _ operation: @escaping @MainActor (_ generation: UUID) async -> Void
    ) {
        transferTask?.cancel()
        let generation = UUID()
        transferGeneration = generation
        transferTask = Task { await operation(generation) }
    }

    private func finishTransfer(_ generation: UUID) {
        guard transferGeneration == generation else { return }
        transferTask = nil
    }
}
