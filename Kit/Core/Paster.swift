import AppKit
import Carbon.HIToolbox
import OSLog

enum Paster {
    /// Stamped on Kit's own synthetic keystrokes so listeners can ignore them.
    static let pasteEventTag: Int64 = 0x50415354  // "PAST"
    private static let finderBundleID = "com.apple.finder"
    private static let logger = Logger(subsystem: "com.eli.Kit", category: "ClipboardTransfer")

    private enum Payload: Sendable {
        case text(String)
        case image(Data)
        case files([URL])
    }

    /// Prepare, target, write, and deliver as one ordered transaction. The caller hides the palette
    /// only after permission and payload preparation succeed. Reusing history preserves its
    /// source, while successful delivery updates history according to the preference.
    @MainActor @discardableResult
    static func paste(
        _ item: ClipboardItem, store: ClipboardStore, previousApp app: NSRunningApplication,
        keepingPaletteOpen: Bool = false, willDeliver: () -> Void = {}
    ) async -> Bool {
        guard !app.isTerminated else { return false }
        let pid = app.processIdentifier
        return await PasteTransaction.run(
            permission: Permissions.ensureAccessibility,
            prepare: { await prepare(item, store: store, targetBundleID: app.bundleIdentifier) },
            willDeliver: willDeliver,
            targetReady: {
                if keepingPaletteOpen { return !app.isTerminated }
                return await activateAndWait(app)
            },
            write: write,
            deliver: { postCommandV(toPid: pid) },
            didDeliver: { store.recordHistoryAction(id: item.id, deferPublication: keepingPaletteOpen) })
    }

    /// Paste directly into our own field editors and restore the saved selection before delivery
    @MainActor @discardableResult
    static func paste(
        _ item: ClipboardItem, store: ClipboardStore, into target: TextFieldPasteTarget,
        keepingPaletteOpen: Bool = false, willDeliver: () -> Void = {}
    ) async -> Bool {
        await PasteTransaction.run(
            permission: { true },
            prepare: { await prepare(item, store: store, targetBundleID: Bundle.main.bundleIdentifier) },
            willDeliver: willDeliver,
            targetReady: { target.restoreEditing(activateWindow: !keepingPaletteOpen) },
            write: write,
            deliver: { target.paste() },
            didDeliver: { store.recordHistoryAction(id: item.id, deferPublication: keepingPaletteOpen) })
    }

    /// Put the item on the pasteboard without pasting. Image bytes are loaded before the caller
    /// hides the palette, so a missing or large file never creates a blank-looking action.
    @MainActor @discardableResult
    static func copy(
        _ item: ClipboardItem, store: ClipboardStore, willWrite: () -> Void
    ) async -> Bool {
        logger.info("Copy requested kind=\(item.kind.rawValue, privacy: .public) files=\(item.fileURLs.count)")
        guard let payload = await prepare(item, store: store, targetBundleID: nil),
            !Task.isCancelled
        else {
            logger.error("Copy stopped before writing cancelled=\(Task.isCancelled)")
            return false
        }
        willWrite()
        guard write(payload) else { return false }
        store.recordHistoryAction(id: item.id)
        return true
    }

    /// Identify a native text selection copy without suppressing its capture
    @MainActor
    static func markCurrentPasteboardSelection() {
        let pasteboard = NSPasteboard.general
        pasteboard.addTypes([ClipboardCapturePolicy.selectionType], owner: nil)
        _ = pasteboard.setData(Data(), forType: ClipboardCapturePolicy.selectionType)
    }

    @MainActor
    private static func prepare(
        _ item: ClipboardItem, store: ClipboardStore, targetBundleID: String?
    ) async -> Payload? {
        // File-backed images retain their original filename and file identity
        if item.isFileBacked {
            let urls = item.fileURLs
            // Copying references must not require Kit to read protected source folders
            // The receiving application resolves the URLs and reports unavailable files
            guard urls.allSatisfy(\.isFileURL) else { return nil }
            return .files(urls)
        }
        switch item.kind {
        case .text, .markdown, .code, .link, .path:
            return item.text.map(Payload.text)
        case .image:
            guard let url = store.imageURL(for: item) else { return nil }
            if targetBundleID == finderBundleID {
                guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
                return .files([url])
            }
            return await imagePayload(at: url)
        case .file:
            return nil
        }
    }

    private static func imagePayload(at url: URL) async -> Payload? {
        let task = Task.detached(priority: .userInitiated) { () -> Payload? in
            guard !Task.isCancelled,
                let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
            else { return nil }
            return Payload.image(data)
        }
        let payload = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return Task.isCancelled ? nil : payload
    }

    /// Wait for the target's actual activation state instead of guessing with a fixed delay.
    @MainActor
    private static func activateAndWait(_ app: NSRunningApplication) async -> Bool {
        guard !app.isTerminated else { return false }
        if app.isActive { return true }
        guard app.activate() else { return false }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(800))
        while !app.isActive {
            guard !app.isTerminated, clock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// The pasteboard is mutated only after payload and target preflight have succeeded.
    @MainActor @discardableResult
    private static func write(_ payload: Payload) -> Bool {
        // Validate the complete reference collection without accessing source files
        if case .files(let urls) = payload {
            guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        switch payload {
        case .text(let text):
            pb.declareTypes([.string, ClipboardManager.internalType], owner: nil)
            guard pb.setString(text, forType: .string) else { return false }
        case .image(let data):
            pb.declareTypes([.png, ClipboardManager.internalType], owner: nil)
            guard pb.setData(data, forType: .png) else { return false }
        case .files(let urls):
            guard pb.writeObjects(urls.map { $0 as NSURL }) else {
                logger.error("File pasteboard write failed count=\(urls.count)")
                return false
            }
            pb.addTypes([ClipboardManager.internalType], owner: nil)
            let readableFiles = pb.pasteboardItems?.filter {
                $0.string(forType: .fileURL) != nil
            }.count ?? 0
            logger.notice("File pasteboard write requested=\(urls.count) readable=\(readableFiles)")
        }
        return pb.setData(Data(), forType: ClipboardManager.internalType)
    }

    /// Synthesize ⌘V for the target process after the transaction has checked permission.
    @MainActor
    private static func postCommandV(toPid pid: pid_t) -> Bool {
        guard Permissions.isAccessibilityTrusted() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: pasteEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: pasteEventTag)

        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}
