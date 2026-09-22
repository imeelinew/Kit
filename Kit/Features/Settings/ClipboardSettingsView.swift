import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardSettingsView: View {
    @ObservedObject private var settings = AppCore.shared.settings
    @ObservedObject private var systemClipboardHistory = AppCore.shared.systemClipboardHistory

    var body: some View {
        PreferencesForm {
            PreferencesRow(label: "Content Preview", alignment: .firstTextBaseline) {
                Toggle("Render Markdown", isOn: $settings.renderMarkdown)
                    .toggleStyle(.checkbox)
            }

            PreferencesDivider()

            PreferencesRow(label: "System Clipboard", alignment: .firstTextBaseline) {
                Toggle(
                    "Disable System Clipboard",
                    isOn: Binding(
                        get: { systemClipboardHistory.isDisabled },
                        set: { systemClipboardHistory.setDisabled($0) }
                    )
                )
                .toggleStyle(.checkbox)
            }

            PreferencesDivider()

            PreferencesRow(label: "Disabled Applications", alignment: .top) {
                VStack(spacing: 0) {
                    ForEach(settings.clipboardDisabledApps, id: \.self) { bundleID in
                        DisabledAppRow(bundleID: bundleID) {
                            settings.clipboardDisabledApps.removeAll { $0 == bundleID }
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.md)

                        if bundleID != settings.clipboardDisabledApps.last {
                            Divider()
                        }
                    }

                    HStack(spacing: Theme.Spacing.lg) {
                        Spacer(minLength: Theme.Spacing.xl)
                        Button(action: addExcludedApp) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Add")
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.md)
                    .overlay(alignment: .top) {
                        if !settings.clipboardDisabledApps.isEmpty {
                            Divider()
                        }
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .frame(maxWidth: PreferencesMetrics.appListMaxWidth, alignment: .leading)
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
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = String(localized: "Add")
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
}

struct HistorySettingsView: View {
    @ObservedObject private var settings = AppCore.shared.settings
    @State private var confirmingClear = false

    var body: some View {
        PreferencesForm {
            PreferencesRow(label: "Keep history for") {
                Picker("Keep history for", selection: $settings.clipboardRetention) {
                    ForEach(ClipboardRetention.allCases) { retention in
                        Text(LocalizedStringKey(retention.title)).tag(retention)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: settings.clipboardRetention) {
                    let store = AppCore.shared.clipboardStore
                    store.maxAge = settings.clipboardRetention.maxAge
                    store.enforceLimits()
                }
            }

            PreferencesDivider()

            PreferencesSectionHeader(title: "Danger Zone")

            PreferencesRow(label: "Clear history") {
                Button("Clear") { confirmingClear = true }
                    .foregroundStyle(.red)
                    .controlSize(.regular)
            }
        }
        .confirmationDialog(
            "Clear clipboard history?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                AppCore.shared.clipboardStore.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
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
            if let name = localized?["CFBundleDisplayName"] as? String ?? info?["CFBundleDisplayName"]
                as? String
            {
                return name
            }
            if let name = localized?["CFBundleName"] as? String ?? info?["CFBundleName"] as? String {
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
