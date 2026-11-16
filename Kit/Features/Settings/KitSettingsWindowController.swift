import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import MacAppSettingsUI
import SwiftUI

@MainActor
final class KitSettingsWindowController {
    private unowned let core: AppCore
    private let activationPolicy: ActivationPolicyCoordinator
    private var controller: SettingsWindowController?
    private var closeObserver: NSObjectProtocol?
    private var commandWCloseView: CommandWCloseView?
    private var languageObserver: ObservationToken?

    init(core: AppCore, activationPolicy: ActivationPolicyCoordinator) {
        self.core = core
        self.activationPolicy = activationPolicy
        languageObserver = core.settings.observeLanguage(initial: false) { [weak self] _ in
            self?.updateTabNames()
        }
    }

    var isVisible: Bool { controller?.window?.isVisible == true }

    func show(tab: SettingsTab = .general) {
        if controller == nil { makeWindow() }
        guard let controller else { return }
        if controller.tabViewController.tabViewItem(withIdentifier: String(tab.rawValue)) != nil {
            controller.tabViewController.selectedTabViewItemIndex = tab.rawValue
        }
        activationPolicy.acquire("settings")
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func focus() {
        guard let controller else { return }
        activationPolicy.acquire("settings")
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() {
        let panes = SettingsTab.allCases.map { tab in
            KitSettingsPane(
                tabName: AppLocalization.string(tab.localizationKey, locale: core.settings.language.locale),
                tabImage: NSImage(
                    systemSymbolName: tab.symbolName,
                    accessibilityDescription: nil
                ),
                tabIdentifier: String(tab.rawValue),
                content: settingsPage(for: tab)
            )
        }
        let controller = SettingsWindowController(with: panes)
        controller.settingsWindow.defaultWindowTitle = AppLocalization.string(
            "Kit Settings", locale: core.settings.language.locale)
        controller.tabViewController.defaultPaneSize = SettingsPaneMetrics.contentSize
        controller.tabViewController.showsLoadingLabelWhileLoading = false
        controller.window?.collectionBehavior = [.fullScreenNone, .fullScreenDisallowsTiling]
        controller.window?.isReleasedWhenClosed = false
        if let window = controller.window {
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
        self.controller = controller
    }

    private func updateTabNames() {
        guard let controller else { return }
        let locale = core.settings.language.locale
        for (tab, item) in zip(SettingsTab.allCases, controller.tabViewController.tabViewItems) {
            let name = AppLocalization.string(tab.localizationKey, locale: locale)
            (item.viewController as? SettingsPaneViewController)?.tabName = name
            item.label = name
        }
        controller.settingsWindow.defaultWindowTitle = AppLocalization.string("Kit Settings", locale: locale)
        controller.tabViewController.updateWindowTitleWithSelectedTab()
    }

    private func settingsPage(for tab: SettingsTab) -> AnyView {
        let view: AnyView
        switch tab {
        case .general:
            view = AnyView(GeneralSettingsView(settings: core.settings, updateService: core.updateService))
        case .shortcuts:
            view = AnyView(ShortcutsSettingsView())
        case .appearance:
            view = AnyView(AppearanceSettingsView(settings: core.settings))
        case .sound:
            view = AnyView(SoundSettingsView(settings: core.settings, onPreviewSound: { [unowned core] in
                core.previewCopySound()
            }))
        case .clipboard:
            view = AnyView(ClipboardSettingsView(
                settings: core.settings,
                store: core.clipboardStore,
                systemClipboardHistory: core.systemClipboardHistory
            ))
        case .about:
            view = AnyView(AboutSettingsView())
        }
        return AnyView(LocalizedSettingsPage(settings: core.settings, content: view))
    }

    private func installCommandWCloseView(on window: NSWindow) {
        guard let content = window.contentView else { return }
        let view = CommandWCloseView(frame: content.bounds)
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        commandWCloseView = view
    }
}

private enum SettingsPaneMetrics {
    static let contentSize = NSSize(width: 528, height: 366)
}

private struct LocalizedSettingsPage: View {
    let settings: AppSettings
    let content: AnyView

    var body: some View {
        content.environment(\.locale, settings.language.locale)
    }
}

private final class KitSettingsPane: SettingsPaneViewController {
    private let content: AnyView

    init(tabName: String, tabImage: NSImage?, tabIdentifier: String, content: AnyView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        self.tabName = tabName
        self.tabImage = tabImage
        self.tabIdentifier = tabIdentifier
        preferredPaneSize = SettingsPaneMetrics.contentSize
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: SettingsPaneMetrics.contentSize))
    }

    override func buildPaneContent() {
        let hosted = NSHostingView(rootView: content)
        hosted.frame = view.bounds
        hosted.autoresizingMask = [.width, .height]
        view.addSubview(hosted)
    }
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
