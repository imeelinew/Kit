import AppKit
import CoreText
import SwiftUI
@testable import Kit

/// Counts reads of the immutable renderer output, including copies made by the bridge.
private final class CountingAttributedString: NSAttributedString {
    private let backing: NSAttributedString
    private(set) var reads = 0

    init(_ backing: NSAttributedString) {
        self.backing = backing
        super.init()
    }

    required init?(coder: NSCoder) { fatalError() }
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError()
    }

    override var string: String {
        reads += 1
        return backing.string
    }

    override var length: Int {
        reads += 1
        return backing.length
    }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?)
        -> [NSAttributedString.Key: Any]
    {
        reads += 1
        return backing.attributes(at: location, effectiveRange: range)
    }
}

@MainActor @Observable
private final class PreviewFixture {
    var source = "let value = 42"
    var query = "value"
    var fontSize: CGFloat = 13
    var dark = false
    var unrelated = 0
    var appKit: CountingAttributedString?
}

private struct PreviewFixtureView: View {
    let fixture: PreviewFixture

    var body: some View {
        let id = PreviewContentID(source: fixture.source, query: fixture.query)
        Group {
            if let appKit = fixture.appKit {
                AttributedTextPreview(nsAttributed: appKit, contentID: id, fontSize: fixture.fontSize)
            } else {
                let attributed = highlightedSource()
                AttributedTextPreview(
                    attributed: attributed,
                    contentID: id, fontSize: fixture.fontSize)
            }
        }
        .environment(\.colorScheme, fixture.dark ? .dark : .light)
        .accessibilityLabel("Update \(fixture.unrelated)")
    }

    private func highlightedSource() -> AttributedString {
        var value = CodeSyntaxHighlighter.highlight(fixture.source)
        SearchHighlight.apply(to: &value, source: fixture.source, query: fixture.query)
        return value
    }
}

@MainActor @Observable
private final class RenderFixture {
    var source = "let alpha = 42"
    var query = "alpha"
    var markdown = false
}

private struct RenderFixtureView: View {
    let fixture: RenderFixture

    var body: some View {
        if fixture.markdown {
            MarkdownPreview(source: fixture.source, query: fixture.query)
        } else {
            CodePreview(code: fixture.source, query: fixture.query)
        }
    }
}

struct ClipboardPreviewTests {
    @MainActor
    private static func textView(in view: NSView) -> PreviewTextView? {
        if let text = view as? PreviewTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    @MainActor
    static func run() async {
        func settle() async {
            ClipboardListAnimationTests.settle(0.03)
            try? await Task.sleep(for: .milliseconds(50))
        }
        let fixture = PreviewFixture()
        let hosting = NSHostingView(rootView: PreviewFixtureView(fixture: fixture))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        await settle()
        var text = textView(in: hosting)!
        precondition(text.string == fixture.source)
        precondition(text.textStorage?.attribute(.backgroundColor, at: 4, effectiveRange: nil) != nil,
                     "Search highlights survive the SwiftUI/AppKit bridge")
        fixture.query = "42"
        await settle()
        precondition(text.textStorage?.attribute(.backgroundColor, at: 4, effectiveRange: nil) == nil)
        precondition(text.textStorage?.attribute(.backgroundColor, at: 12, effectiveRange: nil) != nil)
        fixture.fontSize = 19
        await settle()
        precondition((text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 19)
        let light = text.textStorage?.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        fixture.dark = true
        await settle()
        let dark = text.textStorage?.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        precondition(light != dark, "Appearance changes invalidate resolved SwiftUI colors")

        let source = String(repeating: "ordinary preview text\n", count: 6000)
        let counted = CountingAttributedString(NSAttributedString(string: source))
        fixture.source = source
        fixture.appKit = counted
        await settle()
        text = textView(in: hosting)!
        precondition(text.string == source)
        let reads = counted.reads
        for _ in 0..<10 {
            fixture.unrelated += 1
            hosting.frame.size.width += 1
            hosting.layoutSubtreeIfNeeded()
            await settle()
        }
        precondition(counted.reads == reads,
                     "Unrelated updates and resizing must not copy or compare the renderer output")
        fixture.fontSize = 21
        await settle()
        precondition(counted.reads > reads, "Font changes reconvert the preview")
        precondition((text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 21)
        fixture.appKit = nil
        fixture.source = "replacement"
        await settle()
        text = textView(in: hosting)!
        precondition(text.string == "replacement", "Storage/source changes invalidate the cache")
        let renderFixture = RenderFixture()
        let renderHosting = NSHostingView(rootView: RenderFixtureView(fixture: renderFixture))
        window.contentView = renderHosting
        renderHosting.layoutSubtreeIfNeeded()
        await settle()
        renderFixture.source = "let beta = 7"
        await settle()
        renderFixture.source = "let gamma = 9"
        renderFixture.query = "gamma"
        await settle()
        let codeText = textView(in: renderHosting)!
        precondition(codeText.string == renderFixture.source)
        precondition(codeText.textStorage?.attribute(.backgroundColor, at: 4, effectiveRange: nil) != nil,
                     "Async code rendering must keep only the latest source and search")
        renderFixture.markdown = true
        renderFixture.source = "# Heading\n\n**bold**"
        renderFixture.query = "Heading"
        await settle()
        renderFixture.source = "# Replacement\n\n**final**"
        renderFixture.query = "Replacement"
        await settle()
        let markdownText = textView(in: renderHosting)!
        precondition(markdownText.string.contains("Replacement") && !markdownText.string.contains("Heading"))
        precondition(!markdownText.string.contains("#") && !markdownText.string.contains("**"),
                     "Markdown still renders its structure through the cached bridge")
        precondition(markdownText.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        let markdownUpdates = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: nil, queue: .main
        ) { notification in
            guard let storage = notification.object as? NSTextStorage else { return }
            precondition(!storage.string.contains("# Replacement"),
                         "Search edits must never replace rendered Markdown with its raw source")
        }
        for query in ["final", "fina", "fin", "missing", ""] {
            renderFixture.query = query
            await settle()
            let text = textView(in: renderHosting)!
            precondition(!text.string.contains("#") && !text.string.contains("**"))
            let range = (text.string as NSString).range(of: "final")
            precondition(range.location != NSNotFound)
            let highlighted = text.textStorage?.attribute(
                .backgroundColor, at: range.location, effectiveRange: nil) != nil
            precondition(highlighted == (!query.isEmpty && query != "missing"),
                         "Search highlights update and clear without reparsing Markdown")
        }
        NotificationCenter.default.removeObserver(markdownUpdates)
        window.close()

        let ordinary = "ASCII 中文 👩🏽‍💻 café e\u{301}"
        precondition(NerdSymbolsFont.privateUseRanges(in: ordinary).isEmpty)
        let privateUse = "😀\u{E000}\u{F8FF}\u{F0000}\u{FFFFD}\u{100000}\u{10FFFD}"
        let ranges = NerdSymbolsFont.privateUseRanges(in: privateUse)
        precondition(ranges.map(\.location) == [2, 3, 4, 6, 8, 10])
        precondition(ranges.map(\.length) == [1, 1, 2, 2, 2, 2])
        precondition(NerdSymbolsFont.privateUseRanges(in: "\u{D7FF}\u{F900}\u{FFFFE}\u{10FFFE}").isEmpty)

        let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Kit/Resources/Fonts/SymbolsNerdFontMono-Regular.ttf")
        CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        let base = NSFont.systemFont(ofSize: 13)
        let icons = NSMutableAttributedString(string: "A\u{E0B0}中😀", attributes: [.font: base])
        NerdSymbolsFont.applyFallback(to: icons, baseFont: base)
        precondition((icons.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.familyName == NerdSymbolsFont.familyName,
                     "Powerline icons still use the bundled symbols font")
        precondition((icons.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) == base)
        precondition((icons.attribute(.font, at: 2, effectiveRange: nil) as? NSFont) == base)
        var swiftIcons = AttributedString("A\u{E0B0}中😀")
        NerdSymbolsFont.applyFallback(to: &swiftIcons, size: 13)
        precondition(swiftIcons.runs.contains { $0.font != nil }, "SwiftUI icon fallback survives")

        let limit = CodeSyntaxHighlighter.maximumHighlightedBytes
        let oversize = "let value = 42\n" + String(repeating: "x", count: limit)
        let fallback = CodeSyntaxHighlighter.highlight(oversize)
        precondition(String(fallback.characters) == oversize && fallback.runs.count == 1,
                     "Oversized code keeps its complete payload without syntax scanning")
        let styled = CodeSyntaxHighlighter.highlight(oversize, attributes: [.font: base])
        precondition(styled.string == oversize && styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
        let boundary = "let " + String(repeating: "x", count: limit - 4)
        precondition(CodeSyntaxHighlighter.highlight(boundary).runs.count > 1,
                     "Code exactly at the byte limit is still highlighted")
        let unicodeOversize = String(repeating: "中", count: limit / 3 + 1)
        precondition(CodeSyntaxHighlighter.highlight(unicodeOversize).runs.count == 1,
                     "The render limit counts UTF-8 bytes")
        print("PASS: preview conversion reuse, input/appearance invalidation, latest async code/Markdown render, PUA fallback, code byte limits")
    }
}
