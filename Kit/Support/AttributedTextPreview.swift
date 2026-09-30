import AppKit
import SwiftUI

/// Identifies the logical input and whether its asynchronous rendering has completed.
struct PreviewContentID: Hashable {
    let source: String
    let query: String
    var rendered = true
}

/// Read-only attributed preview text. The scroll view and text system are
/// entirely AppKit so large previews do not need a SwiftUI `ScrollView` around `NSTextView`.
struct AttributedTextPreview: NSViewRepresentable {
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
        PreviewTextScrollView()
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
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
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
            if value == nil { mutable.addAttribute(.font, value: font, range: range) }
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

final class PreviewTextScrollView: NSScrollView {
    let textView = PreviewTextView()
    private var styleObserver: NotificationToken?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        autohidesScrollers = true
        automaticallyAdjustsContentInsets = false
        contentView.drawsBackground = false

        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = true
        textView.allowsUndo = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            styleObserver = nil
            return
        }
        observeScrollerStyleChanges()
        applyOverlayScrollerStyle()
    }

    override func layout() {
        super.layout()
        updateDocumentGeometry()
    }

    func updateDocumentGeometry() {
        let width = contentSize.width
        guard width > 0, let textContainer = textView.textContainer else { return }

        textContainer.containerSize = NSSize(
            width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textContainer)
        let contentHeight = textView.intrinsicContentSize.height
        let height = max(contentSize.height, contentHeight)
        let size = NSSize(width: width, height: height)
        if textView.frame.size != size {
            textView.setFrameSize(size)
        }
    }

    private func observeScrollerStyleChanges() {
        guard styleObserver == nil else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.applyOverlayScrollerStyle() }
        }
        styleObserver = NotificationToken(token, center: .default)
    }

    private func applyOverlayScrollerStyle() {
        guard scrollerStyle != .overlay || !autohidesScrollers || !hasVerticalScroller else {
            return
        }
        scrollerStyle = .overlay
        autohidesScrollers = true
        hasVerticalScroller = true
        tile()
    }
}

final class PreviewTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    override func layout() {
        super.layout()
        if let textContainer, abs(textContainer.size.width - bounds.width) > 0.5 {
            textContainer.size = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
            invalidateIntrinsicContentSize()
        }
    }
}
