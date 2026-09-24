import Foundation

struct ClipboardItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case text, markdown, code, link, path, image

        var typeLabel: String {
            switch self {
            case .text: "Plain Text"
            case .markdown: "Markdown"
            case .code: "Code"
            case .link: "Link"
            case .path: "Path"
            case .image: "Image"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let text: String?
    /// Absolute path to the image owned by this store.
    let imagePath: String?
    /// SHA-256 of canonical visible pixels. Text rows leave it nil.
    let imageFingerprint: String?
    let createdAt: Date
    /// Bundle ID of the app frontmost when the copy was captured (see `ClipboardManager.poll`).
    let sourceBundleID: String?
    /// User-assigned list title. Nil means the visible title is derived from the copied content.
    let customTitle: String?

    init(text: String, kind: Kind, sourceBundleID: String?) {
        self.init(
            id: UUID(), kind: kind, text: text,
            imagePath: nil, imageFingerprint: nil, createdAt: Date(),
            sourceBundleID: sourceBundleID)
    }

    init(imagePath: String, imageFingerprint: String, sourceBundleID: String?) {
        self.init(
            id: UUID(), kind: .image, text: nil, imagePath: imagePath,
            imageFingerprint: imageFingerprint, createdAt: Date(), sourceBundleID: sourceBundleID)
    }

    init(
        id: UUID, kind: Kind, text: String?, imagePath: String?, imageFingerprint: String?,
        createdAt: Date, sourceBundleID: String?,
        customTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imagePath = imagePath
        self.imageFingerprint = imageFingerprint
        self.createdAt = createdAt
        self.sourceBundleID = sourceBundleID
        self.customTitle = customTitle
    }

    func with(createdAt: Date) -> ClipboardItem {
        ClipboardItem(
            id: id, kind: kind, text: text, imagePath: imagePath,
            imageFingerprint: imageFingerprint, createdAt: createdAt,
            sourceBundleID: sourceBundleID, customTitle: customTitle)
    }

    /// A repeated image is the same entry with a fresh copy time and source application.
    func refreshed(sourceBundleID: String?) -> ClipboardItem {
        ClipboardItem(
            id: id, kind: kind, text: text, imagePath: imagePath,
            imageFingerprint: imageFingerprint, createdAt: Date(),
            sourceBundleID: sourceBundleID, customTitle: customTitle)
    }

    /// Visible list/card title: a persisted custom name, otherwise the first line of text or "Image".
    func displayTitle(locale: Locale) -> String {
        if let customTitle {
            let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return defaultTitle(locale: locale)
    }

    func defaultTitle(locale: Locale) -> String {
        switch kind {
        case .image:
            return String(localized: "Image", locale: locale)
        case .text, .markdown, .code, .link, .path:
            let text = String((text ?? "").prefix(200)).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let lineEnd = text.firstIndex(where: { $0.isNewline }) ?? text.endIndex
            return String(text[..<lineEnd])
        }
    }

    /// Case-insensitive literal or pinyin match for resident and pinned entries.
    /// Latin-letter queries also match Mandarin pinyin (full spelling or initials) so `nihao` / `nh` can find `你好`.
    func matches(_ query: String) -> Bool {
        if matches(query, in: customTitle) { return true }
        guard let text else { return false }
        return matches(query, in: text)
    }

    private func matches(_ query: String, in text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        if text.localizedCaseInsensitiveContains(query) { return true }
        guard Pinyin.queryLooksLatin(query) else { return false }
        return Pinyin.matches(query: query, text: text)
    }
}

/// How long clipboard history is kept before pruning; raw value is the age in days persisted to UserDefaults, and `forever` is -1 so an unset key (0) falls through to the default.
enum ClipboardRetention: Int, CaseIterable, Identifiable, Sendable {
    case day = 1
    case week = 7
    case month = 30
    case threeMonths = 90
    case sixMonths = 180
    case year = 365
    case forever = -1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .day: return "1 Day"
        case .week: return "1 Week"
        case .month: return "1 Month"
        case .threeMonths: return "3 Months"
        case .sixMonths: return "6 Months"
        case .year: return "1 Year"
        case .forever: return "Forever"
        }
    }

    var maxAge: TimeInterval {
        self == .forever ? .greatestFiniteMagnitude : TimeInterval(rawValue) * 86_400
    }
}

/// A named group. An item belongs to at most one stack.
struct ClipboardStack: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    var name: String
}
