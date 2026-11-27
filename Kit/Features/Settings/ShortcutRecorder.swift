import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleClipboard = Self(
        "toggleClipboard",
        default: .init(.w, modifiers: [.option])
    )
}

extension Notification.Name {
    static let paletteShortcutDidChange = Self("Kit.paletteShortcutDidChange")
}

/// Palette-local shortcuts stored in UserDefaults without registering global Carbon hotkeys.
enum PaletteShortcut: String, CaseIterable {
    case actions = "paletteActions"
    case copyToClipboard = "paletteCopyToClipboard"
    case pinToScreen = "palettePinToScreen"
    case showInFinder = "paletteShowInFinder"
    case showNextStack = "paletteShowNextStack"
    case showPreviousStack = "paletteShowPreviousStack"
    case showNextType = "paletteShowNextType"
    case showPreviousType = "paletteShowPreviousType"

    /// Fixed palette commands and standard text-editing shortcuts that local bindings cannot override.
    static let reservedShortcuts: Set<KeyboardShortcuts.Shortcut> = [
        .init(.return, modifiers: [.shift]),
        .init(.keypadEnter, modifiers: [.shift]),
        .init(.z, modifiers: [.command]),
        .init(.comma, modifiers: [.command]),
        .init(.q, modifiers: [.command]),
        .init(.delete, modifiers: [.command]),
        .init(.delete, modifiers: [.control]),
        .init(.c, modifiers: [.command]),
        .init(.x, modifiers: [.command]),
        .init(.v, modifiers: [.command]),
        .init(.a, modifiers: [.command]),
    ]

    var storageKey: String {
        "KeyboardShortcuts_\(rawValue)"
    }

    var defaultShortcut: KeyboardShortcuts.Shortcut? {
        switch self {
        case .actions: .init(.k, modifiers: [.command])
        case .copyToClipboard: .init(.return, modifiers: [.command])
        case .pinToScreen: nil
        case .showInFinder: nil
        case .showNextStack: .init(.downArrow, modifiers: [.option])
        case .showPreviousStack: .init(.upArrow, modifiers: [.option])
        case .showNextType: .init(.downArrow, modifiers: [.option, .command])
        case .showPreviousType: .init(.upArrow, modifiers: [.option, .command])
        }
    }

    var shortcut: KeyboardShortcuts.Shortcut? {
        shortcut(from: .standard)
    }

    func shortcut(from defaults: UserDefaults) -> KeyboardShortcuts.Shortcut? {
        guard let stored = defaults.object(forKey: storageKey) else {
            return defaultShortcut
        }
        guard let json = stored as? String,
            let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    func setShortcut(
        _ shortcut: KeyboardShortcuts.Shortcut?,
        in defaults: UserDefaults = .standard
    ) {
        if let shortcut {
            guard let data = try? JSONEncoder().encode(shortcut),
                let encoded = String(data: data, encoding: .utf8)
            else { return }
            defaults.set(encoded, forKey: storageKey)
        } else if defaultShortcut != nil {
            defaults.set(false, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
        NotificationCenter.default.post(
            name: .paletteShortcutDidChange,
            object: nil,
            userInfo: ["shortcut": self]
        )
    }

    @MainActor
    var displayString: String? {
        shortcut?.description.replacingOccurrences(of: "↩", with: "↵")
    }

    func matches(
        _ eventShortcut: KeyboardShortcuts.Shortcut?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let eventShortcut, let shortcut = shortcut(from: defaults) else { return false }
        return eventShortcut == shortcut
    }

    static func canAssign(
        _ candidate: KeyboardShortcuts.Shortcut,
        to target: PaletteShortcut,
        globalShortcut: KeyboardShortcuts.Shortcut? = KeyboardShortcuts.getShortcut(for: .toggleClipboard),
        defaults: UserDefaults = .standard
    ) -> Bool {
        if let globalShortcut, candidate == globalShortcut {
            return false
        }
        if reservedShortcuts.contains(candidate) {
            return false
        }
        for other in allCases where other != target {
            if other.shortcut(from: defaults) == candidate {
                return false
            }
        }
        return true
    }

    static func clearConflicts(
        with shortcut: KeyboardShortcuts.Shortcut,
        in defaults: UserDefaults = .standard
    ) {
        for local in allCases where local.shortcut(from: defaults) == shortcut {
            local.setShortcut(nil, in: defaults)
        }
    }
}

@MainActor
final class LocalShortcutRecorderCocoa: NSSearchField, NSSearchFieldDelegate {
    private let minimumWidth = 130.0
    private var canBecomeKey = false
    private var eventMonitor: Any?
    private var pausedGlobalShortcuts = false
    private var cancelButton: NSButtonCell?
    private var changeObserver: NSObjectProtocol?
    private var windowResignObserver: NSObjectProtocol?
    private var windowBecomeObserver: NSObjectProtocol?

    var paletteShortcut: PaletteShortcut {
        didSet {
            guard paletteShortcut != oldValue else { return }
            refreshDisplay()
        }
    }

    var locale: Locale {
        didSet {
            guard locale != oldValue else { return }
            updatePlaceholder(recording: eventMonitor != nil)
        }
    }

    override var canBecomeKeyView: Bool { canBecomeKey }

    override var intrinsicContentSize: CGSize {
        var size = super.intrinsicContentSize
        size.width = minimumWidth
        return size
    }

    private var showsCancelButton: Bool {
        get { (cell as? NSSearchFieldCell)?.cancelButtonCell != nil }
        set { (cell as? NSSearchFieldCell)?.cancelButtonCell = newValue ? cancelButton : nil }
    }

    init(shortcut: PaletteShortcut, locale: Locale) {
        self.paletteShortcut = shortcut
        self.locale = locale
        super.init(frame: NSRect(x: 0, y: 0, width: minimumWidth, height: 24))
        delegate = self
        alignment = .center
        (cell as? NSSearchFieldCell)?.searchButtonCell = nil
        wantsLayer = true
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        cancelButton = (cell as? NSSearchFieldCell)?.cancelButtonCell
        updatePlaceholder(recording: false)
        refreshDisplay()

        changeObserver = NotificationCenter.default.addObserver(
            forName: .paletteShortcutDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let changed = notification.userInfo?["shortcut"] as? PaletteShortcut else { return }
            MainActor.assumeIsolated {
                guard let self, changed == self.paletteShortcut else { return }
                self.refreshDisplay()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        endRecording()
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let windowResignObserver { NotificationCenter.default.removeObserver(windowResignObserver) }
        if let windowBecomeObserver { NotificationCenter.default.removeObserver(windowBecomeObserver) }
    }

    private func refreshDisplay() {
        stringValue = paletteShortcut.shortcut?.description ?? ""
        showsCancelButton = !stringValue.isEmpty
    }

    private func updatePlaceholder(recording: Bool) {
        let key = recording ? "Press Shortcut" : "Record Shortcut"
        placeholderString = AppLocalization.string(key, locale: locale)
    }

    private func preventBecomingKey() {
        canBecomeKey = false
        DispatchQueue.main.async { [weak self] in
            self?.canBecomeKey = true
        }
    }

    private func endRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if pausedGlobalShortcuts {
            pausedGlobalShortcuts = false
            KeyboardShortcuts.enable(.toggleClipboard)
        }
        updatePlaceholder(recording: false)
        showsCancelButton = !stringValue.isEmpty
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = .textColor
        }
    }

    private func blur() {
        window?.makeFirstResponder(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        if stringValue.isEmpty {
            paletteShortcut.setShortcut(nil)
        }
        showsCancelButton = !stringValue.isEmpty
        if stringValue.isEmpty {
            window?.makeFirstResponder(self)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endRecording()
    }

    override func viewDidMoveToWindow() {
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        if let windowBecomeObserver {
            NotificationCenter.default.removeObserver(windowBecomeObserver)
            self.windowBecomeObserver = nil
        }
        guard let window else {
            endRecording()
            return
        }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endRecording()
                self.window?.makeFirstResponder(nil)
            }
        }
        windowBecomeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.preventBecomingKey()
            }
        }
        preventBecomingKey()
    }

    override func becomeFirstResponder() -> Bool {
        guard window != nil, super.becomeFirstResponder() else { return false }
        updatePlaceholder(recording: true)
        showsCancelButton = !stringValue.isEmpty
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = .clear
        }
        if KeyboardShortcuts.isEnabled(for: .toggleClipboard) {
            KeyboardShortcuts.disable(.toggleClipboard)
            pausedGlobalShortcuts = true
        }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseUp, .rightMouseUp]
        ) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                self?.handleRecordedEvent(event) ?? false
            }
            return consumed ? nil : event
        }
        return true
    }

    private func handleRecordedEvent(_ event: NSEvent) -> Bool {
        let clickPoint = convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseUp || event.type == .rightMouseUp {
            if !bounds.insetBy(dx: -3, dy: -3).contains(clickPoint) {
                blur()
            }
            return false
        }
        guard event.type == .keyDown else { return true }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let keyCode = Int(event.keyCode)

        if modifiers.isEmpty {
            if keyCode == kVK_Tab {
                blur()
                return false
            }
            if keyCode == kVK_Escape {
                blur()
                return true
            }
            if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
                paletteShortcut.setShortcut(nil)
                refreshDisplay()
                blur()
                return true
            }
        }

        let hasNonShiftModifier = !modifiers.subtracting([.shift]).isEmpty
        guard hasNonShiftModifier || Self.isFunctionKey(event),
            let candidate = KeyboardShortcuts.Shortcut(event: event)
        else {
            NSSound.beep()
            return true
        }

        guard PaletteShortcut.canAssign(candidate, to: paletteShortcut) else {
            NSSound.beep()
            return true
        }

        paletteShortcut.setShortcut(candidate)
        refreshDisplay()
        blur()
        return true
    }

    private static func isFunctionKey(_ event: NSEvent) -> Bool {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return false
        }
        return (0xF704...0xF726).contains(Int(scalar.value))
    }
}

private struct LocalShortcutRecorder: NSViewRepresentable {
    let shortcut: PaletteShortcut
    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> LocalShortcutRecorderCocoa {
        LocalShortcutRecorderCocoa(shortcut: shortcut, locale: locale)
    }

    func updateNSView(_ nsView: LocalShortcutRecorderCocoa, context: Context) {
        nsView.paletteShortcut = shortcut
        nsView.locale = locale
    }
}

struct ShortcutsSettingsView: View {
    var body: some View {
        PreferencesForm {
            Section("Activation") {
                PreferencesRow(label: "Show Kit") {
                    KeyboardShortcuts.Recorder(for: .toggleClipboard) { newShortcut in
                        if let newShortcut {
                            PaletteShortcut.clearConflicts(with: newShortcut)
                        }
                    }
                }
            }

            Section("Palette") {
                shortcutRow("Show Next Type", shortcut: .showNextType)
                shortcutRow("Show Previous Type", shortcut: .showPreviousType)
                shortcutRow("Show Next Stack", shortcut: .showNextStack)
                shortcutRow("Show Previous Stack", shortcut: .showPreviousStack)
            }

            Section("Actions") {
                shortcutRow("Actions", shortcut: .actions)
                shortcutRow("Copy to Clipboard", shortcut: .copyToClipboard)
                shortcutRow("Pin to Screen", shortcut: .pinToScreen)
                shortcutRow("Show in Finder", shortcut: .showInFinder)
            }
        }
    }

    private func shortcutRow(
        _ label: LocalizedStringKey,
        shortcut: PaletteShortcut
    ) -> some View {
        PreferencesRow(label: label) {
            LocalShortcutRecorder(shortcut: shortcut)
        }
    }
}
