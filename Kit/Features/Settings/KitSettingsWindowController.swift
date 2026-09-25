import AppKit
import Carbon.HIToolbox
import Combine
import KeyboardShortcuts
import SwiftUI

/// Owns the native window and the selection shared with the SwiftUI sidebar.
@MainActor
final class KitSettingsWindowController {
    private let activationPolicy: ActivationPolicyCoordinator
    private let selection = SettingsSelection()
    private let windowDelegate = SettingsWindowDelegate()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var commandWCloseView: CommandWCloseView?
    private var languageObserver: AnyCancellable?

    init(activationPolicy: ActivationPolicyCoordinator) {
        self.activationPolicy = activationPolicy
        languageObserver = AppCore.shared.settings.$language
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] language in
                self?.window?.title = AppLocalization.string(
                    "Kit Settings", locale: language.locale)
            }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(tab: SettingsTab = .general) {
        if window == nil { makeWindow() }
        selection.tab = tab
        guard let window else { return }
        activationPolicy.acquire("settings")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func focus() {
        guard let window else { return }
        activationPolicy.acquire("settings")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() {
        let hosting = NSHostingController(rootView: SettingsWindowRoot(selection: selection))
        let window = SettingsWindow(contentViewController: hosting)
        window.title = AppLocalization.string(
            "Kit Settings", locale: AppCore.shared.settings.language.locale)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.collectionBehavior = [.fullScreenNone, .fullScreenDisallowsTiling]
        window.delegate = windowDelegate
        window.isReleasedWhenClosed = false
        let contentSize = SettingsWindowMetrics.contentSize
        window.setContentSize(contentSize)
        let frameSize = window.frame.size
        window.minSize = frameSize
        window.maxSize = frameSize
        window.center()
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activationPolicy.release("settings")
            }
        }
        installCommandWCloseView(on: window)
    }

    /// Agent apps have no File → Close command; keep ⌘W below shortcut recorders.
    private func installCommandWCloseView(on window: NSWindow) {
        guard let content = window.contentView else { return }
        let view = CommandWCloseView(frame: content.bounds)
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        commandWCloseView = view
    }
}

@MainActor
private final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

private struct SettingsWindowRoot: View {
    @ObservedObject var selection: SettingsSelection
    @ObservedObject private var settings = AppCore.shared.settings
    @State private var backStack: [SettingsTab] = []
    @State private var forwardStack: [SettingsTab] = []
    @State private var applyingHistory = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.tab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label {
                        Text(LocalizedStringKey(tab.localizationKey))
                    } icon: {
                        Image(tab.iconAsset)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                    .listItemTint(.preferred(Color.secondary))
                    .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .background(SourceListSelection())
            .navigationSplitViewColumnWidth(
                min: SettingsWindowMetrics.sidebarWidth,
                ideal: SettingsWindowMetrics.sidebarWidth,
                max: SettingsWindowMetrics.sidebarWidth
            )
        } detail: {
            NavigationStack {
                settingsPage
                    .navigationTitle(
                        Text(
                            verbatim: AppLocalization.string(
                                selection.tab.localizationKey,
                                locale: settings.language.locale
                            )
                        )
                    )
            }
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button(action: goBack) {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(backStack.isEmpty)
                    .accessibilityLabel("Back")
                    Button(action: goForward) {
                        Image(systemName: "chevron.forward")
                    }
                    .disabled(forwardStack.isEmpty)
                    .accessibilityLabel("Forward")
                }
                .controlGroupStyle(.navigation)
            }
        }
        .onChange(of: selection.tab) { previous, _ in
            guard !applyingHistory else {
                applyingHistory = false
                return
            }
            backStack.append(previous)
            forwardStack.removeAll()
        }
        .environment(\.locale, settings.language.locale)
    }

    private func goBack() {
        guard let tab = backStack.popLast() else { return }
        forwardStack.append(selection.tab)
        applyingHistory = true
        selection.tab = tab
    }

    private func goForward() {
        guard let tab = forwardStack.popLast() else { return }
        backStack.append(selection.tab)
        applyingHistory = true
        selection.tab = tab
    }

    @ViewBuilder
    private var settingsPage: some View {
        switch selection.tab {
        case .general: GeneralSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .appearance: AppearanceSettingsView()
        case .sound: SoundSettingsView()
        case .clipboard: ClipboardSettingsView()
        case .history: HistorySettingsView()
        case .about: AboutSettingsView()
        }
    }
}

/// Keeps the sidebar selection on the system accent while this window is key.
/// A plain list highlight turns gray whenever the detail column is first responder.
private struct SourceListSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SourceListSelectionView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SourceListSelectionView)?.apply()
    }
}

private final class SourceListSelectionView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        DispatchQueue.main.async { [weak self] in
            guard let table = self?.enclosingTable else { return }
            table.style = .sourceList
        }
    }

    private var enclosingTable: NSTableView? {
        if let table = enclosingScrollView?.documentView as? NSTableView { return table }
        var ancestor: NSView? = self
        while let current = ancestor {
            if let table = current as? NSTableView { return table }
            if let table = current.enclosingScrollView?.documentView as? NSTableView { return table }
            ancestor = current.superview
        }
        return window?.contentView?.tables.min { lhs, rhs in
            lhs.convert(lhs.bounds, to: nil).minX < rhs.convert(rhs.bounds, to: nil).minX
        }
    }
}

private extension NSView {
    var tables: [NSTableView] {
        var found: [NSTableView] = []
        if let table = self as? NSTableView { found.append(table) }
        for subview in subviews { found.append(contentsOf: subview.tables) }
        return found
    }
}

/// Dia's settings window, measured while it was open: 778×509, sidebar 196.
private enum SettingsWindowMetrics {
    static let contentSize = NSSize(width: 778, height: 509)
    static let sidebarWidth: CGFloat = 196
}

/// Close stays available. Minimize and zoom stay visible but do nothing.
private final class SettingsWindow: NSWindow {
    override func miniaturize(_ sender: Any?) {}

    override func zoom(_ sender: Any?) {}

    override func toggleFullScreen(_ sender: Any?) {}
}

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { false }
}

private final class CommandWCloseView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .command, event.keyCode == UInt16(kVK_ANSI_W) else {
            return super.performKeyEquivalent(with: event)
        }
        var responder: NSResponder? = window?.firstResponder
        while let current = responder {
            if current is KeyboardShortcuts.RecorderCocoa { return false }
            responder = current.nextResponder
        }
        window?.performClose(nil)
        return true
    }
}
