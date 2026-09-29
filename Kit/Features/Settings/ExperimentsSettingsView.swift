import SwiftUI

/// Experimental features, quarantined in their own sidebar page so the stable settings stay clean.
struct ExperimentsSettingsView: View {
    @ObservedObject private var settings = AppCore.shared.settings
    @State private var apiKeyDraft = ""

    var body: some View {
        PreferencesForm {
            Section("TypeSafe AI") {
                Toggle(isOn: $settings.typesafeAIEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable TypeSafe AI")
                        Text("When enabled, Kit uses the TypeSafe model to classify clipboard text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if settings.typesafeAIEnabled {
                    PreferencesRow(label: "API Key") {
                        HStack {
                            SecureField("API Key", text: $apiKeyDraft)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                                .accessibilityLabel("API Key")
                                .onSubmit(saveAPIKey)

                            Button("Save", action: saveAPIKey)
                                .disabled(normalizedDraft == (settings.typesafeAPIKey ?? ""))
                        }
                    }
                }
            }
        }
        .onAppear { apiKeyDraft = settings.typesafeAPIKey ?? "" }
    }

    private var normalizedDraft: String {
        apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveAPIKey() {
        settings.saveTypeSafeAPIKey(apiKeyDraft)
        apiKeyDraft = settings.typesafeAPIKey ?? ""
    }
}
