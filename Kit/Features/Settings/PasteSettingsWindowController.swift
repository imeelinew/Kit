import AppKit
import Carbon.HIToolbox
import Combine
import KeyboardShortcuts
import MacAppSettingsUI
import SwiftUI

/// Owns the MacAppSettingsUI preferences window and bridges Paste's SwiftUI panes into it.
@MainActor
final class PasteSettingsWindowController {
    private let activationPolicy: ActivationPolicyCoordinator
    private var controller: SettingsWindowController?
    private var closeObserver: NSObjectProtocol?
    private var commandWCloseView: CommandWCloseView?
    private var builtLanguage: AppLanguage?
    private var languageObserver: AnyCancellable?

    init(activationPolicy: ActivationPolicyCoordinator) {
        self.activationPolicy = activationPolicy
        languageObserver = AppCore.shared.settings.$language
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleLanguageChange()
            }
    }

    var isVisible: Bool {
        controller?.window?.isVisible == true
    }

    func show(tab: SettingsTab = .general) {
        let language = AppCore.shared.settings.language
        let needsRebuild =
            controller == nil
            || controller?.tabViewController.panes.count != SettingsTab.allCases.count
            || builtLanguage != language
        if needsRebuild {
            rebuildController(preservingTab: tab, makeVisible: false)
        }
        guard let controller else { return }

        select(tab, in: controller)
        attachCloseObserverIfNeeded(to: controller.window)
        installCommandWCloseViewIfNeeded(on: controller.window)

        activationPolicy.acquire("settings")
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        DispatchQueue.main.async {
            controller.window?.makeKeyAndOrderFront(nil)
        }
    }

    func focus() {
        guard let window = controller?.window else { return }
        activationPolicy.acquire("settings")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Private

    private func handleLanguageChange() {
        guard controller != nil else {
            builtLanguage = nil
            return
        }
        rebuildController(
            preservingTab: selectedTab() ?? .general,
            makeVisible: isVisible
        )
    }

    private func rebuildController(preservingTab tab: SettingsTab, makeVisible: Bool) {
        let frame = controller?.window?.frame
        tearDownController()
        builtLanguage = AppCore.shared.settings.language
        controller = makeController()
        guard let controller else { return }

        select(tab, in: controller)
        if let frame {
            controller.window?.setFrame(frame, display: false)
        }

        guard makeVisible else { return }
        // Keep the existing settings activation; tear-down closed the window
        // without releasing so we don't acquire a second time here.
        attachCloseObserverIfNeeded(to: controller.window)
        installCommandWCloseViewIfNeeded(on: controller.window)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func tearDownController() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        commandWCloseView?.removeFromSuperview()
        commandWCloseView = nil
        controller?.close()
        controller = nil
    }

    private func makeController() -> SettingsWindowController {
        let locale = AppCore.shared.settings.language.locale
        let panes: [SettingsPaneViewController] = SettingsTab.allCases.map { tab in
            SwiftUISettingsPaneController(tab: tab) {
                switch tab {
                case .general:
                    GeneralSettingsView()
                case .shortcuts:
                    ShortcutsSettingsView()
                case .appearance:
                    AppearanceSettingsView()
                case .sound:
                    SoundSettingsView()
                case .clipboard:
                    ClipboardSettingsView()
                case .history:
                    HistorySettingsView()
                case .about:
                    AboutSettingsView()
                }
            }
        }

        let controller = SettingsWindowController(
            with: panes,
            centersWindowPositionAlways: false,
            closesWindowWithEscapeKey: true
        )
        controller.settingsWindow.defaultWindowTitle = String(
            localized: "Paste Settings",
            locale: locale
        )
        return controller
    }

    private func selectedTab() -> SettingsTab? {
        guard let controller,
            let index = controller.tabViewController.selectedTabIndex,
            controller.tabViewController.panes.indices.contains(index)
        else { return nil }
        let identifier = controller.tabViewController.panes[index].tabIdentifier
        return SettingsTab.allCases.first { $0.tabIdentifier == identifier }
    }

    private func select(_ tab: SettingsTab, in controller: SettingsWindowController) {
        let panes = controller.tabViewController.panes
        guard let index = panes.firstIndex(where: { $0.tabIdentifier == tab.tabIdentifier })
        else { return }
        controller.tabViewController.selectedTabIndex = index
    }

    private func attachCloseObserverIfNeeded(to window: NSWindow?) {
        guard let window, closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activationPolicy.release("settings")
            }
        }
    }

    /// Agent apps lack File → Close. Handle ⌘W in the view hierarchy so it only runs after local
    /// monitors; a shortcut recorder can then consume the event instead of closing the window.
    private func installCommandWCloseViewIfNeeded(on window: NSWindow?) {
        guard commandWCloseView == nil, let content = window?.contentView else { return }
        let view = CommandWCloseView(frame: content.bounds)
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        commandWCloseView = view
    }
}

/// Closes the settings window on ⌘W without a local event monitor, so KeyboardShortcuts.Recorder
/// can observe the same keystroke while it is recording.
private final class CommandWCloseView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .command, event.keyCode == UInt16(kVK_ANSI_W) else {
            return super.performKeyEquivalent(with: event)
        }
        if isShortcutRecorderFirstResponder {
            return false
        }
        window?.performClose(nil)
        return true
    }

    private var isShortcutRecorderFirstResponder: Bool {
        var responder: NSResponder? = window?.firstResponder
        while let current = responder {
            if current is KeyboardShortcuts.RecorderCocoa { return true }
            responder = current.nextResponder
        }
        return false
    }
}

/// Hosts a SwiftUI settings pane inside `MacAppSettingsUI`'s `SettingsPaneViewController`.
private final class SwiftUISettingsPaneController: SettingsPaneViewController {
    private let rootView: AnyView
    private let paneHeight: CGFloat
    private static let paneWidth: CGFloat = 480

    init(
        tab: SettingsTab,
        @ViewBuilder content: () -> some View
    ) {
        let locale = AppCore.shared.settings.language.locale
        self.rootView = AnyView(
            SettingsPaneLocalizedRoot(content: content())
        )
        self.paneHeight = tab.preferredPaneHeight
        super.init(nibName: nil, bundle: nil)
        tabName = String(localized: tab.localizationKey, locale: locale)
        tabImage = tab.lucideIcon.settingsTabImage()
        tabIdentifier = tab.tabIdentifier
        isResizableView = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        view = hosting
        preferredPaneSize = NSSize(width: Self.paneWidth, height: paneHeight)
        view.setFrameSize(preferredPaneSize ?? .zero)
    }
}

/// Keeps SwiftUI settings content on the live app-language locale.
private struct SettingsPaneLocalizedRoot<Content: View>: View {
    @ObservedObject private var settings = AppCore.shared.settings
    let content: Content

    var body: some View {
        content
            .environment(\.locale, settings.language.locale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
