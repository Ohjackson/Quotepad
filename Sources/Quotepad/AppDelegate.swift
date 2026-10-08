import Cocoa
import Carbon.HIToolbox

// MARK: - Persistence model

struct NoteTab: Codable {
    var id: String
    var text: String
}

struct TabsState: Codable {
    var tabs: [NoteTab]
    var selectedIndex: Int
}

/// `QUOTEPAD_DATA_DIR` points a dev build at a separate folder, so it can run next to
/// the installed app (the single-instance lock lives in this folder too) without touching real notes.
let appSupportDir: URL = {
    let fm = FileManager.default
    let dir = ProcessInfo.processInfo.environment["QUOTEPAD_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quotepad", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()
let tabsFileURL = appSupportDir.appendingPathComponent("tabs.json")
let legacyNoteFileURL = appSupportDir.appendingPathComponent("note.txt")

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Held for the process lifetime (released by the OS even on kill -9) so two copies,
/// e.g. the login-item app and a dev build, never write the same tabs.json.
func acquireSingleInstanceLock() -> Bool {
    let fd = open(appSupportDir.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o644)
    guard fd >= 0 else { return true }
    return flock(fd, LOCK_EX | LOCK_NB) == 0
}

/// Colored layer over the blurred material; the color is dynamic so it follows light/dark.
final class TintView: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = AppDelegate.cornerRadius
        layer?.backgroundColor = color?.withAlphaComponent(0.82).cgColor ?? NSColor.clear.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate,
    NSMenuItemValidation, NSPopoverDelegate, CodeBlockHost {
    static let cornerRadius: CGFloat = 14

    var panel: OverlayPanel!
    var backgroundView: NSVisualEffectView!
    var tintView: TintView!
    var gearButton: IconButton!
    lazy var settingsPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = SettingsViewController()
        popover.delegate = self
        return popover
    }()
    var tabBar: TabBarView!
    var separator: SeparatorView!
    var scrollView: NSScrollView!
    var textView: NoteTextView!
    let markdownLayoutDelegate = MarkdownLayoutDelegate()
    var hotKeyRef: EventHotKeyRef?
    var statusItem: NSStatusItem!
    var localMonitor: Any?
    var signalSources: [DispatchSourceSignal] = []

    let store = DurableStore(url: tabsFileURL)
    // Save 1s after typing stops, but never let unsaved edits get older than 5s during
    // non-stop typing. Worst-case loss on power failure: ~5s, usually ~1s.
    static let idleSaveDelay: TimeInterval = 1
    static let maxSaveDelay: TimeInterval = 5
    var pendingSave: DispatchWorkItem?
    var firstUnsavedEdit: Date?

    var tabs: [NoteTab] = []
    var selectedIndex = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon, menu-bar only
        loadState()
        setupStatusItem()
        setupPanel()
        applySettings()
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()
        }
        registerGlobalHotKey()
        installTerminationHooks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        flushNow()
    }

    // MARK: - State load/save

    func loadState() {
        if let data = store.loadData() {
            if let state = try? JSONDecoder().decode(TabsState.self, from: data), !state.tabs.isEmpty {
                tabs = state.tabs
                selectedIndex = min(max(state.selectedIndex, 0), tabs.count - 1)
                return
            }
            store.quarantineCorruptFile()
        }
        if let legacyText = try? String(contentsOf: legacyNoteFileURL, encoding: .utf8), !legacyText.isEmpty {
            tabs = [NoteTab(id: UUID().uuidString, text: legacyText)]
        } else {
            tabs = [NoteTab(id: UUID().uuidString, text: "")]
        }
    }

    func persistState() {
        pendingSave?.cancel()
        pendingSave = nil
        firstUnsavedEdit = nil
        let state = TabsState(tabs: tabs, selectedIndex: selectedIndex)
        if let data = try? JSONEncoder().encode(state) {
            store.save(data)
        }
    }

    /// Debounced with a max wait: see `idleSaveDelay` / `maxSaveDelay`.
    func scheduleSave() {
        let now = Date()
        let firstEdit = firstUnsavedEdit ?? now
        firstUnsavedEdit = firstEdit
        let remainingMaxWait = Self.maxSaveDelay - now.timeIntervalSince(firstEdit)
        let delay = max(0, min(Self.idleSaveDelay, remainingMaxWait))

        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistState() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Synchronously writes the latest text to disk.
    func flushNow() {
        commitCurrentText()
        persistState()
        store.flush()
    }

    func installTerminationHooks() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willPowerOffNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.flushNow()
            }
        }

        // kill / Ctrl-C / closing the launching terminal
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.flushNow()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func commitCurrentText() {
        guard tabs.indices.contains(selectedIndex), let storage = textView?.textStorage else { return }
        tabs[selectedIndex].text = NoteCodec.encode(storage)
    }

    // MARK: - Menu bar item

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Quotepad")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "메모 열기/닫기 (⌘')", action: #selector(toggleOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "새 탭 (⌘T)", action: #selector(addTabAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "설정… (⌘,)", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleLaunchAtLogin) else { return true }
        menuItem.state = LoginItem.isEnabled ? .on : .off
        return LoginItem.isAvailable
    }

    @objc func toggleLaunchAtLogin() {
        if let message = LoginItem.setEnabled(!LoginItem.isEnabled) {
            showAlert("로그인 항목 설정에 실패했어요", message)
        }
    }

    // MARK: - Settings

    func applySettings() {
        let settings = Settings.shared
        panel.appearance = settings.theme.appearance
        tintView.color = settings.tint.color
        // Fade only the background layers so text stays fully opaque.
        backgroundView.alphaValue = settings.opacity
        tintView.alphaValue = settings.opacity
        applyEditorFont()
        textView.isContinuousSpellCheckingEnabled = settings.spellCheck
        textView.isAutomaticSpellingCorrectionEnabled = settings.spellCheck
    }

    var editorAttributes: [NSAttributedString.Key: Any] {
        let settings = Settings.shared
        return [
            .font: settings.editorFont.font(size: settings.fontSize),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    func applyEditorFont() {
        let attributes = editorAttributes
        textView.font = attributes[.font] as? NSFont
        textView.typingAttributes = attributes
        restyleMarkdown()
    }

    /// Re-applies the Markdown look. Skipped mid-composition so the IME's marked text stays intact;
    /// committing the composition is an edit of its own and restyles.
    func restyleMarkdown() {
        guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        Markdown.style(storage, base: editorAttributes)
        updateTypingAttributes()
    }

    /// A plain-text view never takes typing attributes from the text, so new text (and IME
    /// composition) would keep whatever look was set last; match the caret's line instead.
    func updateTypingAttributes() {
        guard !textView.hasMarkedText() else { return }
        textView.typingAttributes = Markdown.typingAttributes(
            at: textView.selectedRange().location, in: textView.string as NSString, base: editorAttributes)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateTypingAttributes()
    }

    /// Keeps the caret out of hidden marks, so it never sits somewhere that looks the same but types differently.
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldRange: NSRange,
                  toCharacterRange newRange: NSRange) -> NSRange {
        guard textView === self.textView, newRange.length == 0, let storage = textView.textStorage,
              let run = Markdown.hiddenRun(trapping: newRange.location, in: storage) else { return newRange }
        let start = run.range.location, end = NSMaxRange(run.range)
        switch run.kind {
        case .block:
            // ← from the start of a heading's text goes on to the previous line.
            let leftFromText = oldRange.length == 0 && oldRange.location == end && newRange.location < end
            return NSRange(location: leftFromText && start > 0 ? start - 1 : end, length: 0)
        case .inline:
            return NSRange(location: newRange.location > oldRange.location ? end : start, length: 0)
        }
    }

    /// Backspace right after a hidden mark: a heading/quote mark goes as a whole (the line turns
    /// plain); for inline marks the visible character before them is deleted instead.
    func deleteBackwardOverHiddenMarkdown() -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0, !textView.hasMarkedText(), let storage = textView.textStorage,
              var run = Markdown.hiddenRun(endingAt: selection.location, in: storage) else { return false }
        // Walk back over adjacent marks, e.g. the "**" of "# **bold**" sits right after the heading's "# ".
        while run.kind == .inline, let previous = Markdown.hiddenRun(endingAt: run.range.location, in: storage) {
            run = previous
        }
        switch run.kind {
        case .block:
            textView.insertText("", replacementRange: run.range)
            return true
        case .inline:
            textView.setSelectedRange(NSRange(location: run.range.location, length: 0))
            return false // the text view now deletes the character before the mark
        }
    }

    @objc func toggleSettings() {
        if settingsPopover.isShown {
            settingsPopover.performClose(nil)
        } else {
            settingsPopover.appearance = panel.appearance
            settingsPopover.show(relativeTo: gearButton.bounds, of: gearButton, preferredEdge: .minY)
        }
    }

    @objc func openSettings() {
        if !panel.isVisible { showOverlay() }
        if !settingsPopover.isShown { toggleSettings() }
    }

    func popoverDidClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            let clickedAway = NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
            if clickedAway && Settings.shared.hideOnFocusLoss {
                self.hideOverlay()
            } else {
                self.panel.makeKey()
                self.panel.makeFirstResponder(self.textView)
            }
        }
    }

    // MARK: - Overlay panel

    func setupPanel() {
        let width: CGFloat = 520
        let height: CGFloat = 360

        panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // Transparent window + masked material so nothing shows outside the rounded corners
        // and the shadow follows the rounded shape.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.minSize = NSSize(width: 340, height: 220)

        // Layers: container → blurred material → color tint → content.
        // Content isn't a child of the background, so background opacity never fades the text.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        panel.contentView = container

        backgroundView = NSVisualEffectView(frame: container.bounds)
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.material = .popover
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        container.addSubview(backgroundView)

        tintView = TintView(frame: container.bounds)
        tintView.autoresizingMask = [.width, .height]
        container.addSubview(tintView)

        tabBar = TabBarView(frame: .zero)
        tabBar.onSelect = { [weak self] in self?.selectTab($0) }
        tabBar.onClose = { [weak self] in self?.closeTab($0) }
        tabBar.onAdd = { [weak self] in self?.addTabAction() }
        container.addSubview(tabBar)

        gearButton = IconButton(symbolName: "gearshape", pointSize: 12, weight: .medium, cornerRadius: 6, label: "설정")
        gearButton.toolTip = "설정 (⌘,)"
        gearButton.onClick = { [weak self] in self?.toggleSettings() }
        container.addSubview(gearButton)

        separator = SeparatorView(frame: .zero)
        container.addSubview(separator)

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        container.addSubview(scrollView)

        // TextKit 2 is required for view-based attachments (code boxes).
        // Never touch `textView.layoutManager`: that silently downgrades it to TextKit 1.
        textView = NoteTextView(usingTextLayoutManager: true)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.codeBlockHost = self
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 5, height: 10)
        textView.textLayoutManager?.delegate = markdownLayoutDelegate
        scrollView.documentView = textView

        layoutContent()
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        applyEditorFont()
        loadSelectedTabIntoEditor()
        refreshTabBar()
        installLocalShortcuts()
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func layoutContent() {
        guard let bounds = panel.contentView?.bounds else { return }
        let side: CGFloat = 10
        let top: CGFloat = 10
        let bottom: CGFloat = 8
        let barHeight: CGFloat = 30
        let gearSize: CGFloat = 24
        let barY = bounds.height - top - barHeight

        gearButton.frame = NSRect(x: bounds.width - side - gearSize, y: barY + (barHeight - gearSize) / 2, width: gearSize, height: gearSize)
        tabBar.frame = NSRect(x: side, y: barY, width: gearButton.frame.minX - 8 - side, height: barHeight)
        separator.frame = NSRect(x: 0, y: tabBar.frame.minY - 8, width: bounds.width, height: 1)
        let editorTop = separator.frame.minY - 2
        scrollView.frame = NSRect(x: side, y: bottom, width: bounds.width - side * 2, height: max(40, editorTop - bottom))
    }

    func windowDidResize(_ notification: Notification) {
        layoutContent()
        rememberFrame()
    }

    func windowDidMove(_ notification: Notification) {
        rememberFrame()
    }

    func rememberFrame() {
        guard panel.isVisible else { return } // ignore our own repositioning before showing
        Settings.shared.lastFrame = panel.frame
    }

    /// Size always comes back; position only when "마지막 위치" is chosen and still on a screen.
    func positionPanelForShow() {
        let settings = Settings.shared
        if let saved = settings.lastFrame {
            if settings.openPosition == .lastPosition,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
                panel.setFrame(saved, display: false)
                return
            }
            panel.setContentSize(saved.size)
        }
        centerPanelOnActiveScreen()
    }

    func activeScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    func centerPanelOnActiveScreen() {
        let screenFrame = activeScreen().visibleFrame
        let panelFrame = panel.frame
        let x = screenFrame.midX - panelFrame.width / 2
        let y = screenFrame.maxY - panelFrame.height - 100
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc func toggleOverlay() {
        if panel.isVisible {
            hideOverlay()
        } else {
            showOverlay()
        }
    }

    func showOverlay() {
        positionPanelForShow()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    func hideOverlay() {
        guard panel.isVisible else { return }
        if settingsPopover.isShown { settingsPopover.close() }
        commitCurrentText()
        persistState()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard Settings.shared.hideOnFocusLoss else { return }
        // Deferred: the settings popover taking key status must not count as "clicked away".
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.settingsPopover.isShown, NSApp.keyWindow == nil else { return }
            self.hideOverlay()
        }
    }

    func textDidChange(_ notification: Notification) {
        restyleMarkdown()
        commitCurrentText()
        refreshTabBar()
        scheduleSave()
    }

    // MARK: - Code boxes

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.deleteBackward(_:)) { return deleteBackwardOverHiddenMarkdown() }
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if let (lineRange, kind) = codeTriggerLine() {
            insertCodeBlock(kind, replacing: lineRange)
            return true
        }
        return continueMarkdownList()
    }

    /// Return on a list/quote line starts the next item; on an empty item it ends the list.
    func continueMarkdownList() -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0, !textView.hasMarkedText(),
              let continuation = Markdown.continuation(in: textView.string as NSString, caret: selection.location) else { return false }
        switch continuation {
        case .next(let marker):
            textView.insertText("\n" + marker, replacementRange: selection)
        case .end(let marker):
            textView.insertText("", replacementRange: marker)
        }
        return true
    }

    /// The caret's line content, if the whole line is a box trigger like "/code" or "/p".
    func codeTriggerLine() -> (NSRange, CodeBlockKind)? {
        let selection = textView.selectedRange()
        guard selection.length == 0, !textView.hasMarkedText() else { return nil }
        let text = textView.string as NSString
        var start = 0, contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
        let range = NSRange(location: start, length: contentsEnd - start)
        let line = text.substring(with: range).trimmingCharacters(in: .whitespaces).lowercased()
        return NoteCodec.trigger(line).map { (range, $0) }
    }

    func insertCodeBlock(_ kind: CodeBlockKind, replacing range: NSRange) {
        guard let storage = textView.textStorage else { return }
        let attachment = CodeBlockAttachment(content: "", kind: kind)
        attachment.host = self
        attachment.focusWhenLoaded = true

        let replacement = NSMutableAttributedString(attributedString: NoteCodec.attachmentString(attachment, attributes: editorAttributes))
        let lineEnd = range.location + range.length
        if lineEnd >= storage.length || (storage.string as NSString).character(at: lineEnd) != 0x0A {
            replacement.append(NSAttributedString(string: "\n", attributes: editorAttributes))
        }
        guard textView.shouldChangeText(in: range, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
    }

    func range(of attachment: CodeBlockAttachment) -> NSRange? {
        guard let storage = textView.textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? CodeBlockAttachment) === attachment {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    func codeBlockDidChange(_ attachment: CodeBlockAttachment) {
        commitCurrentText()
        refreshTabBar()
        scheduleSave()
    }

    func codeBlockDidResize(_ attachment: CodeBlockAttachment) {
        guard let range = range(of: attachment),
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return }
        layoutManager.invalidateLayout(for: textRange)
        layoutManager.textViewportLayoutController.layoutViewport()
    }

    func codeBlockRequestsExit(_ attachment: CodeBlockAttachment, after: Bool) {
        guard let range = range(of: attachment), let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        var caret: Int
        if after {
            caret = range.location + range.length
            if caret < text.length, text.character(at: caret) == 0x0A {
                caret += 1 // start of the next line
            } else if textView.shouldChangeText(in: NSRange(location: caret, length: 0), replacementString: "\n") {
                storage.replaceCharacters(in: NSRange(location: caret, length: 0), with: NSAttributedString(string: "\n", attributes: editorAttributes))
                textView.didChangeText()
                caret += 1
            }
        } else {
            caret = max(0, range.location - 1) // end of the previous line
        }
        panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
    }

    func codeBlockRequestsRemoval(_ attachment: CodeBlockAttachment) {
        guard let range = range(of: attachment),
              textView.shouldChangeText(in: range, replacementString: "") else { return }
        textView.textStorage?.replaceCharacters(in: range, with: "")
        textView.didChangeText()
        panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }

    // MARK: - Keyboard shortcuts (only while the overlay is key)

    func installLocalShortcuts() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleShortcut(event) ? nil : event
        }
    }

    // Key-code based (not character based) so shortcuts work while a Hangul input source is active.
    func handleShortcut(_ event: NSEvent) -> Bool {
        let key = Int(event.keyCode)
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        let focusedText = panel.firstResponder as? NSTextView

        if key == kVK_Escape && flags.isEmpty {
            if focusedText?.hasMarkedText() == true { return false } // let the IME cancel composition first
            hideOverlay()
            return true
        }

        switch flags {
        case .command:
            if key == kVK_ANSI_T { addTabAction(); return true }
            if key == kVK_ANSI_W { closeCurrentTab(); return true }
            if key == kVK_ANSI_Comma { toggleSettings(); return true }
            // A menu-bar-only app has no Edit menu, which is what normally delivers these.
            if let focusedText, handleEditCommand(key: key, in: focusedText) { return true }
        case [.command, .shift]:
            if key == kVK_ANSI_Z, let undoManager = focusedText?.undoManager, undoManager.canRedo {
                undoManager.redo()
                return true
            }
            if key == kVK_ANSI_RightBracket { selectRelativeTab(1); return true }
            if key == kVK_ANSI_LeftBracket { selectRelativeTab(-1); return true }
        case .control:
            if key == kVK_Tab { selectRelativeTab(1); return true }
        case [.control, .shift]:
            if key == kVK_Tab { selectRelativeTab(-1); return true }
        default:
            break
        }
        return false
    }

    func handleEditCommand(key: Int, in text: NSTextView) -> Bool {
        switch key {
        case kVK_ANSI_C: text.copy(nil)
        case kVK_ANSI_X: text.cut(nil)
        case kVK_ANSI_V: text.paste(nil)
        case kVK_ANSI_A: text.selectAll(nil)
        case kVK_ANSI_Z:
            guard let undoManager = text.undoManager, undoManager.canUndo else { return true }
            undoManager.undo()
        default: return false
        }
        return true
    }

    // MARK: - Tabs

    /// First meaningful line; code-box fences are skipped so a box's content can be the title.
    func tabTitle(for tab: NoteTab) -> String {
        for line in tab.text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed != NoteCodec.fence && trimmed != NoteCodec.codeFence else { continue }
            let title = Markdown.strippingHeading(trimmed)
            if !title.isEmpty {
                return String(title.prefix(80))
            }
        }
        return "새 메모"
    }

    func refreshTabBar() {
        tabBar.update(titles: tabs.map(tabTitle(for:)), selectedIndex: selectedIndex)
    }

    func loadSelectedTabIntoEditor() {
        if textView.hasMarkedText() {
            textView.unmarkText()
            textView.inputContext?.discardMarkedText()
        }
        textView.textStorage?.setAttributedString(NoteCodec.decode(tabs[selectedIndex].text, attributes: editorAttributes, host: self))
        restyleMarkdown()
        textView.undoManager?.removeAllActions() // undo must not cross tabs
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        if index != selectedIndex {
            commitCurrentText()
            selectedIndex = index
            loadSelectedTabIntoEditor()
            persistState()
            refreshTabBar()
        }
        panel.makeFirstResponder(textView)
    }

    func selectRelativeTab(_ delta: Int) {
        guard tabs.count > 1 else { return }
        selectTab((selectedIndex + delta + tabs.count) % tabs.count)
    }

    @objc func addTabAction() {
        if !panel.isVisible { showOverlay() }
        commitCurrentText()
        tabs.append(NoteTab(id: UUID().uuidString, text: ""))
        selectedIndex = tabs.count - 1
        loadSelectedTabIntoEditor()
        persistState()
        refreshTabBar()
        panel.makeFirstResponder(textView)
    }

    func closeTab(_ index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        commitCurrentText()
        let currentID = tabs[selectedIndex].id
        tabs.remove(at: index)
        if let kept = tabs.firstIndex(where: { $0.id == currentID }) {
            selectedIndex = kept // closed a background tab: editor stays untouched
        } else {
            selectedIndex = min(index, tabs.count - 1) // like browsers: the tab to the right takes over
            loadSelectedTabIntoEditor()
        }
        persistState()
        refreshTabBar()
    }

    @objc func closeCurrentTab() {
        if tabs.count == 1 {
            hideOverlay()
        } else {
            closeTab(selectedIndex)
        }
    }

    // MARK: - Global hotkey (Cmd+')

    func registerGlobalHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            appDelegate.toggleOverlay()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x51504144), id: 1) // 'QPAD'
        RegisterEventHotKey(UInt32(kVK_ANSI_Quote), UInt32(cmdKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc func quit() {
        NSApp.terminate(nil) // applicationWillTerminate flushes
    }
}
