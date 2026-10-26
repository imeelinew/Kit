import Foundation

struct ClipboardItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case text, markdown, code, link, path, image, file

        var typeLabel: String {
            switch self {
            case .text: "Text"
            case .markdown: "Markdown"
            case .code: "Code"
            case .link: "Link"
            case .path: "Path"
            case .image: "Image"
            case .file: "File"
            }
        }
    }

    let id: UUID
    private(set) var kind: Kind
    let text: String?
    /// Absolute path to the image owned by this store.
    let imagePath: String?
    /// SHA-256 of canonical visible pixels. Text rows leave it nil.
    let imageFingerprint: String?
    /// Ordered source file URLs captured as one clipboard entry.
    let fileURLs: [URL]
    private(set) var fileIsImage: Bool
    let firstCopiedAt: Date
    private(set) var lastCopiedAt: Date
    private(set) var copyCount: Int
    /// Bundle ID of the app frontmost when the copy was captured (see `ClipboardManager.poll`).
    private(set) var sourceBundleID: String?
    /// User-assigned list title. Nil means the visible title is derived from the copied content.
    let customTitle: String?
    /// OCR metadata belongs to either a stored image or an image-capable file reference
    private(set) var imageOCR: ClipboardImageOCR?

    init(text: String, kind: Kind, sourceBundleID: String?) {
        self.init(
            id: UUID(), kind: kind, text: text,
            imagePath: nil, imageFingerprint: nil, fileURLs: [], lastCopiedAt: Date(),
            sourceBundleID: sourceBundleID)
    }

    init(imagePath: String, imageFingerprint: String, sourceBundleID: String?) {
        self.init(
            id: UUID(), kind: .image, text: nil, imagePath: imagePath,
            imageFingerprint: imageFingerprint, fileURLs: [], lastCopiedAt: Date(),
            sourceBundleID: sourceBundleID)
    }

    init(
        id: UUID, kind: Kind, text: String?, imagePath: String?, imageFingerprint: String?,
        fileURLs: [URL] = [], fileIsImage: Bool = false, lastCopiedAt: Date, sourceBundleID: String?,
        customTitle: String? = nil, firstCopiedAt: Date? = nil, copyCount: Int = 1,
        imageOCR: ClipboardImageOCR? = nil
    ) {
        self.id = id
        self.kind = fileURLs.isEmpty ? kind : .file
        self.text = text
        self.imagePath = imagePath
        self.imageFingerprint = imageFingerprint
        self.fileURLs = fileURLs
        self.fileIsImage = fileURLs.count == 1 && (fileIsImage || kind == .image)
        self.firstCopiedAt = firstCopiedAt ?? lastCopiedAt
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
        self.imageOCR = imageOCR
        self.sourceBundleID = sourceBundleID
        self.customTitle = customTitle
    }

    var isFileBacked: Bool { !fileURLs.isEmpty }

    /// Preview capabilities do not determine the clipboard payload category
    var hasImagePreview: Bool { kind == .image || (isFileBacked && fileIsImage) }

    var typeLabel: String {
        fileURLs.count > 1 ? "Files" : fileIsImage ? "Image File" : kind.typeLabel
    }

    /// An external recopy reuses the entry with a fresh copy time and source application.
    func recopied(at date: Date = Date(), sourceBundleID: String?) -> ClipboardItem {
        var copy = self
        copy.lastCopiedAt = date
        copy.copyCount += 1
        copy.sourceBundleID = sourceBundleID
        return copy
    }

    func withKind(_ kind: Kind) -> ClipboardItem {
        var copy = self
        copy.kind = isFileBacked ? .file : kind
        return copy
    }

    func withFileImagePreview(_ enabled: Bool) -> ClipboardItem {
        var copy = self
        copy.fileIsImage = isFileBacked && fileURLs.count == 1 && enabled
        return copy
    }

    func withImageOCR(_ metadata: ClipboardImageOCR?) -> ClipboardItem {
        var copy = self
        copy.imageOCR = metadata
        return copy
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
        if isFileBacked {
            return fileURLs.map(\.lastPathComponent).joined(separator: ", ")
        }
        switch kind {
        case .image:
            return AppLocalization.string("Image", locale: locale)
        case .text, .markdown, .code, .link, .path, .file:
            let text = String((text ?? "").prefix(200)).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let lineEnd = text.firstIndex(where: { $0.isNewline }) ?? text.endIndex
            return String(text[..<lineEnd])
        }
    }

    /// Case-insensitive literal or pinyin match for resident and pinned entries.
    /// Latin-letter queries also match Mandarin pinyin (full spelling or initials) so `nihao` / `nh` can find `你好`.
    func matches(_ query: String, includeImageText: Bool = true) -> Bool {
        if matches(query, in: customTitle) { return true }
        if includeImageText, hasImagePreview,
            matches(ClipboardImageTextRecognition.normalizedText(query), in: imageOCR?.text)
        { return true }
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
