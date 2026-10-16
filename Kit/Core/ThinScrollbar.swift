import AppKit
import SwiftUI

struct ThinScrollbarMetrics: Equatable {
    /// Normalized vertical content offset, starting at zero at the resting top edge.
    var offset: CGFloat = 0
    var insetTop: CGFloat = 0
    var content: CGFloat = 0
    var viewport: CGFloat = 0
    var scrollable: Bool { content > viewport + 1 }
}

/// Shared scrollbar appearance and interaction, each owner supplies its own scroll destination
struct ThinScrollbar: ViewModifier {
    var externalMetrics: ThinScrollbarMetrics
    var externalScrollToken: UUID
    var onScrollToFraction: @MainActor (CGFloat) -> Void

    // Interaction signals — kept separate so each source of "show the bar" is independent.
    @State private var isScrolling = false
    @State private var isHoveringTrack = false
    /// Mirrors the AppKit-side thumb drag (`ScrollbarInteraction` owns the actual drag state).
    @State private var isDragging = false

    private var metrics: ThinScrollbarMetrics { externalMetrics }
    /// Instantaneous "pointer is in the trailing hover zone" mirror, for edge-transition detection.
    @State private var inZone = false
    @State private var scrollStop: Task<Void, Never>?
    @State private var hoverExit: Task<Void, Never>?

    // Knob/rail geometry: thin at rest, fatter on hover/drag — like the macOS overlay knob.
    private let thinWidth: CGFloat = 4
    private let expandedWidth: CGFloat = 8
    private let inset: CGFloat = 3
    private let minThumb: CGFloat = 28
    private let hoverZone: CGFloat = 16  // trailing strip that reveals the rail; wider than the thumb

    // Animation curves shared across the interaction transitions.
    private let fadeCurve: Animation = .easeOut(duration: 0.18)
    private let morphCurve: Animation = .spring(response: 0.28, dampingFraction: 0.85)

    private var visible: Bool { isScrolling || isHoveringTrack || isDragging }
    private var expanded: Bool { isHoveringTrack || isDragging }

    func body(content: Content) -> some View {
        content.scrollIndicators(.hidden)
            .onChange(of: externalScrollToken) {
                beganScrolling()
                scheduleScrollStop()
            }
            .overlay(alignment: .topTrailing) { bar }
            // The trailing strip handles dragging, wheel events pass through to the content
            .overlay {
                ScrollbarInteraction(
                    edgeWidth: hoverZone,
                    inset: inset,
                    thumbY: thumbOffset,
                    thumbHeight: thumbHeight,
                    thumbGrabbable: metrics.scrollable && visible,
                    railActive: metrics.scrollable && expanded,
                    onZoneChange: updateZone,
                    onDragChange: dragChanged,
                    onScrollToFraction: onScrollToFraction
                )
            }
            .onDisappear {
                scrollStop?.cancel()
                hoverExit?.cancel()
                isScrolling = false
                isHoveringTrack = false
                isDragging = false
                inZone = false
            }
    }

    @ViewBuilder private var bar: some View {
        if metrics.scrollable {
            ZStack(alignment: .top) {
                // Rail: a faint full-height track, present only while hovering/dragging.
                Capsule()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: expandedWidth, height: track)
                    .offset(y: inset)
                    .opacity(expanded ? 1 : 0)

                // Thumb: proportional knob, thin at rest and fatter when expanded.
                Capsule()
                    .fill(Color.primary.opacity(isDragging ? 0.38 : (expanded ? 0.28 : 0.18)))
                    .frame(width: expanded ? expandedWidth : thinWidth, height: thumbHeight)
                    .frame(width: expandedWidth)
                    .offset(y: thumbOffset)
                    .opacity(visible ? 1 : 0)
            }
            .frame(width: expandedWidth)
            .padding(.trailing, inset)
            // Purely visual, ScrollbarInteraction owns clicks and drags
            .allowsHitTesting(false)
        }
    }

    /// Usable vertical travel, inset a little from the top and bottom edges.
    private var track: CGFloat { max(0, metrics.viewport - inset * 2) }

    private var thumbHeight: CGFloat {
        guard metrics.content > 0 else { return minThumb }
        return min(track, max(minThumb, track * metrics.viewport / metrics.content))
    }

    private var thumbOffset: CGFloat {
        let maxScroll = max(0, metrics.content - metrics.viewport)
        guard maxScroll > 0 else { return inset }
        let fraction = min(1, max(0, (metrics.offset + metrics.insetTop) / maxScroll))
        return inset + fraction * (track - thumbHeight)
    }

    // MARK: - Scroll signal

    private func beganScrolling() {
        scrollStop?.cancel()
        withAnimation(fadeCurve) { isScrolling = true }
    }

    /// Fade the thumb out a beat after scrolling stops, like the native overlay scroller.
    private func scheduleScrollStop() {
        scrollStop?.cancel()
        scrollStop = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            withAnimation(fadeCurve) { isScrolling = false }
        }
    }

    // MARK: - Drag signal

    private func dragChanged(_ dragging: Bool) {
        withAnimation(morphCurve) { isDragging = dragging }
        if dragging {
            scrollStop?.cancel()
        } else {
            // Linger like a normal scroll, then fade unless still hovering/scrolling.
            isScrolling = true
            scheduleScrollStop()
        }
    }

    // MARK: - Hover signal

    /// Called on every pointer move; acts only on the in-zone ⇄ out-of-zone *transition*.
    private func updateZone(_ nowInZone: Bool) {
        guard nowInZone != inZone else { return }
        inZone = nowInZone
        if nowInZone {
            hoverExit?.cancel()
            withAnimation(morphCurve) { isHoveringTrack = true }
        } else {
            scheduleHoverExit()
        }
    }

    /// Leaving the zone collapses the rail after a short delay, so brief exits don't flicker it.
    private func scheduleHoverExit() {
        hoverExit?.cancel()
        hoverExit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            withAnimation(morphCurve) { isHoveringTrack = false }
        }
    }
}

extension View {
    /// AppKit scroll views report geometry and activity through their representable coordinator.
    func thinScrollbar(
        metrics: ThinScrollbarMetrics, scrollToken: UUID,
        onScrollToFraction: @escaping @MainActor (CGFloat) -> Void
    ) -> some View {
        modifier(ThinScrollbar(
            externalMetrics: metrics, externalScrollToken: scrollToken,
            onScrollToFraction: onScrollToFraction))
    }
}

/// Pointer interaction reports a normalized position to its owner, never searches the window for a scroll view
private struct ScrollbarInteraction: NSViewRepresentable {
    let edgeWidth: CGFloat
    let inset: CGFloat
    let thumbY: CGFloat
    let thumbHeight: CGFloat
    let thumbGrabbable: Bool
    let railActive: Bool
    let onZoneChange: @MainActor (Bool) -> Void
    let onDragChange: @MainActor (Bool) -> Void
    let onScrollToFraction: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        InteractionView(
            onZoneChange: onZoneChange, onDragChange: onDragChange,
            onScrollToFraction: onScrollToFraction)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? InteractionView else { return }
        view.edgeWidth = edgeWidth
        view.inset = inset
        view.thumbY = thumbY
        view.thumbHeight = thumbHeight
        view.thumbGrabbable = thumbGrabbable
        view.railActive = railActive
        view.onZoneChange = onZoneChange
        view.onDragChange = onDragChange
        view.onScrollToFraction = onScrollToFraction
    }

    private final class InteractionView: NSView {
        var edgeWidth: CGFloat = 0
        var inset: CGFloat = 0
        var thumbY: CGFloat = 0
        var thumbHeight: CGFloat = 0
        var thumbGrabbable = false
        var railActive = false
        var onZoneChange: @MainActor (Bool) -> Void
        var onDragChange: @MainActor (Bool) -> Void
        var onScrollToFraction: @MainActor (CGFloat) -> Void

        private var lastInZone = false
        private var dragStart: (pointerY: CGFloat, fraction: CGFloat)?

        init(
            onZoneChange: @escaping @MainActor (Bool) -> Void,
            onDragChange: @escaping @MainActor (Bool) -> Void,
            onScrollToFraction: @escaping @MainActor (CGFloat) -> Void
        ) {
            self.onZoneChange = onZoneChange
            self.onDragChange = onDragChange
            self.onScrollToFraction = onScrollToFraction
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        // Match SwiftUI's top-down coordinates so `thumbY` can be used directly.
        override var isFlipped: Bool { true }

        // MARK: Hit testing

        /// Opaque over the thumb's grab strip (and the whole trailing strip while the rail is expanded), transparent elsewhere so content clicks and wheel events fall through.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type != .scrollWheel, let superview else { return nil }
            let p = convert(point, from: superview)
            guard bounds.contains(p) else { return nil }
            if grabRect.contains(p) { return self }
            if railActive && p.x >= bounds.width - edgeWidth { return self }
            return nil
        }

        /// Full trailing-strip width at the thumb's vertical span, so the hairline thumb is comfortably grabbable.
        private var grabRect: CGRect {
            guard thumbGrabbable else { return .null }
            return CGRect(
                x: bounds.width - edgeWidth, y: thumbY, width: edgeWidth, height: thumbHeight)
        }

        // MARK: Thumb drag and track click

        override func mouseDown(with event: NSEvent) {
            guard trackTravel > 0 else { return }
            let p = convert(event.locationInWindow, from: nil)
            var fraction = (thumbY - inset) / trackTravel
            if !(thumbY...(thumbY + thumbHeight)).contains(p.y) {
                fraction = (p.y - thumbHeight / 2 - inset) / trackTravel
            }
            fraction = min(1, max(0, fraction))
            dragStart = (p.y, fraction)
            onDragChange(true)
            onScrollToFraction(fraction)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart, trackTravel > 0 else { return }
            let p = convert(event.locationInWindow, from: nil)
            let fraction = dragStart.fraction + (p.y - dragStart.pointerY) / trackTravel
            onScrollToFraction(min(1, max(0, fraction)))
        }

        override func mouseUp(with event: NSEvent) {
            guard dragStart != nil else { return }
            dragStart = nil
            onDragChange(false)
        }

        private var trackTravel: CGFloat { max(0, bounds.height - inset * 2 - thumbHeight) }

        // MARK: Hover tracking

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            // `.inVisibleRect` pins the area to the resizing bounds; `.activeAlways` so hover reveals the rail in non-key windows too.
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [
                        .mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect,
                    ],
                    owner: self
                ))
        }

        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { update(inZone: false) }

        private func report(_ event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            update(inZone: x >= bounds.width - edgeWidth)
        }

        /// Fire the callback only on a zone transition, so a stream of `mouseMoved`s stays cheap.
        private func update(inZone: Bool) {
            guard inZone != lastInZone else { return }
            lastInZone = inZone
            onZoneChange(inZone)
        }
    }
}

/// An explicitly bound AppKit scroll destination, one instance per scrollable region
@MainActor
final class NativeScrollbarTarget {
    weak var scrollView: NSScrollView?

    func scroll(toFraction fraction: CGFloat) {
        guard let scrollView, scrollView.window != nil else { return }
        let clip = scrollView.contentView
        var probe = clip.bounds
        probe.origin.y = -1_000_000_000
        let minimum = clip.constrainBoundsRect(probe).origin.y
        probe.origin.y = 1_000_000_000
        let maximum = clip.constrainBoundsRect(probe).origin.y
        var origin = clip.bounds.origin
        origin.y = minimum + min(1, max(0, fraction)) * (maximum - minimum)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
