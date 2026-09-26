import AppKit
import SwiftUI

struct RootPaletteView: View {
    @Bindable var vm: PaletteViewModel
    let store: ClipboardStore
    @ObservedObject private var settings = AppCore.shared.settings

    private var isQueryEmpty: Bool {
        vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showActions: Bool {
        if case .actions = vm.overlay { return true }
        return false
    }

    private var showAppMenu: Bool { vm.overlay == .appMenu }
    private var showTypeFilter: Bool { vm.overlay == .typeFilter }
    private var showStackFilter: Bool { vm.overlay == .stackFilter }
    private var showStackActions: Bool {
        if case .stackActions = vm.overlay { return true }
        return false
    }

    private var stackNamingRow: Int? {
        guard showStackFilter else { return nil }
        switch vm.stackNameEdit {
        case .create:
            return vm.menuActions.count - 1
        case .rename(let id):
            return vm.menuActions.firstIndex { action in
                if case .setStackFilter(let stack) = action { return stack?.id == id }
                return false
            }
        case nil:
            return nil
        }
    }
    private var showAddToStack: Bool {
        if case .addToStack = vm.overlay { return true }
        return false
    }

    @State private var stackControlWidth: CGFloat = 0

    @MainActor
    private var menuItems: [PopoverMenuItem] {
        vm.menuActions.map {
            PopoverMenuItem(
                action: $0, target: vm.pasteTarget, kindFilter: vm.kindFilter,
                stackFilter: vm.stackFilter)
        }
    }

    var body: some View {
        let clips = vm.results
        let selected = vm.selectedItem

        return Group {
            if clips.isEmpty {
                EmptyResults(
                    text: isQueryEmpty && vm.kindFilter == .all && vm.stackFilter == nil
                        ? "Clipboard history is empty" : "No matching entries",
                    systemImage: "magnifyingglass"
                )
            } else {
                HStack(spacing: 0) {
                    ClipboardList(
                        results: clips,
                        resultsGeneration: vm.resultsGeneration,
                        hasMoreResults: vm.hasMoreResults,
                        selectedID: vm.selectedID,
                        query: vm.query,
                        scroll: vm.scrollIntent,
                        hoverEnabled: !vm.menuOpen,
                        store: store,
                        onSelect: { vm.select($0.id) },
                        onActivate: { item in
                            guard !vm.menuOpen, vm.searchReady else { return }
                            vm.select(item.id)
                            vm.handle(.activate)
                        },
                        onActions: { item in vm.openActions(for: item.id) },
                        onLoadMore: { vm.loadMoreResults() }
                    )
                    .frame(width: Theme.Size.clipboardListWidth)
                    Rectangle()
                        .fill(Theme.Colors.separator)
                        .frame(width: 1)
                    ClipboardPreview(item: selected, query: vm.query, vm: vm, store: store)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar(showActionGroup: selected != nil)
        }
        .overlay {
            Color.black.opacity(vm.menuOpen ? 0.001 : 0)
                .contentShape(Rectangle())
                .allowsHitTesting(vm.menuOpen)
                .onTapGesture { vm.closeMenu() }
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
            if showActions || showAddToStack {
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
                .padding(
                    .trailing,
                    Theme.Spacing.md * 2 + stackControlWidth + Theme.Spacing.md
                )
                .transition(Self.menuTransition(.topTrailing))
            }
        }
        .overlay(alignment: .topTrailing) {
            if showStackFilter || showStackActions {
                PopoverMenu(
                    items: menuItems,
                    selection: $vm.menuSelection,
                    onActivate: activateMenuItem,
                    onRightClick: { vm.openStackActions(at: $0) },
                    namingText: stackNamingRow == nil ? nil : $vm.stackNameDraft,
                    namingRow: stackNamingRow,
                    namingSelectsAll: {
                        if case .rename = vm.stackNameEdit { return true }
                        return false
                    }()
                )
                .padding(.top, Theme.Size.headerPadding + Theme.Size.headerHeight)
                .padding(.trailing, Theme.Spacing.md * 2)
                .transition(Self.menuTransition(.topTrailing))
            }
        }
        .animation(Self.menuAnimation, value: vm.overlay)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.locale, settings.language.locale)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            PaletteSearchField(text: $vm.query, enabled: true, fontSize: 20)
                .frame(maxWidth: .infinity)
            typeFilterControl
            stackFilterControl
        }
        .padding(.horizontal, Theme.Spacing.md * 2)
        .frame(height: Theme.Size.headerHeight)
        .padding(.top, Theme.Size.headerPadding)
        .frame(maxWidth: .infinity)
    }

    private var typeFilterControl: some View {
        BarButton(pressed: showTypeFilter, action: { vm.toggleTypeFilter() }) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: vm.kindFilter.symbolName)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(vm.kindFilter.title)
                    .font(Theme.Typography.bar)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(Theme.Spacing.xs)
        .frosted(in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(vm.kindFilter.title)
    }

    private var stackFilterControl: some View {
        BarButton(pressed: showStackFilter, action: { vm.toggleStackFilter() }) {
            HStack(spacing: Theme.Spacing.sm) {
                if vm.stackFilter == nil {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Text(vm.stackFilterTitle)
                    .font(Theme.Typography.bar)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(Theme.Spacing.xs)
        .frosted(in: Capsule())
        .fixedSize()
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: StackControlWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(StackControlWidthKey.self) { stackControlWidth = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(vm.stackFilterTitle))
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
            .disabled(!vm.canPaste)
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
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = enabled
        field.font = .systemFont(ofSize: fontSize, weight: .regular)
        let searchTitle = AppLocalization.string("Search", locale: context.environment.locale)
        field.setAccessibilityLabel(searchTitle)
        field.placeholderAttributedString = NSAttributedString(
            string: searchTitle,
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

    override func becomeFirstResponder() -> Bool {
        if (window as? PalettePanel)?.paletteViewModel?.isNamingStack == true {
            return false
        }
        return super.becomeFirstResponder()
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

private struct StackControlWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
