import AppKit
import Darwin
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

    enum Availability: Sendable, Equatable {
        case available, missing, needsPermission, unavailable
    }

    /// Inspect the original address without mistaking a privacy denial for a missing file
    nonisolated static func availability(of url: URL) -> Availability {
        var metadata = stat()
        guard stat(url.path, &metadata) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            case EACCES, EPERM: return .needsPermission
            default: return .unavailable
            }
        }
        guard access(url.path, R_OK) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            case EACCES, EPERM: return .needsPermission
            default: return .unavailable
            }
        }
        return .available
    }

    private static func resolve(_ data: Data?) -> NSURL? {
        guard let data else { return nil }
        var stale: ObjCBool = false
        return try? NSURL(
            resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Credentials grant access, while delivery always refers to the original recorded address
    static func acquire(
        _ item: ClipboardItem, store: ClipboardStore, interactive: Bool = true
    ) -> FileAccessLease? {
        var bookmarks = store.fileBookmarks(for: item.id)
        if interactive {
            let pasteboard = NSPasteboard.general
            if !(pasteboard.types ?? []).contains(ClipboardCapturePolicy.internalType),
                (pasteboard.types ?? []).contains(.fileURL),
                let nativeURLs = pasteboard.readObjects(
                    forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL]
            {
                let wanted = Set(item.fileURLs.map { key($0 as NSURL) })
                bookmarks.merge(capture(nativeURLs.filter { wanted.contains(key($0)) })) { _, new in new }
            }
        }

        var urls: [NSURL] = []
        var scopedURLs: [NSURL] = []
        var acquired = false
        defer {
            if !acquired {
                for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
            }
        }
        func hold(_ url: NSURL) {
            if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        }
        for original in item.fileURLs {
            guard !Task.isCancelled else { return nil }
            let originalKey = key(original as NSURL)
            let credential = resolve(bookmarks[originalKey])
            if let credential { hold(credential) }
            var state = availability(of: original)
            if case .needsPermission = state {
                guard interactive else { continue }
                guard let selected = authorize(original) else { return nil }
                hold(selected)
                state = availability(of: original)
                if case .needsPermission = state {
                    showFailure(filename: original.lastPathComponent)
                    return nil
                }
            }
            guard case .available = state else { continue }

            // Mint from a fresh path URL, so an old bookmark cannot substitute a moved inode
            var delivery = original as NSURL
            if let data = capture([delivery])[originalKey], let current = resolve(data),
                key(current) == originalKey
            {
                hold(current)
                delivery = current
                bookmarks[originalKey] = data
            } else if let credential, key(credential) == originalKey {
                delivery = credential
            }
            // A file may disappear while its credentials are being refreshed
            guard case .available = availability(of: original) else { continue }
            urls.append(delivery)
        }
        guard !Task.isCancelled else { return nil }
        guard !urls.isEmpty else {
            if interactive {
                showUnavailable(filename: item.fileURLs.count == 1 ? item.fileURLs.first?.lastPathComponent : nil)
            }
            return nil
        }
        if interactive, !store.rememberFileBookmarks(bookmarks, for: item.id) {
            logger.error("Could not persist file access credentials")
        }
        acquired = true
        logger.info("File access prepared requested=\(item.fileURLs.count) available=\(urls.count)")
        return FileAccessLease(urls: urls, scopedURLs: scopedURLs)
    }

    static func showUnavailable(filename: String? = nil) {
        let locale = AppCore.shared.settings.language.locale
        let message = filename.map {
            String(format: AppLocalization.string("File Unavailable: %@", locale: locale), $0)
        } ?? AppLocalization.string("Files Are Unavailable", locale: locale)
        showMessage(message)
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
        let message = filename.map {
            String(format: AppLocalization.string("Unable to Access %@", locale: locale), $0)
        } ?? AppLocalization.string("Unable to Copy Files", locale: locale)
        showMessage(message)
    }

    private static func showMessage(_ message: String) {
        guard !Task.isCancelled else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: AppLocalization.string("OK", locale: AppCore.shared.settings.language.locale))
        _ = AppCore.shared.runModalAlert(alert)
    }
}
