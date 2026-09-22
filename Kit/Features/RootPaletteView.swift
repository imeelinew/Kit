import AppKit
import SwiftUI

struct RootPaletteView: View {
    var body: some View {
        DaycastPaletteView()
    }
}

private struct DaycastPaletteView: View {
    @EnvironmentObject private var vm: PaletteViewModel
    @ObservedObject private var settings = AppCore.shared.settings

    @State private var scroll = ScrollIntent(kind: .top)

    private var isQueryEmpty: Bool {
        vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showActions: Bool {
        if case .actions = vm.overlay { return true }
        return false
    }

    private var showAppMenu: Bool { vm.overlay == .appMenu }
    private var showTypeFilter: Bool { vm.overlay == .typeFilter }
    private var showRename: Bool { vm.renamingID != nil }

    @MainActor
    private var menuItems: [PopoverMenuItem] {
        vm.menuActions.map {
            PopoverMenuItem(action: $0, target: vm.pasteTarget, kindFilter: vm.kindFilter)
        }
    }

    var body: some View {
        let clips = vm.results
        let selected = vm.selectedItem

        return Group {
            if clips.isEmpty {
                EmptyResults(
                    text: isQueryEmpty && vm.kindFilter == .all
                        ? "Clipboard history is empty" : "No matching entries",
                    systemImage: "magnifyingglass"
                )
            } else {
                HStack(spacing: 0) {
                    ClipboardList(
                        results: clips,
                        selectedID: vm.selectedID,
                        query: vm.query,
                        scroll: scroll,
                        hoverEnabled: !vm.menuOpen && !showRename,
                        onSelect: { vm.select($0.id) },
                        onActions: { item in vm.openActions(for: item.id) },
                        renamingID: vm.renamingID,
                        renameDraft: vm.renameDraft,
                        onCommitRename: { vm.commitOpenRename($0) }
                    )
                    .frame(width: Theme.Size.clipboardListWidth)
                    Rectangle()
                        .fill(Theme.Colors.separator)
                        .frame(width: 1)
                    ClipboardPreview(item: selected, query: vm.query)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar(showActionGroup: selected != nil)
                .allowsHitTesting(!showRename)
        }
        .overlay {
            if vm.menuOpen {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { vm.closeMenu() }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showAppMenu {
                PopoverMenu(
                    items: menuItems,
                    selection: $vm.menuSelection,
                    onActivate: activateMenuItem
                )
                .padding(Self.menuInset)
                .transition(Self.menuTransition(.bottomLeading))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showActions {
                PopoverMenu(
                    items: menuItems,
                    selection: $vm.menuSelection,
                    onActivate: activateMenuItem
                )
                .padding(Self.menuInset)
                .transition(Self.menuTransition(.bottomTrailing))
            }
        }
        .overlay(alignment: .topTrailing) {
            if showTypeFilter {
                PopoverMenu(
                    items: menuItems,
                    selection: $vm.menuSelection,
                    onActivate: activateMenuItem
                )
                .padding(.top, Theme.Size.headerPadding + Theme.Size.headerHeight)
                .padding(.trailing, Theme.Spacing.md * 2)
                .transition(Self.menuTransition(.topTrailing))
            }
        }
        .animation(Self.menuAnimation, value: vm.overlay)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: vm.resetToken) {
            scroll = ScrollIntent(kind: .top)
        }
        .onChange(of: vm.followToken) {
            scroll = ScrollIntent(kind: .follow)
        }
        .environment(\.locale, settings.language.locale)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            PaletteSearchField(text: $vm.query, enabled: !showRename, fontSize: 20)
                .frame(maxWidth: .infinity)
            typeFilterControl
                .allowsHitTesting(!showRename)
        }
        .padding(.horizontal, Theme.Spacing.md * 2)
        .frame(height: Theme.Size.headerHeight)
        .padding(.top, Theme.Size.headerPadding)
        .frame(maxWidth: .infinity)
    }

    private var typeFilterControl: some View {
        BarButton(pressed: showTypeFilter, action: { vm.toggleTypeFilter() }) {
            HStack(spacing: Theme.Spacing.sm) {
                LucideIconShape(name: vm.kindFilter.icon)
                    .stroke(
                        style: StrokeStyle(
                            lineWidth: LucideIcon.strokeWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .frame(width: LucideIcon.size, height: LucideIcon.size)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(vm.kindFilter.title)
                    .font(Theme.Typography.bar)
                    .foregroundStyle(.primary)
                LucideIconShape(name: .chevronDown)
                    .stroke(
                        style: StrokeStyle(
                            lineWidth: LucideIcon.strokeWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .frame(width: 12, height: 12)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(Theme.Spacing.xs)
        .frosted(in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(vm.kindFilter.title)
    }

    private func bottomBar(showActionGroup: Bool) -> some View {
        HStack(spacing: 0) {
            MenuCircleButton(pressed: showAppMenu) { vm.toggleAppMenu() }
            Spacer()
            if showActionGroup { actionGroup }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: Theme.Size.bottomBarHeight)
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private var actionGroup: some View {
        HStack(spacing: 2) {
            BarButton(action: { vm.handle(.activate) }) {
                HStack(spacing: Theme.Spacing.sm) {
                    if let path = vm.pasteTarget?.iconPath {
                        MenuFileIcon(path: path)
                    }
                    Text(vm.pasteTarget?.pasteTitle ?? LocalizedStringKey("Paste"))
                        .font(Theme.Typography.bar)
                        .foregroundStyle(.primary)
                    KeyCapChip(text: "↵", style: .outline)
                }
            }
            BarButton(pressed: showActions, action: { vm.handle(.toggleActions) }) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("Actions")
                        .font(Theme.Typography.bar)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    if let shortcut = PaletteShortcut.actions.displayString {
                        HStack(spacing: Theme.Spacing.xxs) {
                            ForEach(Array(shortcut.enumerated()), id: \.offset) { _, glyph in
                                KeyCapChip(text: String(glyph), style: .outline)
                            }
                        }
                    }
                }
            }
        }
        .padding(Theme.Spacing.xs)
        .frosted(in: Capsule())
    }

    private func activateMenuItem(_ index: Int) {
        vm.activateMenuItem(at: index)
    }

    private static let menuInset: CGFloat = 8
    private static let menuAnimation: Animation = .easeOut(duration: 0.14)

    private static func menuTransition(_ anchor: UnitPoint) -> AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96, anchor: anchor))
    }
}

private struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    var fontSize: CGFloat = 17

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSTextField {
        let field = PaletteSearchTextField(frame: .zero)
        field.delegate = context.coordinator
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize, weight: .regular)
        field.textColor = .labelColor
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setAccessibilityLabel(String(localized: "Search"))
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = enabled
        field.font = .systemFont(ofSize: fontSize, weight: .regular)
        field.placeholderAttributedString = NSAttributedString(
            string: String(localized: "Search", locale: context.environment.locale),
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
        if !enabled, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        (field.window as? PalettePanel)?.registerSearchField(field)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                text.wrappedValue != field.stringValue
            else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

private final class PaletteSearchTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? PalettePanel)?.registerSearchField(self)
    }
}

private struct MenuCircleButton: View {
    var pressed: Bool = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Capsule().frame(width: 14, height: 1.5)
                Capsule().frame(width: 8, height: 1.5)
            }
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(width: Theme.Size.menuButton, height: Theme.Size.menuButton)
            .background(
                Circle().fill(pressed || hovered ? Theme.Colors.selection : Color.clear)
            )
            .contentShape(.circle)
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .frosted(in: Circle())
    }
}

private struct BarButton<Label: View>: View {
    var pressed: Bool = false
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, Theme.Spacing.md)
                .frame(height: 28)
                .contentShape(Capsule())
                .background(
                    Capsule().fill(
                        pressed || hovered ? Theme.Colors.rowHover : Color.clear
                    )
                )
                .scaleEffect(pressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.08), value: pressed)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct EmptyResults: View {
    let text: LocalizedStringKey
    var systemImage = "rectangle.stack"

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
