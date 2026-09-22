import AppKit
import SwiftUI

/// Layout metrics for the Preferences-style settings form (visual only).
enum PreferencesMetrics {
    static let labelWidth: CGFloat = 132
    static let gutter: CGFloat = 12
    static let contentPaddingH: CGFloat = 28
    static let contentPaddingV: CGFloat = 22
    static let rowSpacing: CGFloat = 18
    static let appListMaxWidth: CGFloat = 280
}

/// Vertical stack used by each settings tab.
struct PreferencesForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesMetrics.rowSpacing) {
            content
        }
        .padding(.horizontal, PreferencesMetrics.contentPaddingH)
        .padding(.vertical, PreferencesMetrics.contentPaddingV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Two-column Preferences row: trailing-aligned label, leading-aligned control.
struct PreferencesRow<Content: View>: View {
    let label: LocalizedStringKey
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: alignment, spacing: PreferencesMetrics.gutter) {
            Text(label)
                .font(.body)
                .multilineTextAlignment(.trailing)
                .frame(width: PreferencesMetrics.labelWidth, alignment: .trailing)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Checkbox in the label column, title in the control column, sharing the same gutter as `PreferencesRow`.
struct PreferencesCheckboxRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PreferencesMetrics.gutter) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: PreferencesMetrics.labelWidth, alignment: .trailing)
                .disabled(disabled)

            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !disabled else { return }
                    isOn.toggle()
                }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PreferencesDivider: View {
    var body: some View {
        Divider()
    }
}

/// Group title inside a preferences form. Rows under it keep the existing two-column style.
struct PreferencesSectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(Theme.Typography.sectionHeader)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
