import AppKit
import SwiftUI

enum ImageQuickLook {
    /// Close any open Quick Look without going through the SwiftUI binding (palette hide).
    @MainActor static func close(immediately: Bool = false) {
        ImageQuickLookSession.shared.forceClose(immediately: immediately)
    }
}

/// Hover-triggered image Quick Look via `NSPopover`, sized to the room left of or below the preview so
/// AppKit does not flip the popover on top of the anchor.
///
/// The representable sits on the right-hand preview image so the popover arrow targets the image.
struct ImageQuickLookAnchor: NSViewRepresentable {
    var url: URL?
    var highlights: [CGRect] = []
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
            presented: isPresented, url: url, highlights: highlights, anchor: nsView
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
    private var requestedHighlights: [CGRect] = []
    private var requestedPresented = false
    private var onDismiss: (() -> Void)?
    private var shownURL: URL?
    private var shownSize: CGSize = .zero
    private var shownHighlights: [CGRect] = []
    private var isClosing = false
    private var notifyWhenClosed = false
    private var reconcileScheduled = false

    private static let gap: CGFloat = 12
    private static let popoverChrome: CGFloat = 16
    private static let screenPad: CGFloat = 10
    private static let minSide: CGFloat = 180

    func sync(
        presented: Bool, url: URL?, highlights: [CGRect], anchor: NSView,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        self.anchorView = anchor
        requestedPresented = presented && url != nil
        requestedURL = url
        requestedHighlights = highlights
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
    func forceClose(immediately: Bool) {
        requestedPresented = false
        notifyWhenClosed = false
        if immediately, let popover {
            // A hover-exit animation may already be in flight. Hide its window as well;
            // changing animates alone does not finish an animation that already started.
            popover.animates = false
            popover.contentViewController?.view.window?.alphaValue = 0
        }
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
            // Selection changes close the session. Keep an already showing image stable during hover.
            guard shownURL == url, shownSize == placement.size, shownAnchorView === anchorView
            else { return }
            if shownHighlights != requestedHighlights,
                let hosting = popover.contentViewController as? NSHostingController<ImageQuickLookContent>
            {
                hosting.rootView = ImageQuickLookContent(
                    url: url, size: shownSize, highlights: requestedHighlights)
                shownHighlights = requestedHighlights
            }
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
            rootView: ImageQuickLookContent(
                url: url, size: placement.size, highlights: requestedHighlights)
        )
        self.popover = popover
        shownAnchorView = anchorView
        shownURL = url
        shownSize = placement.size
        shownHighlights = requestedHighlights
        popover.show(
            relativeTo: anchorView.bounds, of: anchorView, preferredEdge: placement.edge)
    }

    func popoverWillShow(_ notification: Notification) {
        guard let shownPopover = notification.object as? NSPopover,
            shownPopover === popover, requestedPresented, !isClosing
        else { return }
        PaletteHaptics.previewOpened()
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
        shownHighlights = []
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

    /// Fit the image left of or below the preview, then use whichever placement shows it larger.
    /// Leave room for popover chrome so AppKit does not flip it over the anchor.
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

    @State private var image: NSImage?
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
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: "\(url.absoluteString)#\(Int(size.width))x\(Int(size.height))") {
            let maxPixel =
                max(size.width, size.height) * displayScale
            let loaded = await ImageThumbnail.loadAsync(url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
