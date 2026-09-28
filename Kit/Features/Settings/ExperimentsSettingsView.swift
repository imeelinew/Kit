import SwiftUI

/// Experimental features, quarantined in their own sidebar page so the stable settings stay clean.
struct ExperimentsSettingsView: View {
    @ObservedObject private var settings = AppCore.shared.settings
    @State private var keyInput = ""

    var body: some View {
        PreferencesForm {
            Section("TypeSafe AI") {
                Toggle("Enable TypeSafe AI", isOn: $settings.typesafeAIEnabled)

                if settings.typesafeAIEnabled {
                    PreferencesRow(label: "API Key") {
                        HStack(spacing: 8) {
                            SecureField("", text: $keyInput)
                                .frame(width: 240)
                            Button("Save", action: saveKey)
                                .disabled(
                                    keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func saveKey() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, settings.saveTypeSafeAPIKey(trimmed) else { return }
        keyInput = ""
    }
}
