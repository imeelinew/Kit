import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppCore.shared.settings
    @ObservedObject private var updateService = AppCore.shared.updateService

    var body: some View {
        PreferencesForm {
            PreferencesRow(label: "Language") {
                Picker("App Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.title)).tag(language)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            PreferencesRow(label: "Startup", alignment: .firstTextBaseline) {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .toggleStyle(.checkbox)
            }

            PreferencesRow(label: "Input Method", alignment: .firstTextBaseline) {
                Toggle(
                    "Switch to English When Opening",
                    isOn: $settings.switchToEnglishInputOnOpen
                )
                .toggleStyle(.checkbox)
            }

            PreferencesDivider()

            PreferencesRow(label: "Updates", alignment: .firstTextBaseline) {
                Toggle(
                    "Automatically Check for Updates",
                    isOn: Binding(
                        get: { updateService.automaticallyChecksForUpdates },
                        set: { updateService.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                .toggleStyle(.checkbox)
            }
        }
        .onAppear {
            settings.launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject private var settings = AppCore.shared.settings

    var body: some View {
        PreferencesForm {
            PreferencesSectionHeader(title: "Theme")

            PreferencesRow(label: "Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(LocalizedStringKey(option.title)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Theme")
            }

            PreferencesDivider()

            PreferencesSectionHeader(title: "Visual Style")

            PreferencesRow(label: "Visual Style") {
                Picker("Visual Style", selection: $settings.paletteVisualStyle) {
                    ForEach(PaletteVisualStyle.allCases) { style in
                        Text(LocalizedStringKey(style.title)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Visual Style")
            }

            PreferencesDivider()

            PreferencesSectionHeader(title: "Menu Bar")

            PreferencesCheckboxRow(
                title: "Show Menu Bar Icon",
                isOn: $settings.showMenuBarIcon
            )

            PreferencesCheckboxRow(
                title: "Icon Animation",
                isOn: $settings.animateMenuBarIconOnCopy,
                disabled: !settings.showMenuBarIcon
            )

            PreferencesDivider()

            PreferencesSectionHeader(title: "Pinned Cards")

            PreferencesRow(label: "Pinned Image Size") {
                Picker("Pinned Image Size", selection: $settings.pinnedImageSize) {
                    ForEach(PinnedImageSize.allCases) { option in
                        Text(LocalizedStringKey(option.title)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

struct SoundSettingsView: View {
    @ObservedObject private var settings = AppCore.shared.settings
    @Environment(\.locale) private var locale

    var body: some View {
        PreferencesForm {
            PreferencesRow(label: "Enable Sound Effects", alignment: .firstTextBaseline) {
                Toggle("Enable Sound Effects", isOn: $settings.soundEffectsEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Enable Sound Effects")
            }

            PreferencesRow(label: "Sound Effect") {
                Picker("Sound Effect", selection: $settings.copySoundEffect) {
                    ForEach(CopySoundEffect.allCases) { option in
                        Text(option.title(locale: locale)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(!settings.soundEffectsEnabled)
                .accessibilityLabel("Sound Effect")
            }
        }
        .onChange(of: settings.copySoundEffect) {
            AppCore.shared.previewCopySound()
        }
    }
}

struct AboutSettingsView: View {
    @Environment(\.locale) private var locale
    private static let repositoryURL = URL(string: "https://github.com/imeelinew/Kit")!
    private static let acknowledgments: [(name: String, url: URL)] = [
        (
            "TinyCast",
            URL(string: "https://github.com/abue-ammar/tinycast")!
        ),
        (
            "KeyboardShortcuts",
            URL(string: "https://github.com/sindresorhus/KeyboardShortcuts")!
        ),
        (
            "MacAppSettingsUI",
            URL(string: "https://github.com/usagimaru/MacAppSettingsUI")!
        ),
        (
            "Sparkle",
            URL(string: "https://github.com/sparkle-project/Sparkle")!
        ),
    ]

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Kit"
    }

    private var versionString: String {
        let short =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        PreferencesForm {
            HStack(alignment: .center, spacing: Theme.Spacing.xl) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(appName)
                        .font(.title2.weight(.semibold))
                    Text("\(AppLocalization.string("Version", locale: locale)) \(versionString)")
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.bottom, Theme.Spacing.sm)

            PreferencesDivider()

            PreferencesRow(label: "Repository") {
                Button("GitHub Repository") {
                    NSWorkspace.shared.open(Self.repositoryURL)
                }
            }

            PreferencesDivider()

            PreferencesRow(label: "Acknowledgments", alignment: .top) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(Self.acknowledgments, id: \.name) { item in
                        Button(item.name) {
                            NSWorkspace.shared.open(item.url)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }
}
