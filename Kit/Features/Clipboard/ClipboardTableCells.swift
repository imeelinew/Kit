import AppKit
import QuartzCore

final class ClipboardSectionCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private var topConstraint: NSLayoutConstraint!
    private var centerYConstraint: NSLayoutConstraint!

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
        centerYConstraint = titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            topConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, isFirst: Bool, centered: Bool = false) {
        titleLabel.stringValue = title
        NSLayoutConstraint.deactivate([topConstraint, centerYConstraint])
        NSLayoutConstraint.activate([centered ? centerYConstraint : topConstraint])
        topConstraint.constant = isFirst ? Theme.Spacing.xs : Theme.Spacing.sectionSpacing
    }
}

final class ClipboardItemCellView: NSTableCellView {
    private final class VerticallyCenteredTextCell: NSTextFieldCell {
        override func drawingRect(forBounds rect: NSRect) -> NSRect {
            var drawingRect = super.drawingRect(forBounds: rect)
            let textHeight = cellSize(forBounds: rect).height
            drawingRect.origin.y = rect.midY - textHeight / 2
            drawingRect.size.height = textHeight
            return drawingRect
        }
    }

    private static var titleFont: NSFont {
        ClipboardPreviewFont.regular(
            ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize + 1)
    }

    private enum HighlightMotion {
        static let fillAlpha: CGFloat = 0.11
        static let briefVisitThreshold: CFTimeInterval = 0.06
        static let enterDuration: CFTimeInterval = 0.19
        static let exitDuration: CFTimeInterval = 0.24
        static let tracePeak: Float = 0.45
        static let traceDuration: CFTimeInterval = 0.22
    }

    /// AppKit may replace backing layers while retaining the cell across presentations.
    /// Keep the fill in its drawing lifecycle and opacity in NSView's persistent alphaValue.
    private final class HighlightView: NSView {
        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            guard let layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.cornerRadius = Theme.Radius.row
            layer.cornerCurve = .continuous
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer.backgroundColor = NSColor.labelColor.withAlphaComponent(HighlightMotion.fillAlpha).cgColor
            }
            CATransaction.commit()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }

    private let highlightView = HighlightView()
    private let thumbnailView = ClipboardThumbnailView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var fullTitle = NSAttributedString(string: "")
    private var standardConstraints: [NSLayoutConstraint] = []
    private var imageConstraints: [NSLayoutConstraint] = []
    private var truncatesFromHead = false
    private var renderedTitleWidth: CGFloat = -1
    private var representedID: ClipboardItem.ID?
    private var selected = false
    private var hovered = false
    private var highlighted = false
    private var fadeToken = 0
    private var entranceQueued = false
    private var selectionBeganAt: CFTimeInterval?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        highlightView.wantsLayer = true
        highlightView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        highlightView.translatesAutoresizingMaskIntoConstraints = false

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.cell = VerticallyCenteredTextCell(textCell: "")
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.font = Self.titleFont
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
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            titleLabel.heightAnchor.constraint(equalToConstant: Theme.Size.rowIcon),
        ])
        standardConstraints = [
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: Theme.Size.rowIcon),
            thumbnailView.heightAnchor.constraint(equalToConstant: Theme.Size.rowIcon),

            titleLabel.leadingAnchor.constraint(
                equalTo: thumbnailView.trailingAnchor, constant: Theme.Spacing.lg),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        imageConstraints = [
            thumbnailView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            thumbnailView.heightAnchor.constraint(equalToConstant: 56),
            titleLabel.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 4),
        ]
        NSLayoutConstraint.activate(standardConstraints)
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
        hovered = false
        highlighted = false
        setHighlightOpacity(0)
        titleLabel.isHidden = false
        fullTitle = NSAttributedString(string: "")
        renderedTitleWidth = -1
        thumbnailView.prepareForReuse()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        thumbnailView.refreshAppearance()
    }

    func configure(
        item: ClipboardItem, selected: Bool, query: String, imageURL: URL?, locale: Locale
    ) {
        if representedID != item.id {
            // Reused cells must never carry a previous item's highlight or pending fade.
            representedID = item.id
            self.selected = false
            hovered = false
            highlighted = false
            setHighlightOpacity(0)
        }
        setSelected(selected)
        updateTitle(item: item, query: query, locale: locale)
        thumbnailView.configure(item: item, imageURL: imageURL)
    }

    func updateTitle(item: ClipboardItem, query: String, locale: Locale) {
        let customTitle = item.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCustomTitle = customTitle?.isEmpty == false
        let isImage = item.kind == .image
        let showsImageTitle = isImage && (hasCustomTitle || item.isFileBacked)
        NSLayoutConstraint.deactivate(isImage ? standardConstraints : imageConstraints)
        NSLayoutConstraint.activate(isImage ? imageConstraints : standardConstraints)
        titleLabel.isHidden = isImage && !showsImageTitle
        // Keep inline image rows identifiable to VoiceOver without a redundant visible label.
        thumbnailView.setAccessibilityElement(isImage)
        thumbnailView.setAccessibilityRole(isImage ? .image : .unknown)
        thumbnailView.setAccessibilityLabel(isImage ? item.displayTitle(locale: locale) : nil)
        truncatesFromHead = item.kind == .path && !hasCustomTitle
        fullTitle = SearchHighlight.nsAttributed(
            Self.listTitle(for: item, customTitle: customTitle, locale: locale),
            query: query,
            font: Self.titleFont)
        renderedTitleWidth = -1
        renderTitle()
    }

    func refreshThumbnail(item: ClipboardItem, imageURL: URL?) {
        guard item.isFileBacked else { return }
        thumbnailView.configure(item: item, imageURL: imageURL)
    }

    static func rowHeight(for item: ClipboardItem) -> CGFloat {
        guard item.kind == .image else { return 36 }
        let hasCustomTitle = item.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        return item.isFileBacked || hasCustomTitle ? 92 : 72
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
            font: titleLabel.font ?? Self.titleFont)
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
        case .file:
            return item.defaultTitle(locale: locale)
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
        self.selected = selected
        updateHighlight(animated: true)
    }

    func setHovered(_ hovered: Bool, animated: Bool = true) {
        self.hovered = hovered
        updateHighlight(animated: animated)
    }

    private func updateHighlight(animated: Bool) {
        let highlighted = selected || hovered
        // Offscreen preparation must produce a finished first frame, not enqueue a fade
        // that starts only after the palette has already appeared.
        guard window?.isVisible == true else {
            self.highlighted = highlighted
            setHighlightOpacity(highlighted ? 1 : 0)
            return
        }
        guard self.highlighted != highlighted else { return }
        guard animated else {
            self.highlighted = highlighted
            setHighlightOpacity(highlighted ? 1 : 0)
            return
        }
        let briefVisit = !highlighted && (
            entranceQueued
                || selectionBeganAt.map {
                    CACurrentMediaTime() - $0 < HighlightMotion.briefVisitThreshold
                } == true
        )
        self.highlighted = highlighted
        entranceQueued = highlighted
        selectionBeganAt = highlighted ? CACurrentMediaTime() : nil
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
                self.animateHighlight(to: self.highlighted ? 1 : 0)
            }
        }
    }

    private func setHighlightOpacity(_ opacity: Float) {
        fadeToken += 1
        entranceQueued = false
        selectionBeganAt = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightView.layer?.removeAnimation(forKey: "hoverFade")
        highlightView.alphaValue = CGFloat(opacity)
        CATransaction.commit()
    }

    private func animateHighlight(to opacity: Float) {
        guard let layer = highlightView.layer else { return }
        let current = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightView.alphaValue = CGFloat(opacity)
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
    /// This keeps rapid pointer sweeps continuous without animating scroll-driven hover changes
    private func animateBriefVisit() {
        guard let layer = highlightView.layer else { return }
        let current = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightView.alphaValue = 0
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
    /// Covers a full-width preview on a 2× display, including wide screenshots.
    private static let imageMaxPixel = ImageThumbnail.rowMaxPixel

    private let symbolView = NSImageView()
    private var representedID: ClipboardItem.ID?
    private var representedURL: URL?
    private var representedVersion: UInt64?
    private var loadTask: Task<Void, Never>?
    private var displayedImage: NSImage?
    private var displayedFileIcon: NSImage?
    private var finishedLoading = false
    private var placeholderKind: ClipboardItem.Kind = .image

    deinit { loadTask?.cancel() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        symbolView.wantsLayer = true
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
        let factor = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        let destination = NSRect(
            x: bounds.minX, y: bounds.midY - size.height / 2,
            width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        let radius = min(Theme.Radius.thumbnail, min(size.width, size.height) / 2)
        let outline = NSBezierPath(roundedRect: destination, xRadius: radius, yRadius: radius)
        outline.addClip()
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        outline.fill()
        image.draw(
            in: destination, from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    func configure(item: ClipboardItem, imageURL: URL?) {
        let sourceURL = imageURL ?? item.fileURLs.first
        let sourceVersion = sourceURL.map { ImageThumbnail.fileVersion(for: $0) }
        let usesFileContents = item.kind == .image || item.kind == .file
        if usesFileContents, representedID == item.id, representedURL == sourceURL,
            representedVersion == sourceVersion,
            finishedLoading || loadTask != nil
        { return }
        loadTask?.cancel()
        loadTask = nil
        representedID = item.id
        representedURL = sourceURL
        representedVersion = sourceVersion
        displayedImage = nil
        displayedFileIcon = nil
        finishedLoading = false

        switch item.kind {
        case .text, .markdown, .code, .link, .path:
            showKind(item.kind)
            finishedLoading = true
        case .image:
            showKind(.image)
            guard let imageURL, FileManager.default.fileExists(atPath: imageURL.path) else {
                finishedLoading = true
                return
            }
            if let cached = ImageThumbnail.cached(
                imageURL, maxPixel: Self.imageMaxPixel)
            {
                showImage(cached)
                finishedLoading = true
                return
            }
            let id = item.id
            loadTask = Task { @MainActor [weak self] in
                let image = await ImageThumbnail.loadAsync(
                    imageURL, maxPixel: Self.imageMaxPixel)
                guard !Task.isCancelled, let self, representedID == id,
                    representedVersion == sourceVersion,
                    sourceVersion == sourceURL.map({ ImageThumbnail.fileVersion(for: $0) })
                else { return }
                loadTask = nil
                finishedLoading = true
                guard let image else { return }
                showImage(image)
            }
        case .file:
            showKind(.file)
            guard let sourceURL, FileManager.default.fileExists(atPath: sourceURL.path) else {
                finishedLoading = true
                return
            }
            if let cached = IconCache.cached(forFile: sourceURL.path, version: sourceVersion ?? 0) {
                showFileIcon(cached)
                finishedLoading = true
                return
            }
            let id = item.id
            loadTask = Task { @MainActor [weak self] in
                let icon = await IconCache.loadAsync(forFile: sourceURL.path, version: sourceVersion ?? 0)
                guard !Task.isCancelled, let self, representedID == id,
                    representedVersion == sourceVersion,
                    sourceVersion == ImageThumbnail.fileVersion(for: sourceURL)
                else { return }
                loadTask = nil
                finishedLoading = true
                guard let icon else { return }
                showFileIcon(icon)
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        representedID = nil
        representedURL = nil
        representedVersion = nil
        displayedImage = nil
        displayedFileIcon = nil
        finishedLoading = false
        showKind(.image)
    }

    func refreshAppearance() {
        if let displayedImage {
            showImage(displayedImage)
        } else if let displayedFileIcon {
            showFileIcon(displayedFileIcon)
        } else {
            showKind(placeholderKind)
        }
    }

    private func showKind(_ kind: ClipboardItem.Kind) {
        placeholderKind = kind
        displayedImage = nil
        displayedFileIcon = nil
        layer?.contents = nil
        layer?.cornerRadius = Theme.Radius.thumbnail
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
        displayedFileIcon = nil
        symbolView.isHidden = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contents = nil
        needsDisplay = true
    }

    private func showFileIcon(_ image: NSImage) {
        displayedImage = nil
        displayedFileIcon = image
        layer?.contents = nil
        layer?.cornerRadius = Theme.Radius.thumbnail
        layer?.backgroundColor = NSColor.clear.cgColor
        needsDisplay = true
        symbolView.isHidden = false
        symbolView.contentTintColor = nil
        image.isTemplate = false
        symbolView.image = image
    }
}
