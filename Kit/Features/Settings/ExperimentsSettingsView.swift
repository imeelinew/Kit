import AppKit
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
                            SecureKeyField(text: $keyInput)
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

/// SwiftUI text fields misbehave in this menu-less agent app (focus and ⌘V paste), the same
/// reason the palette search wraps NSTextField. NSSecureTextField keeps masking plus working
/// field-editor editing, including paste.
private struct SecureKeyField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField(frame: .zero)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) { _text = text }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            text = field.stringValue
        }
    }
}
