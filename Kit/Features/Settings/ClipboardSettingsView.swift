import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardSettingsView: View {
    @ObservedObject private var settings = AppCore.shared.settings
    @ObservedObject private var store = AppCore.shared.clipboardStore
    private struct RetentionConfirmation: Identifiable {
        let id = UUID()
        let retention: ClipboardRetention
        let impact: ClipboardStore.RetentionImpact
    }
    @State private var retentionConfirmation: RetentionConfirmation?
    @State private var confirmingRetentionChange = false
    @State private var retentionChangeFailed = false
    @State private var confirmingClear = false
    @State private var confirmingClearImageIndex = false
    @State private var confirmingRebuildImageIndex = false
    @State private var imageCountForRebuild = 0

    @ObservedObject private var systemClipboardHistory = AppCore.shared.systemClipboardHistory

    var body: some View {
        PreferencesForm {
            Section("System Clipboard") {
                Toggle(
                    "Disable System Clipboard",
                    isOn: Binding(
                        get: { systemClipboardHistory.isDisabled },
                        set: { systemClipboardHistory.setDisabled($0) }
                    )
                )
            }

            Section("Disabled Applications") {
                ForEach(settings.clipboardDisabledApps, id: \.self) { bundleID in
                    DisabledAppRow(bundleID: bundleID) {
                        settings.clipboardDisabledApps.removeAll { $0 == bundleID }
                    }
                }

                Button(action: addExcludedApp) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Application…")
            }

            LLMClassificationSettingsSection()

            Section("Image Text Recognition") {
                Toggle("Search Text in Images", isOn: $settings.imageTextSearchEnabled)
            }

            Section("Content Preview") {
                Toggle("Render Markdown", isOn: $settings.renderMarkdown)
            }

            Section("History Retention") {
                PreferencesRow(label: "Keep history for") {
                    Picker("Keep history for", selection: Binding(
                        get: { settings.clipboardRetention },
                        set: { changeRetention(to: $0) }
                    )) {
                        ForEach(ClipboardRetention.allCases) { retention in
                            Text(LocalizedStringKey(retention.title)).tag(retention)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .confirmationDialog(
                        Text(verbatim: retentionConfirmationTitle),
                        isPresented: $confirmingRetentionChange,
                        titleVisibility: .visible,
                        presenting: retentionConfirmation
                    ) { confirmation in
                        Button("Delete and Change", role: .destructive) {
                            changeRetention(to: confirmation.retention, confirming: confirmation.impact)
                        }
                        Button("Cancel", role: .cancel) { retentionConfirmation = nil }
                    } message: { confirmation in
                        Text(verbatim: retentionConfirmationMessage(confirmation.impact))
                    }
                    .task(id: retentionConfirmation?.id) {
                        guard retentionConfirmation != nil else { return }
                        // Let the previous native sheet dismiss before presenting revised counts.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        confirmingRetentionChange = true
                    }
                }
            }

            Section("Danger Zone") {
                PreferencesRow(label: "Image Text Index") {
                    switch store.imageTextIndexState {
                    case .indexed:
                        Button("Clear…") { confirmingClearImageIndex = true }
                            .foregroundStyle(.red)
                            .accessibilityLabel("Clear Index")
                    case .none:
                        Button("Rebuild Index…") {
                            imageCountForRebuild = store.imageTextIndexImageCount()
                            confirmingRebuildImageIndex = true
                        }
                    case .indexing:
                        Button("Indexing…") {}
                            .disabled(true)
                    }
                }
                PreferencesRow(label: "Clear history") {
                    Button("Clear…") { confirmingClear = true }
                        .foregroundStyle(.red)
                        .controlSize(.regular)
                }
            }
        }
        .onAppear {
            systemClipboardHistory.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            systemClipboardHistory.refresh()
        }
        .alert("Couldn't change history retention", isPresented: $retentionChangeFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("History and the retention setting haven't changed, try again")
        }
        .confirmationDialog(
            "Clear clipboard history?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                store.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone")
        }
        .confirmationDialog(
            "Clear the image text index?",
            isPresented: $confirmingClearImageIndex,
            titleVisibility: .visible
        ) {
            Button("Clear Index", role: .destructive) {
                if !store.clearImageTextIndex() { NSSound.beep() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Images stay in your history, but you won't be able to find them by their text")
        }
        .confirmationDialog(
            "Rebuild the image text index?",
            isPresented: $confirmingRebuildImageIndex,
            titleVisibility: .visible
        ) {
            Button("Rebuild") {
                if !store.rebuildImageTextIndex() { NSSound.beep() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: String(
                format: AppLocalization.string(
                    "Kit will re-read text from %d images in your history, this uses significant CPU",
                    locale: settings.language.locale),
                locale: settings.language.locale,
                imageCountForRebuild))
        }
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = AppLocalization.string("Add", locale: settings.language.locale)
        guard panel.runModal() == .OK else { return }

        var apps = settings.clipboardDisabledApps
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                !apps.contains(bundleID)
            else { continue }
            apps.append(bundleID)
        }
        settings.clipboardDisabledApps = apps
    }

    private func changeRetention(
        to retention: ClipboardRetention, confirming impact: ClipboardStore.RetentionImpact? = nil
    ) {
        guard retention != settings.clipboardRetention else { return }
        switch settings.changeClipboardRetention(to: retention, in: store, confirming: impact) {
        case .applied:
            retentionConfirmation = nil
        case .confirmationRequired(let currentImpact):
            retentionConfirmation = RetentionConfirmation(retention: retention, impact: currentImpact)
        case .failed:
            retentionConfirmation = nil
            retentionChangeFailed = true
        }
    }

    private var retentionConfirmationTitle: String {
        guard let confirmation = retentionConfirmation else { return "" }
        let locale = settings.language.locale
        return String(
            format: AppLocalization.string("Change history retention to %@?", locale: locale),
            locale: locale,
            AppLocalization.string(confirmation.retention.title, locale: locale))
    }

    private func retentionConfirmationMessage(_ impact: ClipboardStore.RetentionImpact) -> String {
        let locale = settings.language.locale
        return String(
            format: AppLocalization.string(
                "Permanently delete %@ history entries\nIncluding %@ images and %@ entries in Stacks\n\nThis can't be undone",
                locale: locale),
            locale: locale,
            impact.itemCount.formatted(.number.locale(locale)),
            impact.imageCount.formatted(.number.locale(locale)),
            impact.stackItemCount.formatted(.number.locale(locale)))
    }
}

private struct DisabledAppRow: View {
    let bundleID: String
    let onRemove: () -> Void

    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private var displayName: String {
        guard let url = appURL else { return bundleID }
        if let bundle = Bundle(url: url) {
            let localized = bundle.localizedInfoDictionary
            let info = bundle.infoDictionary
            if let name = localized?["CFBundleDisplayName"] as? String ?? info?[
                "CFBundleDisplayName"]
                as? String
            {
                return name
            }
            if let name = localized?["CFBundleName"] as? String ?? info?["CFBundleName"] as? String
            {
                return name
            }
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(nsImage: appURL.map { IconCache.icon(forFile: $0.path) } ?? genericIcon)
                .resizable()
                .frame(width: 22, height: 22)
            Text(displayName)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.xl)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private var genericIcon: NSImage {
        NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
