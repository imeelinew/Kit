import AppKit
import OSLog

/// Keeps the original NSURL objects and their access scopes alive through pasteboard delivery
final class FileAccessLease: @unchecked Sendable {
    let urls: [NSURL]
    private let scopedURLs: [NSURL]

    init(urls: [NSURL], scopedURLs: [NSURL] = []) {
        self.urls = urls
        self.scopedURLs = scopedURLs
    }

    deinit {
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
    }
}

@MainActor
enum ClipboardFileAccess {
    private static let logger = Logger(subsystem: "com.eli.Kit", category: "ClipboardTransfer")

    nonisolated static func key(_ url: NSURL) -> String {
        (url.filePathURL ?? (url as URL)).standardizedFileURL.absoluteString
    }

    /// Create credentials before converting the original pasteboard NSURL into a plain path
    nonisolated static func capture(_ urls: [NSURL]) -> [String: Data] {
        var bookmarks: [String: Data] = [:]
        for url in urls {
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            if let data = try? url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil, relativeTo: nil)
            {
                bookmarks[key(url)] = data
            }
        }
        return bookmarks
    }

    static func acquire(_ item: ClipboardItem, store: ClipboardStore) -> FileAccessLease? {
        var bookmarks = store.fileBookmarks(for: item.id)
        // An older history entry can still use credentials on the current native pasteboard
        let pasteboard = NSPasteboard.general
        if !(pasteboard.types ?? []).contains(ClipboardCapturePolicy.internalType),
            (pasteboard.types ?? []).contains(.fileURL),
            let nativeURLs = pasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL]
        {
            let wanted = Set(item.fileURLs.map { key($0 as NSURL) })
            let fresh = capture(nativeURLs.filter { wanted.contains(key($0)) })
            bookmarks.merge(fresh) { _, new in new }
        }

        var urls: [NSURL] = []
        var scopedURLs: [NSURL] = []
        var acquired = false
        defer {
            if !acquired {
                for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
            }
        }
        for original in item.fileURLs {
            guard !Task.isCancelled else { return nil }
            let originalKey = key(original as NSURL)
            var restoredURL: NSURL?
            if let data = bookmarks[originalKey] {
                var stale: ObjCBool = false
                restoredURL = try? NSURL(
                    resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            // Upgrade accessible legacy paths before writing, rather than submitting a bare URL
            if restoredURL == nil, isReadable(original as NSURL),
                let data = capture([original as NSURL])[originalKey]
            {
                var stale: ObjCBool = false
                restoredURL = try? NSURL(
                    resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            var url = restoredURL ?? (original as NSURL)
            var started = url.startAccessingSecurityScopedResource()
            if restoredURL == nil || !isReadable(url) {
                if started { url.stopAccessingSecurityScopedResource() }
                guard let selected = authorize(original) else { return nil }
                url = selected
                started = url.startAccessingSecurityScopedResource()
                guard isReadable(url) else {
                    if started { url.stopAccessingSecurityScopedResource() }
                    showFailure(filename: original.lastPathComponent)
                    return nil
                }
            }
            if started { scopedURLs.append(url) }
            urls.append(url)
            // Refresh stale bookmarks while their scope is active, preserving the history key
            if let data = try? url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil, relativeTo: nil)
            {
                bookmarks[originalKey] = data
            }
        }
        guard !Task.isCancelled else { return nil }
        if !store.rememberFileBookmarks(bookmarks, for: item.id) {
            logger.error("Could not persist file access credentials")
        }
        acquired = true
        return FileAccessLease(urls: urls, scopedURLs: scopedURLs)
    }

    private static func isReadable(_ url: NSURL) -> Bool {
        guard let path = url.path else { return false }
        return FileManager.default.isReadableFile(atPath: path)
    }

    private static func authorize(_ original: URL) -> NSURL? {
        let locale = AppCore.shared.settings.language.locale
        let panel = NSOpenPanel()
        panel.title = String(
            format: AppLocalization.string("Allow Access to %@", locale: locale),
            original.lastPathComponent)
        panel.prompt = AppLocalization.string("Allow Access", locale: locale)
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.directoryURL = original.deletingLastPathComponent()
        panel.nameFieldStringValue = original.lastPathComponent
        NSApp.activate()
        guard AppCore.shared.runFileAccessPanel(panel) == .OK else { return nil }
        guard let chosen = panel.urls.first,
            key(chosen as NSURL) == key(original as NSURL)
        else {
            showFailure(filename: original.lastPathComponent)
            return nil
        }
        return chosen as NSURL
    }

    static func showFailure(filename: String? = nil) {
        guard !Task.isCancelled else { return }
        let locale = AppCore.shared.settings.language.locale
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let filename {
            alert.messageText = String(
                format: AppLocalization.string("Unable to Access %@", locale: locale), filename)
        } else {
            alert.messageText = AppLocalization.string("Unable to Copy Files", locale: locale)
        }
        alert.addButton(withTitle: AppLocalization.string("OK", locale: locale))
        _ = AppCore.shared.runModalAlert(alert)
    }
}
