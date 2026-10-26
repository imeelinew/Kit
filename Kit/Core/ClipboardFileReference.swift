import AppKit
import Darwin

/// Keeps the original NSURL objects and their access scopes alive through pasteboard delivery
final class FileAccessLease: @unchecked Sendable {
    let urls: [NSURL]
    let signatures: [String]
    private let scopedURLs: [NSURL]
    private let retainedLeases: [FileAccessLease]

    init(urls: [NSURL], scopedURLs: [NSURL] = [], retaining: [FileAccessLease] = [], signatures: [String] = []) {
        self.urls = urls
        self.signatures = signatures
        self.scopedURLs = scopedURLs
        self.retainedLeases = retaining
    }

    /// Revalidate after activation or any other suspension before changing the pasteboard
    func isCurrent() async -> Bool {
        guard !Task.isCancelled else { return false }
        let worker = Task.detached(priority: .userInitiated) { [self] in
            for (index, nativeURL) in urls.enumerated() {
                guard !Task.isCancelled else { return false }
                let url = nativeURL as URL
                guard ClipboardFileReference.availability(of: url) == .available else { return false }
                if signatures.indices.contains(index),
                    ImageThumbnail.sourceSignature(for: url) != signatures[index] { return false }
            }
            return !urls.isEmpty
        }
        let valid = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        return valid && !Task.isCancelled
    }

    deinit {
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
    }
}

/// Noninteractive file access shared by capture, previews, OCR and delivery
enum ClipboardFileReference {
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
        let requiredAccess = (metadata.st_mode & S_IFMT) == S_IFDIR ? R_OK | X_OK : R_OK
        guard access(url.path, requiredAccess) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            case EACCES, EPERM: return .needsPermission
            default: return .unavailable
            }
        }
        return .available
    }

    nonisolated private static func resolve(_ data: Data?) -> NSURL? {
        guard let data else { return nil }
        var stale: ObjCBool = false
        return try? NSURL(
            resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    struct Preparation: Sendable {
        let lease: FileAccessLease?
        let states: [Availability]
        let bookmarks: [String: Data]
    }

    /// Filesystem work stays off the main actor, including noninteractive preview access
    nonisolated static func prepare(
        urls originals: [URL], bookmarks stored: [String: Data], refreshCredentials: Bool
    ) -> Preparation {
        var bookmarks = stored
        var urls: [NSURL] = []
        var scopedURLs: [NSURL] = []
        var states: [Availability] = []
        var signatures: [String] = []
        for original in originals {
            guard !Task.isCancelled else { break }
            let originalKey = key(original as NSURL)
            let credential = resolve(bookmarks[originalKey])
            if let credential, credential.startAccessingSecurityScopedResource() {
                scopedURLs.append(credential)
            }
            let state = availability(of: original)
            states.append(state)
            guard state == .available else { continue }
            let signature = ImageThumbnail.sourceSignature(for: original)
            var delivery = original as NSURL
            // Never deliver a bookmark that now points at a different recorded address
            if let credential, key(credential) == originalKey {
                delivery = credential
            }
            // Refresh delivery credentials only for explicit actions, not each preview poll
            if refreshCredentials, let data = capture([original as NSURL])[originalKey],
                let current = resolve(data), key(current) == originalKey
            {
                if current.startAccessingSecurityScopedResource() { scopedURLs.append(current) }
                delivery = current
                bookmarks[originalKey] = data
            }
            guard availability(of: original) == .available,
                ImageThumbnail.sourceSignature(for: original) == signature else {
                let current = availability(of: original)
                states[states.count - 1] = current == .available ? .unavailable : current
                continue
            }
            urls.append(delivery)
            signatures.append(signature)
        }
        let lease = FileAccessLease(urls: urls, scopedURLs: scopedURLs, signatures: signatures)
        return Preparation(lease: urls.isEmpty ? nil : lease, states: states, bookmarks: bookmarks)
    }

}
