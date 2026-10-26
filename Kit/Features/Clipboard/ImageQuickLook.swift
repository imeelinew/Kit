import AppKit
import SwiftUI

enum ImageQuickLook {
    /// Close any open Quick Look without going through the SwiftUI binding (palette hide).
    @MainActor static func close(immediately: Bool = false) {
        ImageQuickLookSession.shared.forceClose(immediately: immediately)
    }
}

/// Click-triggered image Quick Look via `NSPopover`, sized to the room left of or below the preview so
/// AppKit does not flip the popover on top of the anchor.
///
/// The representable sits on the right-hand preview image so the popover arrow targets the image.
struct ImageQuickLookAnchor: NSViewRepresentable {
    var url: URL?
    var highlights: [CGRect] = []
    var sourceVersion: UInt64 = 0
    var pixelSize: CGSize?
    @Binding var isPresented: Bool
    var onActions: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = ImageQuickLookAnchorView()
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ImageQuickLookAnchorView)?.onActions = onActions
        context.coordinator.anchorView = nsView
        let presented = _isPresented
        ImageQuickLookSession.shared.sync(
            presented: isPresented, url: url, highlights: highlights, sourceVersion: sourceVersion, pixelSize: pixelSize, anchor: nsView
        ) {
            if presented.wrappedValue {
                presented.wrappedValue = false
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        ImageQuickLookSession.shared.releaseAnchor(nsView)
        coordinator.anchorView = nil
    }

    final class Coordinator {
        var anchorView: NSView?
    }
}

private final class ImageQuickLookAnchorView: NSView {
    var onActions: (() -> Void)?
    private var dismissalMonitor: Any?
    private var dismissingButton: Int?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, isSecondaryClick(event) else { return nil }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) { onActions?() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onActions?() }
    }

    private func isSecondaryClick(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    isolated deinit {
        if let dismissalMonitor { NSEvent.removeMonitor(dismissalMonitor) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let dismissalMonitor {
            NSEvent.removeMonitor(dismissalMonitor)
            self.dismissalMonitor = nil
        }
        dismissingButton = nil
        if window != nil {
            dismissalMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp,
                           .leftMouseDragged, .rightMouseDragged]
            ) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    self?.consumesDismissal(event) ?? false
                }
                return consumed ? nil : event
            }
        }
        ImageQuickLookSession.shared.anchorDidChange(self)
    }

    override func layout() {
        super.layout()
        ImageQuickLookSession.shared.anchorDidChange(self)
    }

    private func consumesDismissal(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        if dismissingButton == event.buttonNumber {
            switch event.type {
            case .leftMouseUp, .rightMouseUp:
                dismissingButton = nil
                return true
            case .leftMouseDragged, .rightMouseDragged:
                return true
            case .leftMouseDown, .rightMouseDown:
                dismissingButton = nil
            default:
                break
            }
        }
        guard event.type == .leftMouseDown || event.type == .rightMouseDown,
            ImageQuickLookSession.shared.dismissFromPalette(self) else { return false }
        if isSecondaryClick(event),
            window.contentView?.hitTest(event.locationInWindow) === self {
            return false
        }
        // Own the whole closing click so a stationary SwiftUI button cannot reopen the preview
        dismissingButton = event.buttonNumber
        return true
    }
}

// MARK: - Shared session

@MainActor
private final class ImageQuickLookSession: NSObject, NSPopoverDelegate {
    static let shared = ImageQuickLookSession()

    private var popover: NSPopover?
    private var retiringPopovers: [NSPopover] = []
    private weak var anchorView: NSView?
    private weak var shownAnchorView: NSView?
    private var requestedURL: URL?
    private var requestedHighlights: [CGRect] = []
    private var requestedPresented = false
    private var onDismiss: (() -> Void)?
    private var requestedVersion: UInt64 = 0
    private var shownVersion: UInt64 = 0
    private var requestedPixelSize: CGSize?
    private var shownURL: URL?
    private var shownSize: CGSize = .zero
    private var shownHighlights: [CGRect] = []
    private var notifyWhenClosed = false
    private var reconcileScheduled = false

    private static let gap: CGFloat = 12
    private static let popoverChrome: CGFloat = 16
    private static let screenPad: CGFloat = 10
    private static let minSide: CGFloat = 180

    func sync(
        presented: Bool, url: URL?, highlights: [CGRect], sourceVersion: UInt64 = 0,
        pixelSize: CGSize? = nil, anchor: NSView,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        self.anchorView = anchor
        requestedPresented = presented && url != nil
        requestedURL = url
        requestedVersion = sourceVersion
        requestedPixelSize = pixelSize
        requestedHighlights = highlights
        if presented, url != nil {
            // A newly mounted/updated anchor supersedes any deferred failure notification from
            // the previous SwiftUI view identity.
            notifyWhenClosed = false
            scheduleReconcile()
        } else {
            beginClose()
        }
    }

    func releaseAnchor(_ view: NSView) {
        guard anchorView === view else { return }
        anchorView = nil
        requestedPresented = false
        // RootPaletteView owns selection state and closes the binding when an image disappears.
        // Do not emit a delayed dismiss here: SwiftUI may replace this anchor in the same render.
        beginClose()
    }

    /// Palette dismiss / `imageQuickLookOpen = false` when the representable may already be gone.
    func forceClose(immediately: Bool) {
        requestedPresented = false
        notifyWhenClosed = false
        if immediately {
            let retiring = retiringPopovers
            retiringPopovers.removeAll()
            for popover in retiring {
                popover.animates = false
                popover.contentViewController?.view.window?.alphaValue = 0
                popover.close()
            }
        }
        beginClose(immediately: immediately)
    }

    func anchorDidChange(_ view: NSView) {
        guard anchorView === view, requestedPresented else { return }
        scheduleReconcile()
    }

    func dismissFromPalette(_ view: NSView) -> Bool {
        guard anchorView === view, requestedPresented else { return false }
        requestedPresented = false
        notifyWhenClosed = false
        onDismiss?()
        beginClose()
        return true
    }

    private func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reconcileScheduled = false
            reconcile()
        }
    }

    private func reconcile() {
        guard requestedPresented, let url = requestedURL else {
            beginClose()
            return
        }
        guard let anchorView, anchorView.window?.isVisible == true,
            !anchorView.bounds.isEmpty else { return }
        guard let placement = Self.placement(pixelSize: requestedPixelSize, anchorView: anchorView) else {
            requestedPresented = false
            notifyWhenClosed = true
            beginClose()
            return
        }

        if let popover, popover.isShown {
            // Selection changes close the session, keep an already showing image stable
            guard shownURL == url, shownAnchorView === anchorView
            else { return }
            if shownHighlights != requestedHighlights || shownVersion != requestedVersion || shownSize != placement.size,
                let hosting = popover.contentViewController as? NSHostingController<ImageQuickLookContent>
            {
                hosting.rootView = ImageQuickLookContent(
                    url: url, size: placement.size, highlights: requestedHighlights, sourceVersion: requestedVersion)
                popover.contentSize = placement.size
                shownSize = placement.size
                shownHighlights = requestedHighlights
                shownVersion = requestedVersion
            }
            return
        }

        // A not-yet-cleaned-up popover is waiting for its delegate callback.
        guard popover == nil else { return }

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentSize = placement.size
        popover.contentViewController = NSHostingController(
            rootView: ImageQuickLookContent(
                url: url, size: placement.size, highlights: requestedHighlights, sourceVersion: requestedVersion)
        )
        self.popover = popover
        shownAnchorView = anchorView
        shownURL = url
        shownVersion = requestedVersion
        shownSize = placement.size
        shownHighlights = requestedHighlights
        popover.show(
            relativeTo: anchorView.bounds, of: anchorView, preferredEdge: placement.edge)
    }

    private func beginClose(immediately: Bool = false) {
        guard let popover else {
            finishCloseWithoutPopoverIfNeeded()
            return
        }
        // Retire the outgoing popover before animating so another click can open immediately
        self.popover = nil
        shownAnchorView = nil
        shownURL = nil
        shownSize = .zero
        shownHighlights = []
        retiringPopovers.append(popover)
        if immediately {
            popover.animates = false
            popover.contentViewController?.view.window?.alphaValue = 0
        }
        popover.close()
        finishCloseCycle()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover else { return }
        if retiringPopovers.contains(where: { $0 === closedPopover }) {
            retiringPopovers.removeAll { $0 === closedPopover }
            return
        }
        guard closedPopover === popover else { return }

        popover = nil
        shownAnchorView = nil
        shownURL = nil
        shownSize = .zero
        shownHighlights = []

        // Reflect an AppKit-initiated close into SwiftUI
        requestedPresented = false
        notifyWhenClosed = true
        finishCloseCycle()
    }

    private func finishCloseWithoutPopoverIfNeeded() {
        guard notifyWhenClosed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, popover == nil else { return }
            finishCloseCycle()
        }
    }

    private func finishCloseCycle() {
        let notify = notifyWhenClosed
        notifyWhenClosed = false
        if notify { onDismiss?() }
        if requestedPresented { scheduleReconcile() }
    }

    private struct Placement {
        var edge: NSRectEdge
        var size: CGSize
    }

    /// Fit the image left of or below the preview, then use whichever placement shows it larger.
    /// Leave room for popover chrome so AppKit does not flip it over the anchor.
    private static func placement(pixelSize: CGSize?, anchorView: NSView) -> Placement? {
        guard let window = anchorView.window else { return nil }
        let anchorInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchor = window.convertToScreen(anchorInWindow)
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? anchor.insetBy(dx: -400, dy: -400)
        let backing = screen?.backingScaleFactor ?? 2

        let pixel = pixelSize ?? CGSize(width: 1200, height: 900)
        let natural = CGSize(
            width: max(pixel.width / backing, 1), height: max(pixel.height / backing, 1))

        func fit(maxW: CGFloat, maxH: CGFloat) -> CGSize? {
            guard maxW >= minSide, maxH >= minSide else { return nil }
            let scale = min(maxW / natural.width, maxH / natural.height)
            return CGSize(
                width: max((natural.width * scale).rounded(.down), 1),
                height: max((natural.height * scale).rounded(.down), 1))
        }

        let left = fit(
            maxW: anchor.minX - visible.minX - gap - popoverChrome - screenPad,
            maxH: visible.height - 2 * screenPad)
        let below = fit(
            maxW: visible.width - 2 * screenPad,
            maxH: anchor.minY - visible.minY - gap - popoverChrome - screenPad)

        switch (left, below) {
        case let (left?, below?):
            let leftArea = left.width * left.height
            let belowArea = below.width * below.height
            return belowArea > leftArea
                ? Placement(edge: .minY, size: below)
                : Placement(edge: .minX, size: left)
        case let (left?, nil):
            return Placement(edge: .minX, size: left)
        case let (nil, below?):
            return Placement(edge: .minY, size: below)
        case (nil, nil):
            return nil
        }
    }
}

/// Large Quick Look body: decodes a screen-sized bitmap and letterboxes it into `size`.
struct ImageQuickLookContent: View {
    let url: URL
    let size: CGSize
    var highlights: [CGRect] = []

    var sourceVersion: UInt64 = 0
    @State private var image: NSImage?
    @State private var loadFailed = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay {
                        ImageSearchHighlightOverlay(imageSize: image.size, regions: highlights)
                    }
            } else if loadFailed {
                Image(systemName: "photo.badge.exclamationmark")
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: "\(url.absoluteString)#\(Int(size.width))x\(Int(size.height))#\(sourceVersion)#\(displayScale)") {
            image = nil
            loadFailed = false
            let maxPixel =
                max(size.width, size.height) * displayScale
            let loaded = await ImageThumbnail.loadAsync(url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            image = loaded
            loadFailed = loaded == nil
        }
    }
}
