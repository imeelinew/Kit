import AppKit
import OSLog

@MainActor
enum ClipboardFileAccess {
    private static let logger = Logger(subsystem: "com.eli.Kit", category: "ClipboardTransfer")

    typealias Availability = ClipboardFileReference.Availability

    nonisolated static func key(_ url: NSURL) -> String { ClipboardFileReference.key(url) }
    nonisolated static func capture(_ urls: [NSURL]) -> [String: Data] { ClipboardFileReference.capture(urls) }
    nonisolated static func availability(of url: URL) -> Availability { ClipboardFileReference.availability(of: url) }

    nonisolated private static func refreshBookmarks(
        _ stored: [String: Data], originals: [URL]
    ) -> [String: Data] {
        var bookmarks = stored
        let pasteboard = NSPasteboard.general
        if !(pasteboard.types ?? []).contains(ClipboardCapturePolicy.internalType),
            (pasteboard.types ?? []).contains(.fileURL),
            let nativeURLs = pasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL]
        {
            let wanted = Set(originals.map { key($0 as NSURL) })
            bookmarks.merge(capture(nativeURLs.filter { wanted.contains(key($0)) })) { _, new in new }
        }
        return bookmarks
    }

    /// Credentials grant access, while delivery always refers to the original recorded address
    static func acquire(
        _ item: ClipboardItem, store: ClipboardStore, interactive: Bool = true
    ) async -> FileAccessLease? {
        guard !Task.isCancelled else { return nil }
        var bookmarks = store.fileBookmarks(for: item.id)
        var grants: [FileAccessLease] = []
        defer { withExtendedLifetime(grants) {} }
        while !Task.isCancelled {
            let currentBookmarks = bookmarks
            let worker = Task.detached(priority: .userInitiated) {
                let credentials = interactive
                    ? refreshBookmarks(currentBookmarks, originals: item.fileURLs) : currentBookmarks
                return ClipboardFileReference.prepare(
                    urls: item.fileURLs, bookmarks: credentials, refreshCredentials: interactive)
            }
            let prepared = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return nil }
            bookmarks = prepared.bookmarks
            if interactive, let index = prepared.states.firstIndex(of: .needsPermission) {
                let original = item.fileURLs[index]
                guard let selected = authorize(original), !Task.isCancelled else { return nil }
                let started = selected.startAccessingSecurityScopedResource()
                let grant = FileAccessLease(urls: [selected], scopedURLs: started ? [selected] : [])
                grants.append(grant)
                let result = await Task.detached(priority: .userInitiated) {
                    (capture(grant.urls), availability(of: original))
                }.value
                guard !Task.isCancelled else { return nil }
                guard result.1 == .available else {
                    showFailure(filename: original.lastPathComponent)
                    return nil
                }
                bookmarks.merge(result.0) { _, new in new }
                continue
            }
            guard let lease = prepared.lease else {
                if interactive {
                    showUnavailable(filename: item.fileURLs.count == 1 ? item.fileURLs.first?.lastPathComponent : nil)
                }
                return nil
            }
            if interactive, !store.rememberFileBookmarks(bookmarks, for: item.id) {
                logger.error("Could not persist file access credentials")
            }
            // Keep any explicit grants alive for the consumer as well
            return FileAccessLease(urls: lease.urls, retaining: [lease] + grants, signatures: lease.signatures)
        }
        return nil
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
