import AppKit
import Combine
import KeyboardShortcuts
import QuartzCore
import SwiftUI

private enum PinnedImageCommand {
    case close
    case closeAll
    case dismiss
    case copy
    case zoomIn
    case zoomOut
    case resetSize

    var allowsKeyRepeat: Bool {
        self == .zoomIn || self == .zoomOut
    }
}

enum PinnedTextStyle: Equatable {
    case plain
    case markdown
    case code
}

private enum PinnedCommandContext {
    case image(url: URL, imageSize: CGSize, preferredLongEdge: () -> CGFloat)
    case text(String, initialSize: CGSize)
}

private struct PinnedTextViewport: Equatable {
    var scrollPosition: CGPoint = .zero
    var selection = NSRange(location: 0, length: 0)
}

private struct PinnedCardRecord: Codable, Identifiable {
    enum Kind: String, Codable {
        case image
        case plain
        case markdown
        case code

        var fileExtension: String {
            self == .image ? "png" : "txt"
        }
    }

    struct Frame: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ frame: NSRect) {
            x = frame.origin.x
            y = frame.origin.y
            width = frame.width
            height = frame.height
        }

        var rect: NSRect {
            NSRect(x: x, y: y, width: width, height: height)
        }
    }

    let id: UUID
    let kind: Kind
    var frame: Frame
    var scrollY: Double
    var selectionLocation: Int
    var selectionLength: Int

    var viewport: PinnedTextViewport {
        PinnedTextViewport(
            scrollPosition: CGPoint(x: 0, y: scrollY),
            selection: NSRange(location: selectionLocation, length: selectionLength)
        )
    }

    var isValid: Bool {
        frame.x.isFinite && frame.y.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0 && scrollY.isFinite && scrollY >= 0
            && selectionLocation >= 0 && selectionLength >= 0
    }
}

/// Small manifest plus one immutable payload file per open card. Payloads are independent from
/// clipboard retention, so an open card survives history cleanup and relaunches after a crash.
@MainActor
private final class PinnedCardSessionStore {
    private struct Manifest: Codable {
        let version: Int
        var cards: [PinnedCardRecord]
    }

    private static let version = 1

    private let payloadDirectory: URL
    private let manifestURL: URL
    private(set) var records: [PinnedCardRecord]

    init() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            preconditionFailure("Paste requires a bundle identifier")
        }
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("pinned-cards", isDirectory: true)
        payloadDirectory = root.appendingPathComponent("payloads", isDirectory: true)
        manifestURL = root.appendingPathComponent("session.json")
        try? FileManager.default.createDirectory(
            at: payloadDirectory, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
            manifest.version == Self.version
        {
            var seen = Set<UUID>()
            records = manifest.cards.filter { $0.isValid && seen.insert($0.id).inserted }
        } else {
            records = []
        }
        removeOrphanedPayloads()
    }

    func writeImagePayload(from source: URL, itemID: UUID) -> URL? {
        let target = payloadURL(itemID: itemID, kind: .image)
        let temporary = payloadDirectory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
            return target
        } catch {
            return nil
        }
    }

    func writeTextPayload(_ text: String, itemID: UUID, kind: PinnedCardRecord.Kind) -> Bool {
        guard kind != .image else { return false }
        do {
            try text.write(
                to: payloadURL(itemID: itemID, kind: kind),
                atomically: true,
                encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    func imageURL(for record: PinnedCardRecord) -> URL? {
        guard record.kind == .image else { return nil }
        let url = payloadURL(for: record)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func text(for record: PinnedCardRecord) -> String? {
        guard record.kind != .image else { return nil }
        return try? String(contentsOf: payloadURL(for: record), encoding: .utf8)
    }

    func add(
        itemID: UUID,
        kind: PinnedCardRecord.Kind,
        frame: NSRect,
        viewport: PinnedTextViewport = PinnedTextViewport()
    ) {
        guard FileManager.default.fileExists(atPath: payloadURL(itemID: itemID, kind: kind).path)
        else { return }
        records.removeAll { $0.id == itemID }
        records.append(
            PinnedCardRecord(
                id: itemID,
                kind: kind,
                frame: PinnedCardRecord.Frame(frame),
                scrollY: viewport.scrollPosition.y,
                selectionLocation: viewport.selection.location,
                selectionLength: viewport.selection.length
            )
        )
        saveNow()
    }

    func remove(itemID: UUID) {
        guard let record = records.first(where: { $0.id == itemID }) else { return }
        records.removeAll { $0.id == itemID }
        saveNow()
        try? FileManager.default.removeItem(at: payloadURL(for: record))
    }

    @discardableResult
    func updateFrame(itemID: UUID, frame: NSRect) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == itemID }) else { return false }
        let stored = records[index].frame.rect
        guard abs(stored.minX - frame.minX) > 0.5 || abs(stored.minY - frame.minY) > 0.5
            || abs(stored.width - frame.width) > 0.5 || abs(stored.height - frame.height) > 0.5
        else { return false }
        records[index].frame = PinnedCardRecord.Frame(frame)
        return true
    }

    @discardableResult
    func updateViewport(itemID: UUID, viewport: PinnedTextViewport) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == itemID }) else { return false }
        let record = records[index]
        guard abs(record.scrollY - viewport.scrollPosition.y) > 0.5
            || record.selectionLocation != viewport.selection.location
            || record.selectionLength != viewport.selection.length
        else { return false }
        records[index].scrollY = viewport.scrollPosition.y
        records[index].selectionLocation = viewport.selection.location
        records[index].selectionLength = viewport.selection.length
        return true
    }

    @discardableResult
    func bringToFront(itemID: UUID) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == itemID }),
            index != records.endIndex - 1
        else { return false }
        let record = records.remove(at: index)
        records.append(record)
        return true
    }

    func saveNow() {
        let manifest = Manifest(version: Self.version, cards: records)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func payloadURL(for record: PinnedCardRecord) -> URL {
        payloadURL(itemID: record.id, kind: record.kind)
    }

    private func payloadURL(itemID: UUID, kind: PinnedCardRecord.Kind) -> URL {
        payloadDirectory.appendingPathComponent(
            itemID.uuidString + "." + kind.fileExtension,
            isDirectory: false)
    }

    private func removeOrphanedPayloads() {
        let expected = Set(records.map { payloadURL(for: $0).lastPathComponent })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: payloadDirectory,
            includingPropertiesForKeys: nil,
            options: [])
        else { return }
        for file in files where !expected.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

struct PinnedCardInfo: Sendable {
    let id: UUID
    let kind: String
    let title: String
    let visible: Bool
    let parked: Bool
}

/// Owns durable pinned-content panels independently from the clipboard palette. Each clipboard
/// item gets at most one panel; pinning it again brings the existing panel forward. Open panels
/// restore after relaunch, follow regular Spaces, and hide on exclusive fullscreen Spaces.
@MainActor
final class PinnedImageWindowController: NSObject, NSWindowDelegate {
    private var panels: [ClipboardItem.ID: PinnedImagePanel] = [:]
    private var closingPanels: Set<ClipboardItem.ID> = []
    private var hiddenForFullscreen: Set<ClipboardItem.ID> = []
    private var spaceObservers: [NotificationToken] = []
    private var fullscreenSyncTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var lastPersistenceSave = Date.distantPast
    private var observesExclusiveFullScreen = false
    private var restoredSession = false
    private let sessionStore = PinnedCardSessionStore()
    private var titleObserver: AnyCancellable?
    private var opacityObserver: AnyCancellable?
    private var parkedHomeFrames: [ClipboardItem.ID: NSRect] = [:]
    private var isUnparking = false

    func restore() {
        guard !restoredSession else { return }
        restoredSession = true
        observeExclusiveFullScreenIfNeeded()
        observeTitlesIfNeeded()
        observeOpacityIfNeeded()

        for record in sessionStore.records {
            let restored: Bool
            switch record.kind {
            case .image:
                restored = restoreImage(record)
            case .plain:
                restored = restoreText(record, style: .plain)
            case .markdown:
                restored = restoreText(record, style: .markdown)
            case .code:
                restored = restoreText(record, style: .code)
            }
            if !restored {
                sessionStore.remove(itemID: record.id)
            }
        }
    }

    func flushPersistence() {
        persistParkedHomeFrames()
        persistenceTask?.cancel()
        persistenceTask = nil
        sessionStore.saveNow()
        lastPersistenceSave = Date()
    }

    func toggleParked() {
        if isParked {
            unpark()
        } else {
            park()
        }
    }

    var areParked: Bool { isParked }

    func parkCards() {
        if !isParked { park() }
    }

    func unparkCards() {
        if isParked { unpark() }
    }

    func cardInfos() -> [PinnedCardInfo] {
        let locale = AppCore.shared.settings.language.locale
        let store = AppCore.shared.clipboardStore
        return sessionStore.records.map { record in
            let title = store.item(id: record.id)?.displayTitle(locale: locale) ?? ""
            let panel = panels[record.id]
            return PinnedCardInfo(
                id: record.id,
                kind: record.kind.rawValue,
                title: title,
                visible: panel?.isVisible == true
                    && parkedHomeFrames[record.id] == nil
                    && !hiddenForFullscreen.contains(record.id),
                parked: parkedHomeFrames[record.id] != nil
            )
        }
    }

    @discardableResult
    func closeCard(_ itemID: ClipboardItem.ID) -> Bool {
        let known =
            panels[itemID] != nil
            || sessionStore.records.contains { $0.id == itemID }
        guard known else { return false }
        close(itemID)
        return true
    }

    @discardableResult
    func closeAllCards() -> Int {
        let ids = Set(panels.keys).union(sessionStore.records.map(\.id))
        for id in ids { close(id) }
        return ids.count
    }

    func show(
        itemID: ClipboardItem.ID,
        url: URL,
        title: String,
        preferredLongEdge: @escaping () -> CGFloat
    ) {
        observeExclusiveFullScreenIfNeeded()
        observeTitlesIfNeeded()
        observeOpacityIfNeeded()
        if let panel = panels[itemID] {
            reveal(panel, itemID: itemID)
            return
        }

        let storedURL = sessionStore.writeImagePayload(from: url, itemID: itemID)
        let contentURL = storedURL ?? url
        let visibleFrame = targetVisibleFrame()
        let pixelSize = ImageThumbnail.pixelSize(of: contentURL) ?? CGSize(width: 1_200, height: 900)
        let imageSize = NSImage(contentsOf: contentURL)?.size ?? pixelSize
        let initialSize = PinnedImageLayout.initialSize(
            imageSize: imageSize,
            visibleFrame: visibleFrame,
            preferredLongEdge: preferredLongEdge()
        )
        let panel = makePanel(
            title: title,
            initialSize: initialSize,
            aspectRatio: imageSize,
            minSize: PinnedImageLayout.minimumSize(
                imageSize: imageSize,
                visibleFrame: visibleFrame
            )
        )
        panel.onCommand = { [weak self] command in
            self?.handle(
                command,
                itemID: itemID,
                context: .image(
                    url: contentURL, imageSize: imageSize, preferredLongEdge: preferredLongEdge)
            )
        }

        install(
            PinnedImageContent(
                itemID: itemID,
                url: contentURL,
                decodeMaxPixel: imageDecodeMaxPixel,
                onClose: { [weak self] in self?.close(itemID) }
            ),
            in: panel
        )
        let frame = present(panel, size: initialSize, in: visibleFrame, itemID: itemID)
        if storedURL != nil {
            sessionStore.add(itemID: itemID, kind: .image, frame: frame)
            lastPersistenceSave = Date()
        }
    }

    func showText(
        itemID: ClipboardItem.ID,
        text: String,
        style: PinnedTextStyle,
        title: String
    ) {
        observeExclusiveFullScreenIfNeeded()
        observeTitlesIfNeeded()
        observeOpacityIfNeeded()
        if let panel = panels[itemID] {
            reveal(panel, itemID: itemID)
            return
        }

        let recordKind: PinnedCardRecord.Kind
        switch style {
        case .plain: recordKind = .plain
        case .markdown: recordKind = .markdown
        case .code: recordKind = .code
        }
        let storedPayload = sessionStore.writeTextPayload(
            text, itemID: itemID, kind: recordKind)
        let visibleFrame = targetVisibleFrame()
        let initialSize = PinnedTextLayout.initialSize(
            text: text,
            style: style,
            fontSize: AppCore.shared.settings.pinnedTextSize,
            visibleFrame: visibleFrame
        )
        let panel = makePanel(
            title: title,
            initialSize: initialSize,
            aspectRatio: nil,
            minSize: PinnedTextLayout.minimumSize
        )
        panel.onCommand = { [weak self] command in
            self?.handle(
                command,
                itemID: itemID,
                context: .text(text, initialSize: initialSize)
            )
        }
        install(
            PinnedTextContent(
                itemID: itemID,
                text: text,
                style: style,
                viewport: PinnedTextViewport(),
                onViewportChange: { [weak self] viewport in
                    self?.updateViewport(itemID: itemID, viewport: viewport)
                },
                onClose: { [weak self] in self?.close(itemID) }
            ),
            in: panel
        )
        let frame = present(panel, size: initialSize, in: visibleFrame, itemID: itemID)
        if storedPayload {
            sessionStore.add(itemID: itemID, kind: recordKind, frame: frame)
            lastPersistenceSave = Date()
        }
    }

    private func restoreImage(_ record: PinnedCardRecord) -> Bool {
        guard let url = sessionStore.imageURL(for: record) else { return false }
        let visibleFrame = visibleFrame(for: record.frame.rect)
        let pixelSize = ImageThumbnail.pixelSize(of: url) ?? CGSize(width: 1_200, height: 900)
        let imageSize = NSImage(contentsOf: url)?.size ?? pixelSize
        let settings = AppCore.shared.settings
        let preferredLongEdge: () -> CGFloat = { [weak settings] in
            settings?.pinnedImageSize.longestEdge ?? PinnedImageSize.medium.longestEdge
        }
        let initialSize = PinnedImageLayout.initialSize(
            imageSize: imageSize,
            visibleFrame: visibleFrame,
            preferredLongEdge: preferredLongEdge()
        )
        let panel = makePanel(
            title: cardTitle(for: record.id, fallback: String(
                localized: "Pinned Image", locale: settings.language.locale)),
            initialSize: initialSize,
            aspectRatio: imageSize,
            minSize: PinnedImageLayout.minimumSize(
                imageSize: imageSize,
                visibleFrame: visibleFrame
            )
        )
        panel.onCommand = { [weak self] command in
            self?.handle(
                command,
                itemID: record.id,
                context: .image(
                    url: url,
                    imageSize: imageSize,
                    preferredLongEdge: preferredLongEdge)
            )
        }
        install(
            PinnedImageContent(
                itemID: record.id,
                url: url,
                decodeMaxPixel: imageDecodeMaxPixel,
                onClose: { [weak self] in self?.close(record.id) }
            ),
            in: panel
        )
        restore(panel, record: record)
        return true
    }

    private func restoreText(_ record: PinnedCardRecord, style: PinnedTextStyle) -> Bool {
        guard let text = sessionStore.text(for: record) else { return false }
        let visibleFrame = visibleFrame(for: record.frame.rect)
        let initialSize = PinnedTextLayout.initialSize(
            text: text,
            style: style,
            fontSize: AppCore.shared.settings.pinnedTextSize,
            visibleFrame: visibleFrame
        )
        let fallback =
            switch style {
            case .plain:
                String(
                    localized: "Pinned Text",
                    locale: AppCore.shared.settings.language.locale)
            case .markdown:
                String(
                    localized: "Pinned Markdown",
                    locale: AppCore.shared.settings.language.locale)
            case .code:
                String(
                    localized: "Pinned Code",
                    locale: AppCore.shared.settings.language.locale)
            }
        let panel = makePanel(
            title: cardTitle(for: record.id, fallback: fallback),
            initialSize: initialSize,
            aspectRatio: nil,
            minSize: PinnedTextLayout.minimumSize
        )
        panel.onCommand = { [weak self] command in
            self?.handle(
                command,
                itemID: record.id,
                context: .text(text, initialSize: initialSize)
            )
        }
        var viewport = record.viewport
        if NSMaxRange(viewport.selection) > (text as NSString).length {
            viewport.selection = NSRange(location: 0, length: 0)
        }
        install(
            PinnedTextContent(
                itemID: record.id,
                text: text,
                style: style,
                viewport: viewport,
                onViewportChange: { [weak self] viewport in
                    self?.updateViewport(itemID: record.id, viewport: viewport)
                },
                onClose: { [weak self] in self?.close(record.id) }
            ),
            in: panel
        )
        restore(panel, record: record)
        return true
    }

    private func restore(_ panel: PinnedImagePanel, record: PinnedCardRecord) {
        let frame = restoredFrame(record.frame.rect, minimumSize: panel.contentMinSize)
        applyVisibleAlpha(to: panel)
        panel.setFrame(frame, display: false)
        panels[record.id] = panel
        if hidesForExclusiveFullScreen(panel) {
            hideForFullscreen(record.id, panel)
        } else {
            panel.orderFrontRegardless()
        }
        if sessionStore.updateFrame(itemID: record.id, frame: frame) {
            schedulePersistence()
        }
    }

    private var imageDecodeMaxPixel: CGFloat {
        NSScreen.screens.reduce(CGFloat(1_600)) { result, candidate in
            max(
                result,
                max(candidate.visibleFrame.width, candidate.visibleFrame.height)
                    * candidate.backingScaleFactor
            )
        }
    }

    private func visibleFrame(for frame: NSRect) -> NSRect {
        bestScreen(for: frame)?.visibleFrame ?? targetVisibleFrame()
    }

    private func restoredFrame(_ frame: NSRect, minimumSize: CGSize) -> NSRect {
        let remainsReachable = NSScreen.screens.contains { screen in
            let intersection = screen.frame.intersection(frame)
            return !intersection.isNull && intersection.width >= 44 && intersection.height >= 44
        }
        if remainsReachable, frame.width >= minimumSize.width, frame.height >= minimumSize.height {
            return frame
        }

        let visible = visibleFrame(for: frame)
        let width = min(max(frame.width, minimumSize.width), visible.width)
        let height = min(max(frame.height, minimumSize.height), visible.height)
        return NSRect(
            x: min(max(frame.minX, visible.minX), visible.maxX - width),
            y: min(max(frame.minY, visible.minY), visible.maxY - height),
            width: width,
            height: height
        )
    }

    private func bestScreen(for frame: NSRect) -> NSScreen? {
        let candidates = NSScreen.screens.map { screen in
            let intersection = screen.frame.intersection(frame)
            let area = intersection.isNull ? CGFloat.zero : intersection.width * intersection.height
            return (screen, area)
        }
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
            return NSScreen.main
        }
        return best.0
    }

    private func activate(_ panel: PinnedImagePanel) {
        // Trackpad gesture events are delivered to the active application. The clipboard palette
        // is intentionally non-activating, but an interactive pinned image cannot be: activating
        // here lets AppKit route physical magnify events to this window.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Bring an existing panel forward unless its display is in exclusive fullscreen.
    private func reveal(_ panel: PinnedImagePanel, itemID: ClipboardItem.ID) {
        if isParked { unpark() }
        if hidesForExclusiveFullScreen(panel) {
            hideForFullscreen(itemID, panel)
            return
        }
        hiddenForFullscreen.remove(itemID)
        applyVisibleAlpha(to: panel)
        activate(panel)
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? PinnedImagePanel,
            let itemID = itemID(for: panel)
        else { return }
        panels.removeValue(forKey: itemID)
        closingPanels.remove(itemID)
        hiddenForFullscreen.remove(itemID)
        parkedHomeFrames.removeValue(forKey: itemID)
        if parkedHomeFrames.isEmpty { isUnparking = false }
    }

    func windowDidMove(_ notification: Notification) {
        persistFrame(from: notification)
    }

    func windowDidResize(_ notification: Notification) {
        persistFrame(from: notification)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let panel = notification.object as? PinnedImagePanel,
            let itemID = itemID(for: panel), sessionStore.bringToFront(itemID: itemID)
        else { return }
        schedulePersistence()
    }

    private func close(_ itemID: ClipboardItem.ID) {
        hiddenForFullscreen.remove(itemID)
        guard let panel = panels[itemID], closingPanels.insert(itemID).inserted else { return }
        sessionStore.remove(itemID: itemID)
        lastPersistenceSave = Date()

        panel.ignoresMouseEvents = true
        let targetFrame = Self.scaledFrame(panel.frame, scale: 0.96)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
            panel.animator().setFrame(targetFrame, display: true)
        }

        Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, let panel,
                closingPanels.contains(itemID), panels[itemID] === panel
            else { return }
            panel.close()
        }
    }

    private func itemID(for panel: PinnedImagePanel) -> ClipboardItem.ID? {
        panels.first(where: { $0.value === panel })?.key
    }

    private func persistFrame(from notification: Notification) {
        guard !isParked, let panel = notification.object as? PinnedImagePanel,
            let itemID = itemID(for: panel),
            sessionStore.updateFrame(itemID: itemID, frame: panel.frame)
        else { return }
        schedulePersistence()
    }

    private var isParked: Bool { !parkedHomeFrames.isEmpty }

    private func park() {
        if isUnparking {
            isUnparking = false
            slideParkedCardsOffscreen()
            return
        }

        let candidates = panels.filter { itemID, _ in
            !closingPanels.contains(itemID) && !hiddenForFullscreen.contains(itemID)
        }
        guard !candidates.isEmpty else { return }

        var homes: [ClipboardItem.ID: NSRect] = [:]
        for (itemID, panel) in candidates {
            homes[itemID] = panel.frame
        }
        parkedHomeFrames = homes
        slideParkedCardsOffscreen()
    }

    private func unpark() {
        guard isParked, !isUnparking else { return }
        isUnparking = true
        let homes = parkedHomeFrames.mapValues { frame in
            restoredFrame(frame, minimumSize: CGSize(width: 44, height: 44))
        }
        for (itemID, home) in homes {
            guard let panel = panels[itemID], !closingPanels.contains(itemID) else { continue }
            if !panel.isVisible {
                let screen = bestScreen(for: home)?.frame ?? home
                panel.setFrame(PinnedCardPark.offscreenFrame(home, screen: screen), display: false)
            }
            applyVisibleAlpha(to: panel)
            if hidesForExclusiveFullScreen(panel) {
                hideForFullscreen(itemID, panel)
            } else {
                hiddenForFullscreen.remove(itemID)
                panel.orderFrontRegardless()
            }
        }
        animateParkedFrames(homes) { [weak self] in
            guard let self else { return }
            for (itemID, home) in self.parkedHomeFrames {
                _ = self.sessionStore.updateFrame(itemID: itemID, frame: home)
            }
            self.parkedHomeFrames.removeAll()
            self.isUnparking = false
            self.schedulePersistence()
        }
    }

    private func slideParkedCardsOffscreen() {
        var targets: [ClipboardItem.ID: NSRect] = [:]
        for (itemID, home) in parkedHomeFrames {
            guard panels[itemID] != nil, !closingPanels.contains(itemID) else { continue }
            let screen = bestScreen(for: home)?.frame ?? home
            targets[itemID] = PinnedCardPark.offscreenFrame(home, screen: screen)
        }
        guard !targets.isEmpty else { return }
        animateParkedFrames(targets) { [weak self] in
            guard let self else { return }
            for itemID in self.parkedHomeFrames.keys {
                self.panels[itemID]?.orderOut(nil)
            }
        }
    }

    private func persistParkedHomeFrames() {
        for (itemID, frame) in parkedHomeFrames {
            _ = sessionStore.updateFrame(itemID: itemID, frame: frame)
        }
    }

    private func animateParkedFrames(
        _ frames: [ClipboardItem.ID: NSRect],
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PinnedCardPark.duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
            for (itemID, frame) in frames {
                guard let panel = panels[itemID], !closingPanels.contains(itemID) else { continue }
                panel.animator().setFrame(frame, display: true)
            }
        } completionHandler: {
            Task { @MainActor in
                completion?()
            }
        }
    }

    private func updateViewport(itemID: ClipboardItem.ID, viewport: PinnedTextViewport) {
        guard sessionStore.updateViewport(itemID: itemID, viewport: viewport) else { return }
        schedulePersistence()
    }

    private func schedulePersistence() {
        let interval: TimeInterval = 0.12
        let elapsed = Date().timeIntervalSince(lastPersistenceSave)
        if elapsed >= interval {
            persistenceTask?.cancel()
            persistenceTask = nil
            sessionStore.saveNow()
            lastPersistenceSave = Date()
            return
        }

        persistenceTask?.cancel()
        let delay = max(Int((interval - elapsed) * 1_000), 1)
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self else { return }
            sessionStore.saveNow()
            lastPersistenceSave = Date()
            persistenceTask = nil
        }
    }

    private func handle(
        _ command: PinnedImageCommand,
        itemID: ClipboardItem.ID,
        context: PinnedCommandContext
    ) {
        guard let panel = panels[itemID] else { return }

        switch command {
        case .close, .dismiss:
            close(itemID)
        case .closeAll:
            for id in Array(panels.keys) {
                close(id)
            }
        case .copy:
            copy(from: panel, context: context)
        case .zoomIn:
            panel.resize(by: 1.1)
        case .zoomOut:
            panel.resize(by: 0.9)
        case .resetSize:
            resetSize(of: panel, context: context)
        }
    }

    private func copy(from panel: PinnedImagePanel, context: PinnedCommandContext) {
        switch context {
        case .image(let url, _, _):
            Task { _ = await Paster.copyImage(at: url) }
        case .text(let text, _):
            Paster.copyString(selectedText(in: panel) ?? text)
        }
    }

    private func selectedText(in panel: NSPanel) -> String? {
        var responder: NSResponder? = panel.firstResponder
        while let current = responder {
            if let textView = current as? NSTextView {
                let range = textView.selectedRange()
                guard range.length > 0 else { return nil }
                return (textView.string as NSString).substring(with: range)
            }
            responder = current.nextResponder
        }
        return nil
    }

    private func resetSize(of panel: PinnedImagePanel, context: PinnedCommandContext) {
        let visibleFrame = panel.screen?.visibleFrame ?? targetVisibleFrame()
        let size: CGSize
        switch context {
        case .image(_, let imageSize, let preferredLongEdge):
            size = PinnedImageLayout.initialSize(
                imageSize: imageSize,
                visibleFrame: visibleFrame,
                preferredLongEdge: preferredLongEdge()
            )
        case .text(_, let initialSize):
            size = initialSize
        }
        resetFrame(of: panel, to: size, in: visibleFrame)
    }

    private func resetFrame(of panel: PinnedImagePanel, to size: CGSize, in visibleFrame: CGRect) {
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let origin = CGPoint(
            x: min(max(center.x - size.width / 2, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(center.y - size.height / 2, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
    }

    private func cardTitle(for itemID: ClipboardItem.ID, fallback: String) -> String {
        let locale = AppCore.shared.settings.language.locale
        let title = AppCore.shared.clipboardStore.item(id: itemID)?.displayTitle(locale: locale)
            ?? ""
        return title.isEmpty ? fallback : title
    }

    private func observeTitlesIfNeeded() {
        guard titleObserver == nil else { return }
        titleObserver = AppCore.shared.clipboardStore.$revision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncPanelTitles()
            }
    }

    private func observeOpacityIfNeeded() {
        guard opacityObserver == nil else { return }
        opacityObserver = AppCore.shared.settings.$pinnedWindowOpacity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyVisibleAlphaToOpenPanels()
            }
    }

    private var visibleAlpha: CGFloat {
        AppCore.shared.settings.pinnedWindowAlpha
    }

    private func applyVisibleAlpha(to panel: PinnedImagePanel) {
        let alpha = visibleAlpha
        panel.alphaValue = alpha
        panel.ignoresMouseEvents = alpha <= 0
    }

    private func applyVisibleAlphaToOpenPanels() {
        for (itemID, panel) in panels {
            guard !closingPanels.contains(itemID), !hiddenForFullscreen.contains(itemID) else {
                continue
            }
            applyVisibleAlpha(to: panel)
        }
    }

    private func syncPanelTitles() {
        let locale = AppCore.shared.settings.language.locale
        let store = AppCore.shared.clipboardStore
        for (id, panel) in panels {
            let title = store.item(id: id)?.displayTitle(locale: locale) ?? ""
            if !title.isEmpty, panel.title != title {
                panel.title = title
            }
        }
    }

    private func makePanel(
        title: String,
        initialSize: CGSize,
        aspectRatio: CGSize?,
        minSize: CGSize
    ) -> PinnedImagePanel {
        let panel = PinnedImagePanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .floating
        // Follow regular Spaces, but stay off exclusive fullscreen Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        if let aspectRatio {
            panel.contentAspectRatio = aspectRatio
        }
        panel.contentMinSize = minSize
        panel.delegate = self
        return panel
    }

    private func install(_ view: some View, in panel: PinnedImagePanel) {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = Theme.Radius.panel
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
    }

    private func present(
        _ panel: PinnedImagePanel,
        size: CGSize,
        in visibleFrame: CGRect,
        itemID: ClipboardItem.ID
    ) -> NSRect {
        let finalFrame = NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.alphaValue = 0
        panel.setFrame(Self.scaledFrame(finalFrame, scale: 0.96), display: false)
        panels[itemID] = panel
        if hidesForExclusiveFullScreen(panel) {
            panel.setFrame(finalFrame, display: false)
            applyVisibleAlpha(to: panel)
            hideForFullscreen(itemID, panel)
            return finalFrame
        }
        activate(panel)
        panel.ignoresMouseEvents = visibleAlpha <= 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = visibleAlpha
            panel.animator().setFrame(finalFrame, display: true)
        }
        return finalFrame
    }

    private func observeExclusiveFullScreenIfNeeded() {
        guard !observesExclusiveFullScreen else { return }
        observesExclusiveFullScreen = true
        let workspace = NSWorkspace.shared.notificationCenter
        spaceObservers = [
            NotificationToken(
                workspace.addObserver(
                    forName: NSWorkspace.activeSpaceDidChangeNotification,
                    object: nil,
                    queue: .main,
                    using: { [weak self] (_: Notification) -> Void in
                        MainActor.assumeIsolated {
                            self?.handleSpaceChange()
                            return
                        }
                    }
                ),
                center: workspace
            ),
            NotificationToken(
                workspace.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil,
                    queue: .main,
                    using: { [weak self] (_: Notification) -> Void in
                        MainActor.assumeIsolated {
                            self?.handleSpaceChange()
                            return
                        }
                    }
                ),
                center: workspace
            ),
            NotificationToken(
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main,
                    using: { [weak self] (_: Notification) -> Void in
                        MainActor.assumeIsolated {
                            self?.handleSpaceChange()
                            return
                        }
                    }
                ),
                center: .default
            ),
        ]
    }

    private func handleSpaceChange() {
        scheduleFullscreenSync()
    }

    private func scheduleFullscreenSync() {
        syncFullscreenVisibility()
        fullscreenSyncTask?.cancel()
        fullscreenSyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            syncFullscreenVisibility()
        }
    }

    private func syncFullscreenVisibility() {
        for (itemID, panel) in panels {
            guard !closingPanels.contains(itemID) else { continue }
            if hidesForExclusiveFullScreen(panel) {
                hideForFullscreen(itemID, panel)
            } else if hiddenForFullscreen.remove(itemID) != nil {
                guard parkedHomeFrames[itemID] == nil else { continue }
                applyVisibleAlpha(to: panel)
                panel.orderFrontRegardless()
            }
        }
    }

    private func hideForFullscreen(_ itemID: ClipboardItem.ID, _ panel: PinnedImagePanel) {
        hiddenForFullscreen.insert(itemID)
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func hidesForExclusiveFullScreen(_ panel: PinnedImagePanel) -> Bool {
        guard let screen = screen(for: panel) else { return false }
        return ExclusiveFullScreen.contains(screen)
    }

    private func screen(for panel: NSPanel) -> NSScreen? {
        panel.screen
            ?? NSScreen.screens.first {
                NSMouseInRect(
                    NSPoint(x: panel.frame.midX, y: panel.frame.midY), $0.frame, false)
            }
            ?? NSScreen.main
    }

    private func targetVisibleFrame() -> CGRect {
        targetScreen()?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
    }

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private static func scaledFrame(_ frame: NSRect, scale: CGFloat) -> NSRect {
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// Exclusive macOS fullscreen (a dedicated Space that owns the whole display), not a zoomed
/// window that still leaves the menu bar visible.
@MainActor
private enum ExclusiveFullScreen {
    static func contains(_ screen: NSScreen) -> Bool {
        let frame = screen.frame
        let visible = screen.visibleFrame
        // A zoomed window keeps the menu bar, so `visibleFrame` is inset from `frame`.
        guard abs(frame.width - visible.width) < 1, abs(frame.height - visible.height) < 1 else {
            return false
        }
        return hasWindowCoveringDisplay(screen)
    }

    /// A layer-0 window that fills `screen.frame` (including the menu-bar strip). Finder's
    /// desktop and the Dock are excluded so an auto-hidden menu bar on the Desktop is not
    /// treated as fullscreen.
    private static func hasWindowCoveringDisplay(_ screen: NSScreen) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return false }

        let screenFrame = screen.frame
        let ourPID = ProcessInfo.processInfo.processIdentifier
        for window in info {
            guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                alpha > 0.9,
                let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                ownerPID != Int(ourPID),
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"],
                let width = bounds["Width"], let height = bounds["Height"]
            else { continue }

            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Window Server" || owner == "Dock" { continue }

            let cocoa = cocoaRect(fromCGWindow: CGRect(x: x, y: y, width: width, height: height))
            guard abs(cocoa.width - screenFrame.width) < 4,
                abs(cocoa.height - screenFrame.height) < 4,
                cocoa.intersects(screenFrame)
            else { continue }
            return true
        }
        return false
    }

    /// `kCGWindowBounds` origin is the top-left of the primary display, Y increasing down.
    private static func cocoaRect(fromCGWindow bounds: CGRect) -> CGRect {
        let primaryHeight =
            NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? bounds.height
        return CGRect(
            x: bounds.origin.x,
            y: primaryHeight - bounds.origin.y - bounds.height,
            width: bounds.width,
            height: bounds.height
        )
    }
}

/// Pure sizing policy kept separate from AppKit window ownership so unusual image ratios and
/// multi-display bounds remain deterministic.
enum PinnedImageLayout {
    static func initialSize(
        imageSize: CGSize,
        visibleFrame: CGRect,
        preferredLongEdge: CGFloat
    ) -> CGSize {
        let natural = normalized(imageSize)
        let maxSize = CGSize(
            width: max(visibleFrame.width - 24, 1),
            height: max(visibleFrame.height - 24, 1)
        )
        let preferredScale = max(preferredLongEdge, 1) / max(natural.width, natural.height)
        let screenScale = min(maxSize.width / natural.width, maxSize.height / natural.height)
        let scale = max(min(preferredScale, screenScale, 1), 0.001)
        return rounded(CGSize(width: natural.width * scale, height: natural.height * scale))
    }

    static func minimumSize(imageSize: CGSize, visibleFrame: CGRect) -> CGSize {
        let natural = normalized(imageSize)
        let longSideScale = 160 / max(natural.width, natural.height)
        // The 28-point close control has 10-point card insets on both sides. Never let either
        // image dimension fall below 48 points, even for extreme panoramas or long screenshots.
        let shortSideScale = 48 / min(natural.width, natural.height)
        let desiredScale = max(longSideScale, shortSideScale)
        let displayScale = min(
            visibleFrame.width * 0.9 / natural.width,
            visibleFrame.height * 0.9 / natural.height
        )
        let scale = max(min(desiredScale, displayScale), 0.001)
        return rounded(CGSize(width: natural.width * scale, height: natural.height * scale))
    }

    private static func normalized(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(size.width, 1),
            height: max(size.height, 1)
        )
    }

    private static func rounded(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width.rounded(), 1), height: max(size.height.rounded(), 1))
    }
}

enum PinnedTextLayout {
    static let minimumSize = CGSize(width: 280, height: 160)

    static func initialSize(
        text: String,
        style: PinnedTextStyle,
        fontSize: CGFloat,
        visibleFrame: CGRect
    ) -> CGSize {
        let availableWidth = max(visibleFrame.width - 48, 1)
        let availableHeight = max(visibleFrame.height - 48, 1)
        let minimumWidth = min(minimumSize.width, availableWidth)
        let maximumWidth = min(preferredMaximumWidth(for: style), availableWidth)
        let lineWidths = sampledLineWidths(text: text, style: style, fontSize: fontSize)
        let measuredWidth = (lineWidths.max() ?? 0) + 48
        let width = min(max(measuredWidth, minimumWidth), max(maximumWidth, minimumWidth))

        let contentWidth = max(width - 32, 1)
        let wrappedLines = lineWidths.reduce(CGFloat.zero) { count, lineWidth in
            count + max(ceil(lineWidth / contentWidth), 1)
        }
        let lineHeight = max(fontSize * 1.4, 18)
        let height = min(
            max(220, 72 + wrappedLines * lineHeight),
            max(availableHeight * 0.72, minimumSize.height)
        )
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    private static func preferredMaximumWidth(for style: PinnedTextStyle) -> CGFloat {
        switch style {
        case .plain: return 420
        case .markdown: return 460
        case .code: return 500
        }
    }

    private static func sampledLineWidths(
        text: String,
        style: PinnedTextStyle,
        fontSize: CGFloat
    ) -> [CGFloat] {
        let font =
            style == .code
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)
        let sample = String(text.prefix(20_000))
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false).prefix(200)
        let widths = lines.map { line -> CGFloat in
            let measuredLine = String(line.prefix(200))
            return ceil(
                (measuredLine as NSString).size(withAttributes: [.font: font]).width
            )
        }
        return widths.isEmpty ? [0] : widths
    }
}

private enum PinnedCardPark {
    static let duration: TimeInterval = 0.34
    static let margin: CGFloat = 12

    static func offscreenFrame(_ frame: NSRect, screen: NSRect) -> NSRect {
        let x =
            frame.midX < screen.midX
            ? screen.minX - frame.width - margin
            : screen.maxX + margin
        return NSRect(x: x, y: frame.minY, width: frame.width, height: frame.height)
    }
}

private final class PinnedImagePanel: NSPanel {
    var onCommand: ((PinnedImageCommand) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if isEditingTitle {
                super.sendEvent(event)
                return
            }
            if let command = command(for: event) {
                if !event.isARepeat || command.allowsKeyRepeat {
                    onCommand?(command)
                }
                return
            }
        }
        if event.type == .magnify {
            resize(
                by: max(1 + event.magnification, 0.1),
                anchorInWindow: event.locationInWindow
            )
            return
        }
        super.sendEvent(event)
    }

    private var isEditingTitle: Bool {
        (firstResponder as? NSTextView)?.isEditable == true
    }

    func resize(by requestedScale: CGFloat, anchorInWindow requestedAnchor: NSPoint? = nil) {
        guard requestedScale.isFinite, requestedScale > 0, requestedScale != 1 else { return }

        let current = frame
        guard current.width > 0, current.height > 0 else { return }

        let visibleFrame = resizeVisibleFrame()
        let maximumScale = min(
            visibleFrame.width / current.width,
            visibleFrame.height / current.height
        )
        guard maximumScale.isFinite, maximumScale > 0 else { return }
        let minimumScale = min(max(
            contentMinSize.width / current.width,
            contentMinSize.height / current.height
        ), maximumScale)
        let scale = min(max(requestedScale, minimumScale), maximumScale)
        let size = CGSize(width: current.width * scale, height: current.height * scale)

        let rawAnchor = requestedAnchor ?? NSPoint(x: current.width / 2, y: current.height / 2)
        let anchor = NSPoint(
            x: min(max(rawAnchor.x, 0), current.width),
            y: min(max(rawAnchor.y, 0), current.height)
        )
        let unitAnchor = NSPoint(x: anchor.x / current.width, y: anchor.y / current.height)
        let screenAnchor = NSPoint(x: current.minX + anchor.x, y: current.minY + anchor.y)
        let proposedOrigin = NSPoint(
            x: screenAnchor.x - size.width * unitAnchor.x,
            y: screenAnchor.y - size.height * unitAnchor.y
        )
        let origin = NSPoint(
            x: min(max(proposedOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(proposedOrigin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
        let resizedFrame = NSRect(origin: origin, size: size)
        guard !resizedFrame.nearlyEquals(current) else { return }

        setFrame(resizedFrame, display: true)
        // Magnify events arrive much faster than SwiftUI's normal display pass. Keep the hosting
        // tree and its clipping layer synchronized with every window frame so stale bounds cannot
        // crop the image or card controls mid-gesture.
        contentView?.layoutSubtreeIfNeeded()
    }

    private func resizeVisibleFrame() -> NSRect {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
        let inset = min(12, max(min(visible.width, visible.height) / 4, 0))
        return visible.insetBy(dx: inset, dy: inset)
    }

    private func command(for event: NSEvent) -> PinnedImageCommand? {
        let shortcut = KeyboardShortcuts.Shortcut(event: event)
        if PinnedImageShortcut.close.matches(shortcut) { return .close }
        if PinnedImageShortcut.closeAll.matches(shortcut) { return .closeAll }
        if PinnedImageShortcut.dismiss.matches(shortcut) { return .dismiss }
        if PinnedImageShortcut.copy.matches(shortcut) { return .copy }
        if PinnedImageShortcut.zoomIn.matches(shortcut) { return .zoomIn }
        if PinnedImageShortcut.zoomOut.matches(shortcut) { return .zoomOut }
        if PinnedImageShortcut.resetSize.matches(shortcut) { return .resetSize }
        return nil
    }
}

private extension NSRect {
    func nearlyEquals(_ other: NSRect, tolerance: CGFloat = 0.01) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

@MainActor
private struct PinnedCardBackground: View {
    @ObservedObject private var settings = AppCore.shared.settings

    var body: some View {
        Group {
            if settings.pinnedWindowBlur {
                VisualEffectView()
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .ignoresSafeArea()
    }
}

@MainActor
private struct PinnedImageContent: View {
    let itemID: ClipboardItem.ID
    let url: URL
    let decodeMaxPixel: CGFloat
    let onClose: () -> Void

    @State private var image: NSImage?
    @State private var loadFailed = false

    var body: some View {
        ZStack(alignment: .top) {
            PinnedCardBackground()

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadFailed {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            PinnedImageDragSurface()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            PinnedCardChrome(
                itemID: itemID,
                trailingWidth: 28,
                closeLabel: "Close Pinned Image",
                onClose: onClose
            ) {
                Color.clear
                    .frame(width: 28, height: 28)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .ignoresSafeArea()
        .task(id: url) {
            image = await ImageThumbnail.loadAsync(url, maxPixel: decodeMaxPixel)
            loadFailed = image == nil
        }
    }
}

@MainActor
private struct PinnedTextContent: View {
    let itemID: ClipboardItem.ID
    let text: String
    let style: PinnedTextStyle
    let onViewportChange: (PinnedTextViewport) -> Void
    let onClose: () -> Void

    @ObservedObject private var settings = AppCore.shared.settings
    @State private var viewport: PinnedTextViewport

    init(
        itemID: ClipboardItem.ID,
        text: String,
        style: PinnedTextStyle,
        viewport: PinnedTextViewport,
        onViewportChange: @escaping (PinnedTextViewport) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.itemID = itemID
        self.text = text
        self.style = style
        self.onViewportChange = onViewportChange
        self.onClose = onClose
        _viewport = State(initialValue: viewport)
    }

    var body: some View {
        ZStack(alignment: .top) {
            PinnedCardBackground()

            Group {
                switch style {
                case .plain:
                    SelectableAttributedText(
                        nsAttributed: NSAttributedString(string: text),
                        fontSize: settings.pinnedTextSize,
                        scrollPosition: viewport.scrollPosition,
                        selection: viewport.selection,
                        onScroll: updateScrollPosition,
                        onSelectionChange: updateSelection)
                case .markdown:
                    MarkdownPreview(
                        source: text,
                        fontSize: settings.pinnedTextSize,
                        scrollPosition: viewport.scrollPosition,
                        selection: viewport.selection,
                        onScroll: updateScrollPosition,
                        onSelectionChange: updateSelection)
                case .code:
                    CodePreview(
                        code: text,
                        fontSize: settings.pinnedTextSize,
                        scrollPosition: viewport.scrollPosition,
                        selection: viewport.selection,
                        onScroll: updateScrollPosition,
                        onSelectionChange: updateSelection)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 16)
            .padding(.top, 48)
            .padding(.bottom, 16)

            PinnedImageDragSurface()
                .frame(height: 44)
                .frame(maxWidth: .infinity, alignment: .top)

            PinnedCardChrome(
                itemID: itemID,
                trailingWidth: 64,
                closeLabel: "Close Pinned Item",
                onClose: onClose
            ) {
                HStack(spacing: 8) {
                    PinnedCardButton(
                        systemName: "minus",
                        label: "Decrease Pinned Text Size"
                    ) {
                        changeTextSize(by: -PinnedTextSize.step)
                    }
                    .disabled(settings.pinnedTextSize <= PinnedTextSize.minimum)

                    PinnedCardButton(
                        systemName: "plus",
                        label: "Increase Pinned Text Size"
                    ) {
                        changeTextSize(by: PinnedTextSize.step)
                    }
                    .disabled(settings.pinnedTextSize >= PinnedTextSize.maximum)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .ignoresSafeArea()
    }

    private func changeTextSize(by amount: CGFloat) {
        settings.pinnedTextSize = PinnedTextSize.clamped(settings.pinnedTextSize + amount)
    }

    private func updateScrollPosition(_ position: CGPoint) {
        guard abs(viewport.scrollPosition.y - position.y) > 0.5 else { return }
        viewport.scrollPosition = CGPoint(x: 0, y: position.y)
        onViewportChange(viewport)
    }

    private func updateSelection(_ selection: NSRange) {
        guard viewport.selection != selection else { return }
        viewport.selection = selection
        onViewportChange(viewport)
    }
}

private struct PinnedCardChrome<Trailing: View>: View {
    let itemID: ClipboardItem.ID
    let trailingWidth: CGFloat
    let closeLabel: LocalizedStringKey
    let onClose: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        GeometryReader { geometry in
            let titleWidth = max(geometry.size.width - 2 * (trailingWidth + 8), 0)

            ZStack {
                PinnedCardTitle(itemID: itemID)
                    .frame(width: titleWidth)
                    .clipped()

                PinnedCardButton(
                    systemName: "xmark",
                    label: closeLabel,
                    action: onClose
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                trailing
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: 28)
        .padding(10)
        .frame(maxWidth: .infinity)
    }
}

private struct PinnedCardTitle: View {
    let itemID: ClipboardItem.ID

    @ObservedObject private var store = AppCore.shared.clipboardStore
    @ObservedObject private var settings = AppCore.shared.settings
    @State private var isEditing = false
    @State private var draft = ""
    @State private var skipCommitOnBlur = false
    @FocusState private var focused: Bool

    private var title: String {
        store.item(id: itemID)?.displayTitle(locale: settings.language.locale) ?? ""
    }

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 12, weight: .semibold))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
            } else {
                Button(action: beginEditing) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help(Text("Rename"))
                .accessibilityLabel(Text("Rename"))
            }
        }
        .frame(minWidth: 0, maxWidth: 280)
        .onChange(of: isEditing) {
            if isEditing {
                focused = true
            }
        }
        .onChange(of: focused) {
            if isEditing, !focused {
                if skipCommitOnBlur {
                    skipCommitOnBlur = false
                    isEditing = false
                } else {
                    commit()
                }
            }
        }
    }

    private func beginEditing() {
        skipCommitOnBlur = false
        draft = title
        isEditing = true
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        skipCommitOnBlur = false
        focused = false
        store.setCustomTitle(draft, for: itemID)
    }

    private func cancel() {
        skipCommitOnBlur = true
        focused = false
    }
}

private struct PinnedCardButton: View {
    let systemName: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frosted(in: Circle())
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }
}

private struct PinnedImageDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> PinnedImageDragView {
        PinnedImageDragView()
    }

    func updateNSView(_ nsView: PinnedImageDragView, context: Context) {}
}

private final class PinnedImageDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
