import AppKit
import SwiftUI

/// Experimental features, quarantined in their own sidebar page so the stable settings stay clean.
struct ExperimentsSettingsView: View {
    @ObservedObject private var settings = AppCore.shared.settings

    var body: some View {
        PreferencesForm {
            Section("TypeSafe AI") {
                Toggle("Enable TypeSafe AI", isOn: $settings.typesafeAIEnabled)

                if settings.typesafeAIEnabled {
                    PreferencesRow(label: "API Key") {
                        SecureKeyField(text: apiKeyBinding)
                            .frame(width: 240)
                    }
                }
            }
        }
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { settings.typesafeAPIKey ?? "" },
            set: { settings.saveTypeSafeAPIKey($0) }
        )
    }
}

/// Native secure entry uses the application's Edit menu for standard editing commands.
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
        context.coordinator.text = $text
        field.setAccessibilityLabel(
            AppLocalization.string("API Key", locale: AppCore.shared.settings.language.locale))
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
