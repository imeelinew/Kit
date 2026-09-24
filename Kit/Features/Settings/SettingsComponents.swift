import SwiftUI

struct PreferencesForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .contentMargins(.horizontal, 18, for: .scrollContent)
        .contentMargins(.top, 0, for: .scrollContent)
    }
}

struct PreferencesRow<Content: View>: View {
    let label: LocalizedStringKey
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        if alignment == .top {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                Spacer(minLength: 12)
                content
            }
        } else {
            LabeledContent(label) {
                content
            }
        }
    }
}

struct PreferencesCheckboxRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        Toggle(title, isOn: $isOn)
            .disabled(disabled)
    }
}
