import Cocoa

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

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

/// Safari-style tab: centered title, close button appears on the left on hover/selection.
final class TabItemView: NSView {
    static let closeSize: CGFloat = 16
    static let closeInset: CGFloat = 5
    // Symmetric space reserved on both sides so the centered title never overlaps the close button.
    static let sideInset: CGFloat = closeInset + closeSize + 4
    static let minWidth: CGFloat = 80
    static let maxWidth: CGFloat = 180

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    var title = "" {
        didSet {
            titleLabel.stringValue = title
            toolTip = title
            setAccessibilityLabel(title)
        }
    }
    var isSelected = false { didSet { refresh() } }
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

    private func refresh() {
        titleLabel.font = .systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        closeButton.isHidden = !(isClosable && (isSelected || hovered))
        setAccessibilitySelected(isSelected)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 7
        let alpha: CGFloat = isSelected ? 0.10 : (hovered ? 0.05 : 0)
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        closeButton.frame = NSRect(
            x: Self.closeInset,
            y: (bounds.height - Self.closeSize) / 2,
            width: Self.closeSize,
            height: Self.closeSize
        )
        // NSTextField labels pad their text by 2pt per side; widen the frame to compensate.
        let labelHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(
            x: Self.sideInset - 2,
            y: (bounds.height - labelHeight) / 2,
            width: max(0, bounds.width - Self.sideInset * 2 + 4),
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
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, isClosable { onClose?() } // middle click
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Browser-style tab strip: left-aligned tabs, "+" right after the last tab,
/// horizontal scrolling when tabs overflow (with "+" pinned to the right edge).
final class TabBarView: NSView {
    static let tabHeight: CGFloat = 26
    static let spacing: CGFloat = 4
    static let addSize: CGFloat = 24

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?

    private let scrollView = NSScrollView()
    private let strip = FlippedView()
    private let addButton = IconButton(symbolName: "plus", pointSize: 11, weight: .semibold, cornerRadius: 6, label: "새 탭")
    private var items: [TabItemView] = []
    private var selectedIndex = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = strip
        addSubview(scrollView)

        addButton.toolTip = "새 탭 (⌘T)"
        addButton.onClick = { [weak self] in self?.onAdd?() }
        addSubview(addButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(titles: [String], selectedIndex: Int) {
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
        }
        self.selectedIndex = selectedIndex
        relayout()
        scrollSelectedIntoView()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        relayout()
    }

    private func relayout() {
        let y = (bounds.height - Self.tabHeight) / 2
        var x: CGFloat = 0
        for item in items {
            let width = item.preferredWidth
            item.frame = NSRect(x: x, y: y, width: width, height: Self.tabHeight)
            x += width + Self.spacing
        }
        let contentWidth = max(0, x - Self.spacing)
        let visibleWidth = min(contentWidth, max(0, bounds.width - Self.addSize - Self.spacing))
        strip.frame = NSRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
        scrollView.frame = NSRect(x: 0, y: 0, width: visibleWidth, height: bounds.height)
        addButton.frame = NSRect(
            x: visibleWidth + Self.spacing,
            y: (bounds.height - Self.addSize) / 2,
            width: Self.addSize,
            height: Self.addSize
        )
    }

    private func scrollSelectedIntoView() {
        guard items.indices.contains(selectedIndex) else { return }
        strip.scrollToVisible(items[selectedIndex].frame.insetBy(dx: -8, dy: 0))
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
