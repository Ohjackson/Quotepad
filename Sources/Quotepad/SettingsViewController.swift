import Cocoa

final class ColorSwatch: NSView {
    let tint: BackgroundTint
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    init(tint: BackgroundTint) {
        self.tint = tint
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        toolTip = tint.name
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(tint.name)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4))
        (tint.color ?? .windowBackgroundColor).setFill()
        circle.fill()
        NSColor.separatorColor.setStroke()
        circle.lineWidth = 1
        circle.stroke()

        if tint.color == nil { // "no tint": diagonal slash
            let slash = NSBezierPath()
            let inner = bounds.insetBy(dx: 7, dy: 7)
            slash.move(to: NSPoint(x: inner.minX, y: inner.minY))
            slash.line(to: NSPoint(x: inner.maxX, y: inner.maxY))
            slash.lineWidth = 1.2
            NSColor.secondaryLabelColor.setStroke()
            slash.stroke()
        }

        if isSelected {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
        setAccessibilitySelected(isSelected)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SettingsViewController: NSViewController {
    private let settings = Settings.shared

    private let themeControl = NSSegmentedControl(labels: ThemeMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private var swatches: [ColorSwatch] = []
    private let opacitySlider = NSSlider(value: 1, minValue: Settings.opacityRange.lowerBound, maxValue: Settings.opacityRange.upperBound, target: nil, action: nil)
    private let opacityLabel = NSTextField(labelWithString: "")
    private let fontSizeSlider = NSSlider(value: 14, minValue: Settings.fontSizeRange.lowerBound, maxValue: Settings.fontSizeRange.upperBound, target: nil, action: nil)
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let spellCheckbox = NSButton(checkboxWithTitle: "맞춤법 검사", target: nil, action: nil)
    private let hideCheckbox = NSButton(checkboxWithTitle: "다른 곳을 클릭하면 숨기기", target: nil, action: nil)
    private let positionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loginCheckbox = NSButton(checkboxWithTitle: "로그인 시 자동 실행", target: nil, action: nil)

    override func loadView() {
        wireControls()

        var rows: [[NSView]] = []
        var headerRows: [Int] = []
        func header(_ title: String) {
            headerRows.append(rows.count)
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            rows.append([label, NSGridCell.emptyContentView])
        }
        func row(_ title: String, _ control: NSView) {
            rows.append([fieldLabel(title), control])
        }
        func row(_ control: NSView) {
            rows.append([NSGridCell.emptyContentView, control])
        }

        header("모양")
        row("테마", themeControl)
        row("배경색", hStack(swatches, spacing: 2))
        row("배경 투명도", hStack([opacitySlider, opacityLabel], spacing: 8))
        header("편집기")
        row("글자 크기", hStack([fontSizeSlider, fontSizeLabel], spacing: 8))
        row("글꼴", fontPopup)
        row(spellCheckbox)
        header("동작")
        row("열릴 위치", positionPopup)
        row(hideCheckbox)
        row(loginCheckbox)

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 9
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        for index in 0..<grid.numberOfRows {
            grid.row(at: index).yPlacement = .center
        }
        for index in headerRows {
            let headerRow = grid.row(at: index)
            headerRow.mergeCells(in: NSRange(location: 0, length: 2))
            headerRow.cell(at: 0).xPlacement = .leading
            if index > 0 { headerRow.topPadding = 8 }
        }

        let shortcuts = NSTextField(wrappingLabelWithString:
            "⌘' 열기/닫기 · ⌘T 새 탭 · ⌘W 탭 닫기 · ⌃Tab 탭 이동\n/code 코드 블록 · /p 복사 박스 · ⌘, 설정 · Esc 숨기기")
        shortcuts.font = .systemFont(ofSize: 11)
        shortcuts.textColor = .tertiaryLabelColor

        let openFolder = smallButton("데이터 폴더 열기", #selector(openDataFolder))
        let reset = smallButton("기본값으로 되돌리기", #selector(resetDefaults))
        let buttons = hStack([openFolder, reset], spacing: 8)

        let divider = NSBox()
        divider.boxType = .separator

        let stack = NSStackView(views: [grid, divider, shortcuts, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        view = stack
        preferredContentSize = stack.fittingSize
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadControls()
    }

    private func wireControls() {
        themeControl.target = self
        themeControl.action = #selector(themeChanged)

        swatches = BackgroundTint.all.map { tint in
            let swatch = ColorSwatch(tint: tint)
            swatch.onClick = { [weak self] in
                self?.settings.tint = tint
                self?.reloadControls()
            }
            return swatch
        }

        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.isContinuous = true
        opacitySlider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        configureValueLabel(opacityLabel)

        fontSizeSlider.target = self
        fontSizeSlider.action = #selector(fontSizeChanged)
        fontSizeSlider.isContinuous = true
        fontSizeSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        configureValueLabel(fontSizeLabel)

        fontPopup.addItems(withTitles: EditorFont.allCases.map(\.title))
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)

        positionPopup.addItems(withTitles: OpenPosition.allCases.map(\.title))
        positionPopup.target = self
        positionPopup.action = #selector(positionChanged)

        spellCheckbox.target = self
        spellCheckbox.action = #selector(spellCheckChanged)
        hideCheckbox.target = self
        hideCheckbox.action = #selector(hideChanged)
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged)
    }

    private func reloadControls() {
        themeControl.selectedSegment = settings.theme.rawValue
        let tintID = settings.tint.id
        swatches.forEach { $0.isSelected = $0.tint.id == tintID }
        opacitySlider.doubleValue = settings.opacity
        opacityLabel.stringValue = "\(Int((settings.opacity * 100).rounded()))%"
        fontSizeSlider.doubleValue = settings.fontSize
        fontSizeLabel.stringValue = "\(Int(settings.fontSize))pt"
        fontPopup.selectItem(at: settings.editorFont.rawValue)
        spellCheckbox.state = settings.spellCheck ? .on : .off
        hideCheckbox.state = settings.hideOnFocusLoss ? .on : .off
        positionPopup.selectItem(at: settings.openPosition.rawValue)
        loginCheckbox.isEnabled = LoginItem.isAvailable
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off
        loginCheckbox.toolTip = LoginItem.isAvailable ? nil : ".app으로 설치한 경우에만 사용할 수 있어요"
    }

    // MARK: - Actions

    @objc private func themeChanged() {
        settings.theme = ThemeMode(rawValue: themeControl.selectedSegment) ?? .system
    }

    @objc private func opacityChanged() {
        settings.opacity = (opacitySlider.doubleValue * 20).rounded() / 20 // 5% steps
        opacityLabel.stringValue = "\(Int((settings.opacity * 100).rounded()))%"
    }

    @objc private func fontSizeChanged() {
        settings.fontSize = fontSizeSlider.doubleValue.rounded()
        fontSizeLabel.stringValue = "\(Int(settings.fontSize))pt"
    }

    @objc private func fontChanged() {
        settings.editorFont = EditorFont(rawValue: fontPopup.indexOfSelectedItem) ?? .system
    }

    @objc private func positionChanged() {
        settings.openPosition = OpenPosition(rawValue: positionPopup.indexOfSelectedItem) ?? .topCenter
    }

    @objc private func spellCheckChanged() {
        settings.spellCheck = spellCheckbox.state == .on
    }

    @objc private func hideChanged() {
        settings.hideOnFocusLoss = hideCheckbox.state == .on
    }

    @objc private func loginChanged() {
        if let message = LoginItem.setEnabled(loginCheckbox.state == .on) {
            showAlert("로그인 항목 설정에 실패했어요", message)
        }
        reloadControls()
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([tabsFileURL])
    }

    @objc private func resetDefaults() {
        settings.resetToDefaults()
        reloadControls()
    }

    // MARK: - Helpers

    private func fieldLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        return label
    }

    private func configureValueLabel(_ label: NSTextField) {
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 38).isActive = true
    }

    private func hStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = .centerY
        return stack
    }

    private func smallButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return button
    }
}
