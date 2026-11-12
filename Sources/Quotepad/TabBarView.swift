import Cocoa

final class SeparatorView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

/// Borderless SF Symbol button with a rounded hover/press background.
final class IconButton: NSView {
    var onClick: (() -> Void)?
    private let imageView = NSImageView()
    private let cornerRadius: CGFloat
    private let symbolConfig: NSImage.SymbolConfiguration
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(symbolName: String, pointSize: CGFloat, weight: NSFont.Weight, cornerRadius: CGFloat, label: String) {
        self.cornerRadius = cornerRadius
        self.symbolConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        super.init(frame: .zero)
        wantsLayer = true
        setSymbol(symbolName, label: label)
        imageView.imageScaling = .scaleNone
        addSubview(imageView)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ symbolName: String, label: String) {
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
            .withSymbolConfiguration(symbolConfig)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        let alpha: CGFloat = pressed ? 0.16 : (hovered ? 0.08 : 0)
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        imageView.contentTintColor = hovered ? .labelColor : .secondaryLabelColor
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        imageView.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Safari-style tab: a softly lit rounded chip with a centered title; the close button
/// appears on the left on hover/selection.
final class TabItemView: NSView {
    static let closeSize: CGFloat = 16
    static let closeInset: CGFloat = 5
    // Symmetric space reserved on both sides so the centered title never overlaps the close button.
    static let sideInset: CGFloat = closeInset + closeSize + 4
    // Below this width the title gives up centering and only makes room for the close button when it's shown.
    static let compactWidth: CGFloat = sideInset * 2 + 36
    static let compactInset: CGFloat = 7
    static let minWidth: CGFloat = 64
    static let maxWidth: CGFloat = 180

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// Pressing, dragging and releasing the tab: the bar moves it to reorder the tabs.
    var onDrag: ((NSEvent, DragPhase) -> Void)?

    enum DragPhase { case began, moved, ended }

    var title = "" {
        didSet {
            titleLabel.stringValue = title
            toolTip = title
            setAccessibilityLabel(title)
        }
    }
    var isSelected = false { didSet { refresh() } }
    /// Being dragged: drawn solid with a shadow, lifted over the tabs it passes.
    var isLifted = false { didSet { needsDisplay = true } }
    var isClosable = true { didSet { refresh() } }

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = IconButton(symbolName: "xmark", pointSize: 8.5, weight: .bold, cornerRadius: 4, label: "탭 닫기")
    private var hovered = false { didSet { refresh() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.alignment = .center
        titleLabel.cell?.truncatesLastVisibleLine = true
        addSubview(titleLabel)
        closeButton.onClick = { [weak self] in self?.onClose?() }
        addSubview(closeButton)
        setAccessibilityRole(.radioButton)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let measuringLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }()

    // Measured with a label one weight heavier than selected so the width never
    // truncates and doesn't jump when selection changes.
    var preferredWidth: CGFloat {
        Self.measuringLabel.stringValue = title
        let textWidth = Self.measuringLabel.intrinsicContentSize.width
        let width = ceil(textWidth) + 4 + Self.sideInset * 2
        return min(max(width, Self.minWidth), Self.maxWidth)
    }

    private var closeVisible: Bool { isClosable && (isSelected || hovered) }

    private func refresh() {
        titleLabel.font = .systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        closeButton.isHidden = !closeVisible
        setAccessibilitySelected(isSelected)
        needsDisplay = true
        layoutContents()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 7
        let alpha: CGFloat = isSelected ? 0.15 : (hovered ? 0.10 : 0.06)
        if isLifted {
            let solid = NSColor.windowBackgroundColor.blended(withFraction: 0.3, of: .labelColor) ?? .windowBackgroundColor
            layer?.backgroundColor = solid.cgColor
            layer?.shadowOpacity = 0.3
            layer?.shadowRadius = 4
            layer?.shadowOffset = CGSize(width: 0, height: -1)
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
            layer?.shadowOpacity = 0
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutContents()
    }

    private func layoutContents() {
        closeButton.frame = NSRect(
            x: Self.closeInset,
            y: (bounds.height - Self.closeSize) / 2,
            width: Self.closeSize,
            height: Self.closeSize
        )
        let compact = bounds.width < Self.compactWidth
        let left = compact ? (closeVisible ? Self.sideInset : Self.compactInset) : Self.sideInset
        let right = compact ? Self.compactInset : Self.sideInset
        // NSTextField labels pad their text by 2pt per side; widen the frame to compensate.
        let labelHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(
            x: left - 2,
            y: (bounds.height - labelHeight) / 2,
            width: max(0, bounds.width - left - right + 4),
            height: labelHeight
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {
        onSelect?()
        onDrag?(event, .began)
    }
    override func mouseDragged(with event: NSEvent) { onDrag?(event, .moved) }
    override func mouseUp(with event: NSEvent) { onDrag?(event, .ended) }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, isClosable { onClose?() } // middle click
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Safari-style tab strip: left-aligned tabs with "+" right after the last one. When space runs out
/// the widest tabs shrink first (titles truncate with "…"), down to a still readable width; past that
/// the strip scrolls sideways, with the clipped edges fading out. The selected tab is scrolled into view.
/// Tabs are reordered by dragging them; the others slide out of the way.
final class TabBarView: NSView {
    static let tabHeight: CGFloat = 26
    static let spacing: CGFloat = 4
    static let addSize: CGFloat = 24
    /// Tabs don't shrink below this (or their own width) to fit: the strip scrolls instead.
    static let scrollingWidth: CGFloat = 120
    static let fadeWidth: CGFloat = 18
    /// How far the mouse has to move before a press on a tab becomes a drag.
    static let dragThreshold: CGFloat = 4
    /// Dragging a tab this close to the strip's edge scrolls the strip.
    static let autoScrollEdge: CGFloat = 28

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    /// A tab was dragged from one position to another.
    var onMove: ((Int, Int) -> Void)?

    private let addButton = IconButton(symbolName: "plus", pointSize: 11, weight: .semibold, cornerRadius: 6, label: "새 탭")
    private let scrollView = TabScrollView()
    private let strip = NSView()
    private let fadeMask = CAGradientLayer()
    private var items: [TabItemView] = []
    private var selectedIndex = 0

    private struct TabDrag {
        let item: TabItemView
        let from: Int
        let startX: CGFloat
        /// Where in the tab it was grabbed, so it doesn't jump under the mouse.
        let grab: CGFloat
        var point: NSPoint
        var active = false
    }
    private var drag: TabDrag?
    private var autoScrollTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addButton.toolTip = "새 탭 (⌘T)"
        addButton.onClick = { [weak self] in self?.onAdd?() }
        addSubview(addButton)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = strip
        scrollView.wantsLayer = true
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        scrollView.layer?.mask = fadeMask
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(stripDidScroll),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        addSubview(scrollView)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(titles: [String], selectedIndex: Int) {
        guard drag?.active != true else { return } // the order on screen is mid-change; the drop updates it
        let changed = selectedIndex != self.selectedIndex || titles.count != items.count
        while items.count < titles.count {
            let item = TabItemView()
            strip.addSubview(item)
            items.append(item)
        }
        while items.count > titles.count {
            items.removeLast().removeFromSuperview()
        }
        let closable = titles.count > 1
        for (index, item) in items.enumerated() {
            item.title = titles[index]
            item.isSelected = index == selectedIndex
            item.isClosable = closable
            item.onSelect = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
            item.onDrag = { [weak self, weak item] event, phase in
                if let item { self?.handleDrag(of: item, event: event, phase: phase) }
            }
        }
        self.selectedIndex = selectedIndex
        relayout()
        if changed { revealSelected(animated: window?.isVisible == true) }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        relayout()
    }

    private func relayout() {
        let y = (bounds.height - Self.tabHeight) / 2
        let budget = max(0, bounds.width - Self.addSize - Self.spacing)
        let gaps = Self.spacing * CGFloat(max(0, items.count - 1))
        let preferred = items.map(\.preferredWidth)
        let widths = zip(Self.fit(preferred, into: budget - gaps), preferred).map { fitted, own in
            max(fitted, min(own, Self.scrollingWidth))
        }
        let contentWidth = widths.reduce(0, +) + gaps

        var x: CGFloat = 0
        for (index, item) in items.enumerated() {
            item.frame = NSRect(x: x, y: 0, width: widths[index], height: Self.tabHeight)
            x += widths[index] + Self.spacing
        }
        strip.frame = NSRect(x: 0, y: 0, width: contentWidth, height: Self.tabHeight)
        let visibleWidth = min(contentWidth, budget)
        scrollView.frame = NSRect(x: 0, y: y, width: visibleWidth, height: Self.tabHeight)
        // Keeps the scroll position inside the strip after tabs close or the bar widens.
        let clip = scrollView.contentView
        let maxX = max(0, contentWidth - visibleWidth)
        if clip.bounds.origin.x > maxX {
            clip.scroll(to: NSPoint(x: maxX, y: 0))
            scrollView.reflectScrolledClipView(clip)
        }
        addButton.frame = NSRect(x: visibleWidth + Self.spacing, y: (bounds.height - Self.addSize) / 2,
                                 width: Self.addSize, height: Self.addSize)
        updateFades()
    }

    /// Scrolls just far enough to show the selected tab whole, with a little of its neighbor.
    private func revealSelected(animated: Bool) {
        guard items.indices.contains(selectedIndex) else { return }
        let clip = scrollView.contentView
        let frame = items[selectedIndex].frame
        let visible = clip.bounds
        let margin = Self.fadeWidth
        var x = visible.origin.x
        if frame.minX - margin < visible.minX {
            x = frame.minX - margin
        } else if frame.maxX + margin > visible.maxX {
            x = frame.maxX + margin - visible.width
        }
        x = min(max(0, x), max(0, strip.frame.width - visible.width))
        guard x != visible.origin.x else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
            }
        } else {
            clip.scroll(to: NSPoint(x: x, y: 0))
        }
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Reordering

    private func handleDrag(of item: TabItemView, event: NSEvent, phase: TabItemView.DragPhase) {
        switch phase {
        case .began:
            guard items.count > 1, let from = items.firstIndex(of: item) else { return }
            let x = strip.convert(event.locationInWindow, from: nil).x
            drag = TabDrag(item: item, from: from, startX: event.locationInWindow.x, grab: x - item.frame.minX,
                           point: event.locationInWindow)
        case .moved:
            guard var current = drag, current.item === item else { return }
            current.point = event.locationInWindow
            if !current.active {
                guard abs(current.point.x - current.startX) >= Self.dragThreshold else { return }
                current.active = true
                strip.addSubview(item, positioned: .above, relativeTo: nil) // over the tabs it passes
                item.isLifted = true
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.autoScroll() }
                RunLoop.main.add(timer, forMode: .common)
                autoScrollTimer = timer
            }
            drag = current
            follow(to: current.point)
        case .ended:
            endDrag()
        }
    }

    /// Moves the dragged tab under the mouse, and the other tabs to make room where it would land.
    private func follow(to windowPoint: NSPoint) {
        guard let drag else { return }
        let item = drag.item
        let x = strip.convert(windowPoint, from: nil).x - drag.grab
        item.setFrameOrigin(NSPoint(x: min(max(0, x), max(0, strip.frame.width - item.frame.width)), y: 0))
        // Where the mouse would put it, unclamped: dragging past either end still passes the end tab.
        let midX = x + item.frame.width / 2

        // It trades places with a neighbor once its middle crosses the neighbor's.
        guard var index = items.firstIndex(of: item) else { return }
        let start = index
        func slotX(_ i: Int) -> CGFloat { items[..<i].reduce(0) { $0 + $1.frame.width + Self.spacing } }
        while index + 1 < items.count, midX > slotX(index + 1) + items[index + 1].frame.width / 2 {
            items.swapAt(index, index + 1)
            index += 1
        }
        while index > 0, midX < slotX(index - 1) + items[index - 1].frame.width / 2 {
            items.swapAt(index, index - 1)
            index -= 1
        }
        guard index != start else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            var x: CGFloat = 0
            for tab in items {
                if tab !== item { tab.animator().setFrameOrigin(NSPoint(x: x, y: 0)) }
                x += tab.frame.width + Self.spacing
            }
        }
    }

    /// Near either end of the strip, a dragged tab scrolls it, faster the closer it gets.
    private func autoScroll() {
        guard let drag, drag.active else { return }
        let x = scrollView.convert(drag.point, from: nil).x
        let width = scrollView.bounds.width
        var delta: CGFloat = 0
        if x < Self.autoScrollEdge {
            delta = -min(12, (Self.autoScrollEdge - x) / 3)
        } else if x > width - Self.autoScrollEdge {
            delta = min(12, (x - (width - Self.autoScrollEdge)) / 3)
        }
        let clip = scrollView.contentView
        let maxX = max(0, strip.frame.width - clip.bounds.width)
        let newX = min(max(0, clip.bounds.origin.x + delta), maxX)
        guard newX != clip.bounds.origin.x else { return }
        clip.scroll(to: NSPoint(x: newX, y: 0))
        scrollView.reflectScrolledClipView(clip)
        follow(to: drag.point)
    }

    /// Drops the dragged tab: it slides into its slot and the new order is passed on.
    private func endDrag() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        guard let finished = drag else { return }
        drag = nil
        guard finished.active, let to = items.firstIndex(of: finished.item) else { return }
        finished.item.isLifted = false
        let dropped = finished.item.frame
        // The views are already in the new order, so the update that follows keeps each on its tab.
        relayout()
        if to != finished.from { onMove?(finished.from, to) }
        let slot = finished.item.frame
        finished.item.frame = dropped
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            finished.item.animator().frame = slot
        }
    }

    @objc private func stripDidScroll() { updateFades() }

    /// Fades out an edge that has tabs scrolled past it.
    private func updateFades() {
        let bounds = scrollView.bounds
        let offset = scrollView.contentView.bounds.origin.x
        let fadeLeft = offset > 0.5
        let fadeRight = offset + bounds.width < strip.frame.width - 0.5
        let fraction = bounds.width > 0 ? min(0.5, Self.fadeWidth / bounds.width) : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        fadeMask.colors = [fadeLeft ? NSColor.clear.cgColor : NSColor.black.cgColor, NSColor.black.cgColor,
                           NSColor.black.cgColor, fadeRight ? NSColor.clear.cgColor : NSColor.black.cgColor]
        fadeMask.locations = [0, NSNumber(value: Double(fraction)), NSNumber(value: Double(1 - fraction)), 1]
        CATransaction.commit()
    }

    /// Shrinks the widest entries first until the total fits `budget`; unchanged when it already fits.
    private static func fit(_ preferred: [CGFloat], into budget: CGFloat) -> [CGFloat] {
        guard preferred.reduce(0, +) > budget else { return preferred }
        let sorted = preferred.sorted()
        var remaining = budget
        var cap = sorted.last ?? 0
        for (position, width) in sorted.enumerated() {
            let share = remaining / CGFloat(sorted.count - position)
            if share < width {
                cap = share
                break
            }
            remaining -= width
        }
        return preferred.map { floor(min($0, cap)) }
    }

    // Empty bar area: double-click opens a new tab, drag moves the window.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onAdd?()
        } else {
            window?.performDrag(with: event)
        }
    }
}

/// The tab strip's scroll view: a mouse wheel (or a vertical swipe) scrolls the tabs sideways too.
final class TabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let strip = documentView else {
            return super.scrollWheel(with: event)
        }
        let clip = contentView
        let maxX = max(0, strip.frame.width - clip.bounds.width)
        guard maxX > 0 else { return }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
        clip.scroll(to: NSPoint(x: min(max(0, clip.bounds.origin.x - delta), maxX), y: 0))
        reflectScrolledClipView(clip)
    }
}
