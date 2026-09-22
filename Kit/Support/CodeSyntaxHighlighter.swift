import AppKit
import Foundation
import SwiftUI

/// Lightweight multi-language highlighting for clipboard snippets. It intentionally colors only
/// lexical forms common across Swift, JavaScript/TypeScript, Python, C-family languages, Rust, Go,
/// SQL, shell, JSON, and markup; unknown syntax remains the native primary text color.
enum CodeSyntaxHighlighter {
    private enum TokenStyle {
        case orange
        case secondary
        case red
        case blue
        case purple
        case teal
        case indigo

        var swiftUIColor: Color {
            switch self {
            case .orange: .orange
            case .secondary: .secondary
            case .red: .red
            case .blue: .blue
            case .purple: .purple
            case .teal: .teal
            case .indigo: .indigo
            }
        }

        var appKitColor: NSColor {
            switch self {
            case .orange: .systemOrange
            case .secondary: .secondaryLabelColor
            case .red: .systemRed
            case .blue: .systemBlue
            case .purple: .systemPurple
            case .teal: .systemTeal
            case .indigo: .systemIndigo
            }
        }
    }

    private struct Rule {
        let expression: NSRegularExpression
        let style: TokenStyle
    }

    private struct Token {
        let range: NSRange
        let style: TokenStyle
        let priority: Int
    }

    /// Rules are ordered for ties at the same UTF-16 offset. The scanner always consumes the
    /// earliest next token, so a quote before `//` wins as a string while a comment opener before
    /// a quote wins as a comment; tokens inside either are never recolored.
    private static let rules: [Rule] = [
        rule(#"(?m)^[\t ]*[#](?:include|define|if|ifdef|ifndef|endif|pragma|!)[^\n]*"#, .orange),
        rule(#"(?s:/\*.*?\*/)|(?m://[^\n]*|^[\t ]*[#][^\n]*)"#, .secondary),
        rule(#"`(?:\\.|[^`\\])*`|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, .red),
        rule(#"\b(?:0x[0-9A-Fa-f]+|0b[01]+|\d+(?:\.\d+)?)\b"#, .blue),
        rule(
            #"\b(?:import|from|export|default|as|const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|class|struct|enum|protocol|extension|func|guard|defer|throw|throws|try|catch|async|await|in|is|nil|self|super|true|false|null|undefined|new|typeof|instanceof|def|lambda|with|yield|pass|raise|public|private|protected|internal|static|final|override|mutating|where|associatedtype|some|any|interface|type|implements|extends|package|use|mod|pub|fn|match|impl|trait|dyn|SELECT|FROM|WHERE|JOIN|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|VALUES|INTO|AND|OR|NOT|AS|NULL)\b"#,
            .purple),
        rule(#"\b[A-Z][A-Za-z0-9_]*\b"#, .teal),
        rule(#"\b[A-Za-z_$][A-Za-z0-9_$]*(?=[\t ]*\()"#, .indigo),
    ]

    private static func rule(_ pattern: String, _ style: TokenStyle) -> Rule {
        // Every pattern is a source literal covered by the render smoke test. Falling back to a
        // never-matching expression keeps a typo from crashing the app when a code row is selected.
        let expression =
            (try? NSRegularExpression(pattern: pattern))
            ?? (try! NSRegularExpression(pattern: "(?!)"))
        return Rule(expression: expression, style: style)
    }

    static func highlight(_ source: String) -> AttributedString {
        var output = AttributedString(source)
        output.foregroundColor = .primary
        for token in highlightedTokens(in: source) {
            guard !Task.isCancelled else { return output }
            let tokenRange = token.range
            guard let stringRange = Range(tokenRange, in: source),
                let lower = AttributedString.Index(stringRange.lowerBound, within: output),
                let upper = AttributedString.Index(stringRange.upperBound, within: output)
            else { continue }
            output[lower..<upper].foregroundColor = token.style.swiftUIColor
        }
        return output
    }

    /// AppKit variant used by the Markdown renderer. The caller's font, background, and paragraph
    /// styling remain intact while the same token rules and colors as `CodePreview` are applied.
    static func highlight(
        _ source: String,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSMutableAttributedString {
        let output = NSMutableAttributedString(string: source, attributes: attributes)
        for token in highlightedTokens(in: source) {
            guard !Task.isCancelled else { return output }
            output.addAttribute(
                .foregroundColor, value: token.style.appKitColor, range: token.range)
        }
        return output
    }

    private static func highlightedTokens(in source: String) -> [Token] {
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        var tokens: [Token] = []
        for (priority, rule) in rules.enumerated() {
            guard !Task.isCancelled else { return [] }
            for match in rule.expression.matches(in: source, range: fullRange) {
                tokens.append(Token(range: match.range, style: rule.style, priority: priority))
            }
        }
        tokens.sort {
            $0.range.location == $1.range.location
                ? $0.priority < $1.priority : $0.range.location < $1.range.location
        }

        var highlighted: [Token] = []
        var consumedThrough = 0
        for token in tokens {
            guard !Task.isCancelled else { return highlighted }
            guard token.range.location >= consumedThrough else { continue }
            highlighted.append(token)
            consumedThrough = NSMaxRange(token.range)
        }
        return highlighted
    }
}

struct CodePreview: View {
    let code: String
    var query: String = ""
    var fontSize: CGFloat? = nil
    var scrollPosition: CGPoint? = nil
    var selection: NSRange? = nil
    var onScroll: ((CGPoint) -> Void)? = nil
    var onSelectionChange: ((NSRange) -> Void)? = nil
    @State private var highlighted: AttributedString?

    private struct RenderID: Hashable {
        let code: String
        let query: String
    }

    private struct Rendered: @unchecked Sendable {
        let value: AttributedString
    }

    var body: some View {
        SelectableAttributedText(
            attributed: highlighted ?? AttributedString(code),
            fontSize: fontSize,
            scrollPosition: scrollPosition,
            selection: selection,
            onScroll: onScroll,
            onSelectionChange: onSelectionChange)
        .task(id: RenderID(code: code, query: query)) {
            highlighted = nil
            let task = Task.detached(priority: .userInitiated) {
                var attributed = CodeSyntaxHighlighter.highlight(code)
                SearchHighlight.apply(to: &attributed, source: code, query: query)
                return Rendered(value: attributed)
            }
            let rendered = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled else { return }
            highlighted = rendered.value
        }
    }
}
