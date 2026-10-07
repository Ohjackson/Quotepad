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
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
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
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, isClosable { onClose?() } // middle click
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Browser-style tab strip: left-aligned tabs with "+" right after the last one. Every tab stays
/// visible: when space runs out the widest tabs shrink first (titles truncate with "…"), and tabs
/// that still don't fit at their minimum width move into a "···" menu. The selected tab is always shown.
final class TabBarView: NSView {
    static let tabHeight: CGFloat = 26
    static let spacing: CGFloat = 4
    static let addSize: CGFloat = 24

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?

    private let addButton = IconButton(symbolName: "plus", pointSize: 11, weight: .semibold, cornerRadius: 6, label: "새 탭")
    private let overflowButton = IconButton(symbolName: "ellipsis", pointSize: 11, weight: .semibold, cornerRadius: 6, label: "다른 탭")
    private var items: [TabItemView] = []
    private var selectedIndex = 0
    private var hiddenIndices: [Int] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        addButton.toolTip = "새 탭 (⌘T)"
        addButton.onClick = { [weak self] in self?.onAdd?() }
        addSubview(addButton)

        overflowButton.onClick = { [weak self] in self?.showOverflowMenu() }
        addSubview(overflowButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(titles: [String], selectedIndex: Int) {
        while items.count < titles.count {
            let item = TabItemView()
            addSubview(item)
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
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        relayout()
    }

    private func relayout() {
        let y = (bounds.height - Self.tabHeight) / 2
        let budget = max(0, bounds.width - Self.addSize - Self.spacing)

        var visible = Array(items.indices)
        var widths = Self.fit(items.map(\.preferredWidth), into: budget - Self.spacing * CGFloat(max(0, items.count - 1)))
        hiddenIndices = []
        if widths.contains(where: { $0 < TabItemView.minWidth }) {
            // Overflow: as many minimum-width tabs as fit next to "···", stretched evenly.
            let room = budget - Self.addSize - Self.spacing
            let count = max(1, Int((room + Self.spacing) / (TabItemView.minWidth + Self.spacing)))
            visible = Array(items.indices.prefix(count))
            if !visible.contains(selectedIndex), items.indices.contains(selectedIndex) {
                visible[visible.count - 1] = selectedIndex
            }
            hiddenIndices = items.indices.filter { !visible.contains($0) }
            let width = min(TabItemView.maxWidth, (room - Self.spacing * CGFloat(count - 1)) / CGFloat(count))
            widths = Array(repeating: max(0, floor(width)), count: count)
        }

        var x: CGFloat = 0
        for (slot, index) in visible.enumerated() {
            items[index].isHidden = false
            items[index].frame = NSRect(x: x, y: y, width: widths[slot], height: Self.tabHeight)
            x += widths[slot] + Self.spacing
        }
        for index in hiddenIndices { items[index].isHidden = true }

        overflowButton.isHidden = hiddenIndices.isEmpty
        if !hiddenIndices.isEmpty {
            overflowButton.frame = NSRect(x: x, y: (bounds.height - Self.addSize) / 2, width: Self.addSize, height: Self.addSize)
            overflowButton.toolTip = "다른 탭 \(hiddenIndices.count)개"
            x += Self.addSize + Self.spacing
        }
        addButton.frame = NSRect(x: x, y: (bounds.height - Self.addSize) / 2, width: Self.addSize, height: Self.addSize)
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

    private func showOverflowMenu() {
        let menu = NSMenu()
        for index in hiddenIndices {
            let item = NSMenuItem(title: items[index].title, action: #selector(overflowItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: overflowButton)
    }

    @objc private func overflowItemChosen(_ sender: NSMenuItem) {
        onSelect?(sender.tag)
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
