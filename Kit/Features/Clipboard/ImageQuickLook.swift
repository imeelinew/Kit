import AppKit
import SwiftUI

enum ImageQuickLook {
    /// Close any open Quick Look without going through the SwiftUI binding (palette hide).
    @MainActor static func close() {
        ImageQuickLookSession.shared.forceClose()
    }
}

/// Space-toggled image Quick Look via `NSPopover`, sized to the room beside the thumbnail so
/// AppKit does not flip the popover on top of the anchor.
///
/// The representable sits on the rendered thumbnail so the popover arrow targets the image.
struct ImageQuickLookAnchor: NSViewRepresentable {
    var url: URL?
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.anchorView = nsView
        let presented = _isPresented
        ImageQuickLookSession.shared.sync(
            presented: isPresented, url: url, anchor: nsView
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

// MARK: - Shared session

@MainActor
private final class ImageQuickLookSession: NSObject, NSPopoverDelegate {
    static let shared = ImageQuickLookSession()

    private var popover: NSPopover?
    private weak var anchorView: NSView?
    private weak var shownAnchorView: NSView?
    private var requestedURL: URL?
    private var requestedPresented = false
    private var onDismiss: (() -> Void)?
    private var shownURL: URL?
    private var shownSize: CGSize = .zero
    private var isClosing = false
    private var notifyWhenClosed = false
    private var reconcileScheduled = false

    private static let gap: CGFloat = 12
    private static let popoverChrome: CGFloat = 16
    private static let screenPad: CGFloat = 10
    private static let minSide: CGFloat = 180

    func sync(presented: Bool, url: URL?, anchor: NSView, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        self.anchorView = anchor
        requestedPresented = presented && url != nil
        requestedURL = url
        if presented, url != nil {
            // A newly mounted/updated anchor supersedes any deferred failure notification from
            // the previous SwiftUI view identity.
            notifyWhenClosed = false
            reconcileWhenLaidOut()
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
    func forceClose() {
        requestedPresented = false
        notifyWhenClosed = false
        beginClose()
    }

    private func reconcileWhenLaidOut() {
        if let anchorView, !anchorView.bounds.isEmpty, anchorView.window != nil {
            reconcile()
        } else {
            scheduleReconcile()
        }
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
        guard !isClosing else { return }
        guard let anchorView, anchorView.window != nil else { return }
        guard let placement = Self.placement(url: url, anchorView: anchorView) else {
            requestedPresented = false
            notifyWhenClosed = true
            beginClose()
            return
        }

        if let popover, popover.isShown {
            // Same image still showing — leave it alone. URL changes while open are ignored
            // because ↑↓ are blocked during Quick Look.
            guard shownURL == url, shownSize == placement.size, shownAnchorView === anchorView
            else { return }
            return
        }

        // A not-yet-cleaned-up popover is waiting for its delegate callback.
        guard popover == nil else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = placement.size
        popover.contentViewController = NSHostingController(
            rootView: ImageQuickLookContent(url: url, size: placement.size)
        )
        self.popover = popover
        shownAnchorView = anchorView
        shownURL = url
        shownSize = placement.size
        popover.show(
            relativeTo: anchorView.bounds, of: anchorView, preferredEdge: placement.edge)
    }

    private func beginClose() {
        guard let popover else {
            finishCloseWithoutPopoverIfNeeded()
            return
        }
        guard !isClosing else { return }
        isClosing = true
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
            closedPopover === popover
        else { return }

        let appInitiatedClose = isClosing
        popover = nil
        shownAnchorView = nil
        shownURL = nil
        shownSize = .zero
        isClosing = false

        // A transient outside-click close originates in AppKit, so reflect it into SwiftUI.
        if !appInitiatedClose {
            requestedPresented = false
            notifyWhenClosed = true
        }
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

    /// Size the popover to fit entirely on one side of the thumbnail (prefer leading / `.minX`)
    /// so `NSPopover` has no reason to flip over the anchor.
    private static func placement(url: URL, anchorView: NSView) -> Placement? {
        guard let window = anchorView.window else { return nil }
        let anchorInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchor = window.convertToScreen(anchorInWindow)
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? anchor.insetBy(dx: -400, dy: -400)
        let backing = screen?.backingScaleFactor ?? 2

        let pixel = ImageThumbnail.pixelSize(of: url) ?? CGSize(width: 1200, height: 900)
        let natural = CGSize(
            width: max(pixel.width / backing, 1), height: max(pixel.height / backing, 1))

        func fit(maxW: CGFloat, maxH: CGFloat) -> CGSize? {
            guard maxW >= minSide, maxH >= minSide else { return nil }
            let scale = min(maxW / natural.width, maxH / natural.height)
            return CGSize(
                width: max((natural.width * scale).rounded(.down), 1),
                height: max((natural.height * scale).rounded(.down), 1))
        }

        struct Candidate {
            let edge: NSRectEdge
            let maxW: CGFloat
            let maxH: CGFloat
            let rank: Int
        }

        let candidates: [Candidate] = [
            Candidate(
                edge: .minX,
                maxW: anchor.minX - visible.minX - gap - popoverChrome - screenPad,
                maxH: visible.height - 2 * screenPad, rank: 0),
            Candidate(
                edge: .maxX,
                maxW: visible.maxX - anchor.maxX - gap - popoverChrome - screenPad,
                maxH: visible.height - 2 * screenPad, rank: 1),
            Candidate(
                edge: .maxY,
                maxW: visible.width - 2 * screenPad,
                maxH: visible.maxY - anchor.maxY - gap - popoverChrome - screenPad, rank: 2),
            Candidate(
                edge: .minY,
                maxW: visible.width - 2 * screenPad,
                maxH: anchor.minY - visible.minY - gap - popoverChrome - screenPad, rank: 3),
        ]

        let fitted: [(Candidate, CGSize)] = candidates.compactMap { c in
            guard let size = fit(maxW: c.maxW, maxH: c.maxH) else { return nil }
            return (c, size)
        }
        let best = fitted.sorted { a, b in
            let areaA = a.1.width * a.1.height
            let areaB = b.1.width * b.1.height
            let aHorizontal = a.0.rank < 2
            let bHorizontal = b.0.rank < 2
            if aHorizontal != bHorizontal { return aHorizontal }
            if abs(areaA - areaB) > 4_000 { return areaA > areaB }
            return a.0.rank < b.0.rank
        }.first

        guard let (candidate, size) = best else { return nil }
        return Placement(edge: candidate.edge, size: size)
    }
}

/// Large Quick Look body: decodes a screen-sized bitmap and letterboxes it into `size`.
private struct ImageQuickLookContent: View {
    let url: URL
    let size: CGSize

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: "\(url.absoluteString)#\(Int(size.width))x\(Int(size.height))") {
            let maxPixel =
                max(size.width, size.height) * (NSScreen.main?.backingScaleFactor ?? 2)
            image = await ImageThumbnail.loadAsync(url, maxPixel: maxPixel)
        }
    }
}
