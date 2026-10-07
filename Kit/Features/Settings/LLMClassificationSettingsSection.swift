import SwiftUI

/// LLM classification controls shared with the clipboard settings form.
struct LLMClassificationSettingsSection: View {
    @ObservedObject private var settings = AppCore.shared.settings
    @State private var apiKeyDrafts: [LLMAPIKeyProvider: String] = [:]

    var body: some View {
        Section("LLM Classification") {
            Toggle("Enable LLM Classification", isOn: $settings.llmClassificationEnabled)

            if settings.llmClassificationEnabled {
                PreferencesRow(label: "Classification Engine") {
                    Picker("Classification Engine", selection: $settings.llmClassificationEngine) {
                        ForEach(LLMClassificationEngine.allCases) { engine in
                            Text(verbatim: engine.title).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                PreferencesRow(label: "API Channel") {
                    Picker("API Channel", selection: $settings.llmAPIChannel) {
                        ForEach(LLMAPIChannel.allCases) { channel in
                            Text(LocalizedStringKey(channel.title)).tag(channel)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                PreferencesRow(label: LocalizedStringKey(settings.llmAPIKeyProvider.fieldTitle)) {
                    HStack {
                        SecureField("API Key", text: apiKeyDraft)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .accessibilityLabel(Text(LocalizedStringKey(settings.llmAPIKeyProvider.fieldTitle)))
                            .onSubmit(saveAPIKey)

                        Button("Save", action: saveAPIKey)
                            .disabled(normalizedDraft == (settings.llmAPIKey ?? ""))
                    }
                }
            }
        }
    }

    private var apiKeyDraft: Binding<String> {
        let provider = settings.llmAPIKeyProvider
        return Binding(
            get: { apiKeyDrafts[provider] ?? settings.apiKey(for: provider) ?? "" },
            set: { apiKeyDrafts[provider] = $0 })
    }

    private var normalizedDraft: String {
        apiKeyDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveAPIKey() {
        settings.saveLLMAPIKey(apiKeyDraft.wrappedValue)
        apiKeyDraft.wrappedValue = settings.llmAPIKey ?? ""
    }
}
