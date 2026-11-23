import AppKit
import SwiftUI
@testable import Kit

@MainActor @Observable
private final class PreviewFixture {
    var source = "let value = 42"
    var query = "value"
    var fontSize: CGFloat = 13
}

private struct PreviewFixtureView: View {
    let fixture: PreviewFixture

    var body: some View {
        let id = PreviewContentID(source: fixture.source, query: fixture.query)
        AttributedTextPreview(
            attributed: highlightedSource(), contentID: id, fontSize: fixture.fontSize)
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

    /// A synchronous pump, because `RunLoop.run(until:)` is unavailable from async contexts.
    @MainActor
    private static func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    @MainActor
    private static func settle() async {
        pumpRunLoop()
        try? await Task.sleep(for: .milliseconds(50))
    }

    @MainActor
    static func run() async {
        // A long document must have a usable viewport without typesetting its entire history
        let viewport = PreviewTextScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        let longText = String(repeating: "A clipboard line with 中文 and 👩‍💻\n", count: 20_000)
        viewport.textView.textStorage?.setAttributedString(NSAttributedString(
            string: longText, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]))
        viewport.updateDocumentGeometry()
        let manager = viewport.textView.layoutManager!
        let laidOut = manager.firstUnlaidCharacterIndex()
        precondition(laidOut > 0 && laidOut < viewport.textView.textStorage!.length,
                     "The first preview frame lays out visible lines without blocking on the full document")
        precondition(viewport.textView.frame.height > viewport.contentSize.height,
                     "TextKit estimates scrollable document geometry before full layout")
        manager.ensureLayout(for: viewport.textView.textContainer!)
        viewport.updateDocumentGeometry()
        let end = NSPoint(x: 0, y: max(0, viewport.textView.frame.height - viewport.contentSize.height))
        viewport.contentView.scroll(to: end)
        viewport.updateDocumentGeometry()
        precondition(viewport.contentView.bounds.maxY >= viewport.textView.intrinsicContentSize.height,
                     "The final line can scroll above the bottom fade")

        let sample = ClipboardItem(text: "CLIPTEST-UTF16 👩‍💻", kind: .text, sourceBundleID: nil)
        let samplePayload = await ClipboardPreviewPayload.load(for: sample, imageURL: nil)
        precondition(samplePayload.details.characters == 20 && samplePayload.details.words == 2,
                     "Character and word counts match the Raycast reference sample")
        let fixture = PreviewFixture()
        let hosting = NSHostingView(rootView: PreviewFixtureView(fixture: fixture))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        await settle()
        let text = textView(in: hosting)!
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
        fixture.source = "replacement"
        await settle()
        precondition(textView(in: hosting)!.string == "replacement",
                     "Storage and source changes invalidate the preview")

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
        precondition(codeText.string == renderFixture.source,
                     "Async code rendering keeps only the latest source")
        let codeFont = codeText.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        precondition(codeFont?.fontName == ClipboardPreviewFont.regular(
            ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize).fontName,
                     "Native code highlighting preserves the monospaced preview font")
        precondition(codeText.textStorage?.attribute(.backgroundColor, at: 4, effectiveRange: nil) != nil,
                     "Search highlights apply to highlighted code")
        renderFixture.markdown = true
        renderFixture.source = "# Replacement\n\n**final**"
        renderFixture.query = "Replacement"
        await settle()
        let markdownText = textView(in: renderHosting)!
        precondition(markdownText.string.contains("Replacement") && !markdownText.string.contains("Heading"))
        precondition(!markdownText.string.contains("#") && !markdownText.string.contains("**"),
                     "Markdown renders its structure instead of its raw source")
        for query in ["final", "missing", ""] {
            renderFixture.query = query
            await settle()
            let text = textView(in: renderHosting)!
            precondition(!text.string.contains("#") && !text.string.contains("**"))
            let range = (text.string as NSString).range(of: "final")
            precondition(range.location != NSNotFound)
            let highlighted = text.textStorage?.attribute(
                .backgroundColor, at: range.location, effectiveRange: nil) != nil
            precondition(highlighted == (query == "final"),
                         "Search highlights update and clear without reparsing Markdown")
        }
        window.close()

        let ordinary = "ASCII 中文 👩🏽‍💻 café e\u{301}"
        precondition(NerdSymbolsFont.privateUseRanges(in: ordinary).isEmpty)
        let privateUse = "😀\u{E000}\u{F8FF}\u{F0000}\u{FFFFD}\u{100000}\u{10FFFD}"
        let ranges = NerdSymbolsFont.privateUseRanges(in: privateUse)
        precondition(ranges.map(\.location) == [2, 3, 4, 6, 8, 10])
        precondition(ranges.map(\.length) == [1, 1, 2, 2, 2, 2])
        precondition(NerdSymbolsFont.privateUseRanges(in: "\u{D7FF}\u{F900}\u{FFFFE}\u{10FFFE}").isEmpty)

        let limit = CodeSyntaxHighlighter.maximumHighlightedBytes
        let oversize = "let value = 42\n" + String(repeating: "x", count: limit)
        let fallback = CodeSyntaxHighlighter.highlight(oversize)
        precondition(String(fallback.characters) == oversize && fallback.runs.count == 1,
                     "Oversized code keeps its complete payload without syntax scanning")
        let unicodeOversize = String(repeating: "中", count: limit / 3 + 1)
        precondition(CodeSyntaxHighlighter.highlight(unicodeOversize).runs.count == 1,
                     "The render limit counts UTF-8 bytes")
        print("PASS: incremental preview layout, bridge highlight and font invalidation, latest async code/Markdown render, PUA range mapping, code byte limits")
    }
}
