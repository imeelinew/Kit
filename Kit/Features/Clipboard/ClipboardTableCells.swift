import AppKit
import QuartzCore

final class ClipboardSectionCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private var topConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let size = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        titleLabel.font = .systemFont(ofSize: size, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        topConstraint = titleLabel.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            topConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, isFirst: Bool) {
        titleLabel.stringValue = title
        topConstraint.constant = isFirst ? Theme.Spacing.xs : Theme.Spacing.sectionSpacing
    }
}

final class ClipboardItemCellView: NSTableCellView {
    private enum HighlightMotion {
        static let fillAlpha: CGFloat = 0.11
        static let briefVisitThreshold: CFTimeInterval = 0.06
        static let enterDuration: CFTimeInterval = 0.19
        static let exitDuration: CFTimeInterval = 0.24
        static let tracePeak: Float = 0.45
        static let traceDuration: CFTimeInterval = 0.22
    }

    private let highlightView = NSView()
    private let thumbnailView = ClipboardThumbnailView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var fullTitle = NSAttributedString(string: "")
    private var truncatesFromHead = false
    private var renderedTitleWidth: CGFloat = -1
    private var representedID: ClipboardItem.ID?
    private var selected = false
    private var fadeToken = 0
    private var entranceQueued = false
    private var selectionBeganAt: CFTimeInterval?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = Theme.Radius.row
        highlightView.layer?.cornerCurve = .continuous
        highlightView.translatesAutoresizingMaskIntoConstraints = false

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byClipping
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.cell?.wraps = false
        titleLabel.cell?.isScrollable = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = titleLabel

        addSubview(highlightView)
        addSubview(thumbnailView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.xxs),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.xxs),

            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: Theme.Size.rowIcon),
            thumbnailView.heightAnchor.constraint(equalToConstant: Theme.Size.rowIcon),

            titleLabel.leadingAnchor.constraint(
                equalTo: thumbnailView.trailingAnchor, constant: Theme.Spacing.lg),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.heightAnchor.constraint(lessThanOrEqualToConstant: Theme.Size.rowIcon),
        ])
        updateHighlightColor()
        setHighlightOpacity(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        renderTitle()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedID = nil
        selected = false
        setHighlightOpacity(0)
        titleLabel.isHidden = false
        fullTitle = NSAttributedString(string: "")
        renderedTitleWidth = -1
        thumbnailView.prepareForReuse()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHighlightColor()
        thumbnailView.refreshAppearance()
    }

    func configure(
        item: ClipboardItem, selected: Bool, query: String, imageURL: URL?, locale: Locale
    ) {
        if representedID != item.id {
            // Reused cells must never carry a previous item's highlight or pending fade.
            representedID = item.id
            self.selected = false
            setHighlightOpacity(0)
        }
        setSelected(selected)
        updateTitle(item: item, query: query, locale: locale)
        thumbnailView.configure(item: item, imageURL: imageURL)
    }

    func updateTitle(item: ClipboardItem, query: String, locale: Locale) {
        let customTitle = item.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCustomTitle = customTitle?.isEmpty == false
        truncatesFromHead = item.kind == .path && !hasCustomTitle
        fullTitle = SearchHighlight.nsAttributed(
            Self.listTitle(for: item, customTitle: customTitle, locale: locale),
            query: query,
            font: .preferredFont(forTextStyle: .body))
        renderedTitleWidth = -1
        renderTitle()
    }

    private func renderTitle() {
        var width = titleLabel.bounds.width
        if let clipView = enclosingScrollView?.contentView {
            let visibleBounds = convert(clipView.bounds, from: clipView)
            width = min(width, visibleBounds.maxX - titleLabel.frame.minX - 16)
        }
        guard width > 0, abs(width - renderedTitleWidth) > 0.5 else { return }
        renderedTitleWidth = width
        // The table can clip a cell before NSTextField gets a chance to draw its own ellipsis.
        titleLabel.attributedStringValue = Self.truncatedTitle(
            fullTitle, toFit: width - 3, fromHead: truncatesFromHead,
            font: titleLabel.font ?? .preferredFont(forTextStyle: .body))
    }

    private static func truncatedTitle(
        _ full: NSAttributedString, toFit width: CGFloat, fromHead: Bool, font: NSFont
    ) -> NSAttributedString {
        guard full.size().width > width else { return full }
        let ellipsis = NSAttributedString(
            string: "…", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let source = full.string
        let boundaries = Array(source.indices) + [source.endIndex]
        let count = boundaries.count - 1
        var best: NSAttributedString = ellipsis
        var low = 0
        var high = count

        while low <= high {
            let kept = (low + high) / 2
            let range = fromHead
                ? NSRange(boundaries[count - kept]..<source.endIndex, in: source)
                : NSRange(source.startIndex..<boundaries[kept], in: source)
            let candidate = NSMutableAttributedString(attributedString: ellipsis)
            let visible = full.attributedSubstring(from: range)
            if fromHead {
                candidate.append(visible)
            } else {
                candidate.setAttributedString(visible)
                candidate.append(ellipsis)
            }
            if candidate.size().width <= width {
                best = candidate
                low = kept + 1
            } else {
                high = kept - 1
            }
        }
        return best
    }

    private static func listTitle(
        for item: ClipboardItem, customTitle: String?, locale: Locale
    ) -> String {
        if let customTitle, !customTitle.isEmpty { return boundedTitle(customTitle) }

        switch item.kind {
        case .image:
            return item.defaultTitle(locale: locale)
        case .path:
            return item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .link:
            let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let url = URL(string: text), let host = url.host else { return text }
            var title = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if let port = url.port { title += ":\(port)" }
            if url.path != "/" { title += url.path }
            if let query = url.query, !query.isEmpty { title += "?\(query)" }
            if let fragment = url.fragment, !fragment.isEmpty { title += "#\(fragment)" }
            return boundedTitle(title)
        case .text, .markdown, .code:
            let text = item.text ?? ""
            let sample = text.prefix(201)
            let lineEnd = sample.firstIndex(where: \.isNewline) ?? sample.endIndex
            let line = String(sample[..<lineEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            let visible = String(line.prefix(200))
            let hasMore = lineEnd < sample.endIndex
                ? text.index(after: lineEnd) < text.endIndex : sample.count > 200
            return hasMore ? visible + "…" : visible
        }
    }

    private static func boundedTitle(_ title: String) -> String {
        let prefix = title.prefix(513)
        return prefix.count > 512 ? String(prefix.prefix(512)) + "…" : title
    }

    func setSelected(_ selected: Bool) {
        // Offscreen preparation must produce a finished first frame, not enqueue a fade
        // that starts only after the palette has already appeared.
        guard window?.isVisible == true else {
            self.selected = selected
            setHighlightOpacity(selected ? 1 : 0)
            return
        }
        guard self.selected != selected else { return }
        let briefVisit = !selected && (
            entranceQueued
                || selectionBeganAt.map {
                    CACurrentMediaTime() - $0 < HighlightMotion.briefVisitThreshold
                } == true
        )
        self.selected = selected
        entranceQueued = selected
        selectionBeganAt = selected ? CACurrentMediaTime() : nil
        fadeToken += 1
        let token = fadeToken
        // The scroll view disables layer actions while scrolling. Start the explicit fade after
        // that transaction, and ignore it if the cell has since been reused or changed again.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.fadeToken == token else { return }
            self.entranceQueued = false
            if briefVisit {
                self.animateBriefVisit()
            } else {
                self.animateHighlight(to: self.selected ? 1 : 0)
            }
        }
    }

    private func updateHighlightColor() {
        guard let layer = highlightView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = NSColor.labelColor.withAlphaComponent(HighlightMotion.fillAlpha).cgColor
        CATransaction.commit()
    }

    private func setHighlightOpacity(_ opacity: Float) {
        fadeToken += 1
        entranceQueued = false
        selectionBeganAt = nil
        guard let layer = highlightView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "hoverFade")
        layer.opacity = opacity
        CATransaction.commit()
    }

    private func animateHighlight(to opacity: Float) {
        guard let layer = highlightView.layer else { return }
        let current = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        layer.removeAnimation(forKey: "hoverFade")
        guard abs(current - opacity) > 0.01 else {
            CATransaction.commit()
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = opacity
        animation.duration = opacity > current
            ? HighlightMotion.enterDuration : HighlightMotion.exitDuration
        animation.timingFunction = opacity > current
            ? CAMediaTimingFunction(controlPoints: 0.17, 0.82, 0.25, 1)
            : CAMediaTimingFunction(controlPoints: 0.32, 0, 0.68, 1)
        layer.add(animation, forKey: "hoverFade")
        CATransaction.commit()
    }

    /// A row crossed before its deferred fade begins still gets a soft, short-lived trace.
    /// This makes rapid pointer sweeps and trackpad scrolling read as a continuous transition.
    private func animateBriefVisit() {
        guard let layer = highlightView.layer else { return }
        let current = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.removeAnimation(forKey: "hoverFade")
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [current, max(current, HighlightMotion.tracePeak), 0]
        animation.keyTimes = [0, 0.18, 1]
        animation.duration = HighlightMotion.traceDuration
        animation.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.17, 0.82, 0.25, 1),
            CAMediaTimingFunction(controlPoints: 0.32, 0, 0.68, 1),
        ]
        layer.add(animation, forKey: "hoverFade")
        CATransaction.commit()
    }
}

private final class ClipboardThumbnailView: NSView {
    /// Well above the 48 device pixels needed by the 24pt row slot on a 2× display, leaving enough
    /// source detail for high-quality final downsampling.
    private static let imageMaxPixel: CGFloat = 128

    private let symbolView = NSImageView()
    private var representedID: ClipboardItem.ID?
    private var loadTask: Task<Void, Never>?
    private var displayedImage: NSImage?
    private var placeholderKind: ClipboardItem.Kind = .image

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.thumbnail
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill

        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbolView)

        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 16),
            symbolView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        refreshAppearance()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image = displayedImage, image.size.width > 0, image.size.height > 0 else {
            return
        }
        let factor = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        let destination = NSRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
            width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: destination, from: .zero, operation: .copy, fraction: 1,
            respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    func configure(item: ClipboardItem, imageURL: URL?) {
        loadTask?.cancel()
        representedID = item.id
        displayedImage = nil

        switch item.kind {
        case .text, .markdown, .code, .link, .path:
            showKind(item.kind)
        case .image:
            showKind(.image)
            guard let imageURL else { return }
            if let cached = ImageThumbnail.cached(
                imageURL, maxPixel: Self.imageMaxPixel)
            {
                showImage(cached)
                return
            }
            let id = item.id
            loadTask = Task { @MainActor [weak self] in
                let image = await ImageThumbnail.loadAsync(
                    imageURL, maxPixel: Self.imageMaxPixel)
                guard !Task.isCancelled, let self, representedID == id, let image else { return }
                showImage(image)
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        representedID = nil
        displayedImage = nil
        showKind(.image)
    }

    func refreshAppearance() {
        guard let displayedImage else {
            showKind(placeholderKind)
            return
        }
        showImage(displayedImage)
    }

    private func showKind(_ kind: ClipboardItem.Kind) {
        placeholderKind = kind
        displayedImage = nil
        layer?.contents = nil
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        needsDisplay = true
        symbolView.isHidden = false
        symbolView.contentTintColor = .labelColor
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        symbolView.image = image
    }

    private func showImage(_ image: NSImage) {
        displayedImage = image
        symbolView.isHidden = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contents = nil
        needsDisplay = true
    }
}
