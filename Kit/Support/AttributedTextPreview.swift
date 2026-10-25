import AppKit
import CoreText
import QuartzCore
import SwiftUI

enum ClipboardPreviewFont {
    private static let registration: Void = {
        guard let url = Bundle.main.url(forResource: "JetBrainsMono-Regular", withExtension: "ttf")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func regular(ofSize size: CGFloat) -> NSFont {
        _ = registration
        return NSFont(name: "JetBrainsMono-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Identifies the logical input and whether its asynchronous rendering has completed.
struct PreviewContentID: Hashable {
    let source: String
    let query: String
    var rendered = true
}

/// Read-only attributed preview text. The scroll view and text system are
/// entirely AppKit so large previews do not need a SwiftUI `ScrollView` around `NSTextView`.
struct AttributedTextPreview: View {
    private let preview: AttributedTextPreviewRepresentable

    init(attributed: AttributedString, contentID: PreviewContentID, fontSize: CGFloat? = nil) {
        preview = AttributedTextPreviewRepresentable(
            attributed: attributed, contentID: contentID, fontSize: fontSize)
    }

    init(nsAttributed: NSAttributedString, contentID: PreviewContentID, fontSize: CGFloat? = nil) {
        preview = AttributedTextPreviewRepresentable(
            nsAttributed: nsAttributed, contentID: contentID, fontSize: fontSize)
    }

    var body: some View { preview }
}

private struct AttributedTextPreviewRepresentable: NSViewRepresentable {
    private enum Storage {
        case swiftUI(AttributedString)
        case appKit(NSAttributedString)
    }

    private let storage: Storage
    private let fontSize: CGFloat?
    private let contentID: PreviewContentID

    init(
        attributed: AttributedString,
        contentID: PreviewContentID,
        fontSize: CGFloat? = nil
    ) {
        storage = .swiftUI(attributed)
        self.fontSize = fontSize
        self.contentID = contentID
    }

    init(
        nsAttributed: NSAttributedString,
        contentID: PreviewContentID,
        fontSize: CGFloat? = nil
    ) {
        storage = .appKit(nsAttributed)
        self.fontSize = fontSize
        self.contentID = contentID
    }

    final class Coordinator {
        fileprivate var lastInput: Input?
    }

    fileprivate struct Input: Equatable {
        let contentID: PreviewContentID
        let fontSize: CGFloat
        let colorScheme: ColorScheme
        let contrast: ColorSchemeContrast
        let accent: NSColor
        let appKit: Bool
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PreviewTextScrollView {
        let scrollView = PreviewTextScrollView()
        return scrollView
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: PreviewTextScrollView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
            width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: nsView.contentHeight(width: width, limit: height))
    }

    static func dismantleNSView(_ scrollView: PreviewTextScrollView, coordinator: Coordinator) {
        // SwiftUI can retain detached AppKit views for reuse; release their heavy text immediately.
        scrollView.textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        coordinator.lastInput = nil
    }

    func updateNSView(_ scrollView: PreviewTextScrollView, context: Context) {
        let environment = context.environment
        let appKit: Bool
        switch storage {
        case .swiftUI: appKit = false
        case .appKit: appKit = true
        }
        let input = Input(
            contentID: contentID,
            fontSize: fontSize ?? NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
            colorScheme: environment.colorScheme, contrast: environment.colorSchemeContrast,
            accent: NSColor.controlAccentColor, appKit: appKit)
        // The text storage already owns the converted result. Skip conversion and full-string
        // comparison for unrelated SwiftUI updates; layout changes are handled by the scroll view.
        guard context.coordinator.lastInput != input else { return }
        let textView = scrollView.textView
        let previousString = textView.string
        let previousSelection = textView.selectedRange()
        let ns: NSAttributedString
        switch storage {
        case .swiftUI(let attributed):
            ns = Self.nsAttributed(
                from: attributed,
                environment: context.environment,
                fontSize: fontSize)
        case .appKit(let attributed):
            ns = Self.nsAttributed(from: attributed, fontSize: fontSize)
        }
        textView.textStorage?.setAttributedString(ns)
        if previousString != ns.string {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        } else if previousSelection.location != NSNotFound {
            let length = textView.string.utf16.count
            let location = min(previousSelection.location, length)
            let selectionLength = min(previousSelection.length, length - location)
            textView.setSelectedRange(
                NSRange(location: location, length: selectionLength))
        }
        textView.invalidateIntrinsicContentSize()
        context.coordinator.lastInput = input
        scrollView.updateDocumentGeometry()
    }

    /// `AttributedString` stores the highlighters' colors in SwiftUI's attribute scope. The
    /// Foundation bridge does not turn those values into the `NSColor` attributes TextKit draws,
    /// so copy them explicitly while preserving every Foundation/AppKit attribute it can bridge.
    private static func nsAttributed(
        from attributed: AttributedString,
        environment: EnvironmentValues,
        fontSize: CGFloat?
    ) -> NSAttributedString {
        let size = fontSize ?? NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        let font = ClipboardPreviewFont.regular(ofSize: size)
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let full = NSRange(location: 0, length: mutable.length)
        guard full.length > 0 else { return mutable }

        var colorCache: [Color: NSColor] = [:]
        func appKitColor(_ color: Color) -> NSColor {
            if let cached = colorCache[color] { return cached }
            let resolved = nsColor(color, environment: environment)
            colorCache[color] = resolved
            return resolved
        }

        for run in attributed.runs {
            let range = NSRange(run.range, in: attributed)
            if let color = run.swiftUI.foregroundColor {
                mutable.addAttribute(
                    .foregroundColor, value: appKitColor(color),
                    range: range)
            }
            if let color = run.swiftUI.backgroundColor {
                mutable.addAttribute(
                    .backgroundColor, value: appKitColor(color),
                    range: range)
            }
        }

        mutable.enumerateAttribute(.font, in: full) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.font, value: font, range: range)
            }
        }
        mutable.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        NerdSymbolsFont.applyFallback(to: mutable, baseFont: font)
        return mutable
    }

    /// Fully styled AppKit previews already contain their fonts and paragraph geometry. Fill only
    /// missing baseline attributes, preserving the renderer's layout verbatim.
    private static func nsAttributed(
        from attributed: NSAttributedString,
        fontSize: CGFloat?
    ) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: mutable.length)
        guard full.length > 0 else { return mutable }

        let font = fontSize.map { NSFont.systemFont(ofSize: $0) }
            ?? NSFont.preferredFont(forTextStyle: .subheadline)
        mutable.enumerateAttribute(.font, in: full) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.font, value: font, range: range)
            }
        }
        mutable.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        NerdSymbolsFont.applyFallback(to: mutable, baseFont: font)
        return mutable
    }

    private static func nsColor(_ color: Color, environment: EnvironmentValues) -> NSColor {
        let resolved = color.resolve(in: environment)
        return NSColor(
            srgbRed: CGFloat(resolved.red), green: CGFloat(resolved.green),
            blue: CGFloat(resolved.blue), alpha: CGFloat(resolved.opacity))
    }
}

final class PreviewTextScrollView: KitScrollView {
    let textView = PreviewTextView()
    private static let fadeHeight: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        edgeDissolve = .bottom(Self.fadeHeight)

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        autohidesScrollers = true
        automaticallyAdjustsContentInsets = false
        contentView.drawsBackground = false
        contentView.wantsLayer = true
        contentView.postsBoundsChangedNotifications = true

        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        installDocumentView(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateDocumentGeometry()
    }

    func contentHeight(width: CGFloat, limit: CGFloat) -> CGFloat {
        guard let textContainer = textView.textContainer else { return limit }
        let size = NSSize(
            width: max(1, width - PreviewTextView.trailingGutter),
            height: CGFloat.greatestFiniteMagnitude)
        if textContainer.containerSize != size {
            textContainer.containerSize = size
        }
        // Measure only the proposed viewport so long documents keep incremental layout
        textView.layoutManager?.ensureLayout(
            forBoundingRect: NSRect(x: 0, y: 0, width: width, height: limit),
            in: textContainer)
        return min(limit, textView.intrinsicContentSize.height)
    }

    func updateDocumentGeometry() {
        let width = contentSize.width
        guard width > 0, let textContainer = textView.textContainer else { return }

        let containerSize = NSSize(
            width: max(1, width - PreviewTextView.trailingGutter), height: CGFloat.greatestFiniteMagnitude)
        if textContainer.containerSize != containerSize {
            textContainer.containerSize = containerSize
        }
        // Lay out the viewport before presentation, TextKit estimates the remaining document
        textView.layoutManager?.ensureLayout(
            forBoundingRect: contentView.bounds.insetBy(dx: 0, dy: -Self.fadeHeight),
            in: textContainer)
        let contentHeight = textView.intrinsicContentSize.height
        // The final line can scroll above the fade instead of remaining hidden underneath it
        let overflows = contentHeight > contentSize.height
        let height = max(contentSize.height, contentHeight + (overflows ? Self.fadeHeight : 0))
        let size = NSSize(width: width, height: height)
        if textView.frame.size != size {
            textView.setFrameSize(size)
        }
        updateScrollAppearance()
    }

}

final class PreviewTextView: NSTextView {
    static let trailingGutter: CGFloat = 16

    override func copy(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        super.copy(sender)
        if pasteboard.changeCount != previousChangeCount {
            Paster.markCurrentPasteboardSelection()
        }
    }

    override func paste(_ sender: Any?) {}
    override func pasteAsPlainText(_ sender: Any?) {}
    override func pasteAsRichText(_ sender: Any?) {}

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    override func layout() {
        super.layout()
        if let textContainer, abs(textContainer.size.width - max(1, bounds.width - Self.trailingGutter)) > 0.5 {
            textContainer.size = NSSize(width: max(1, bounds.width - Self.trailingGutter), height: CGFloat.greatestFiniteMagnitude)
            invalidateIntrinsicContentSize()
        }
    }
}
