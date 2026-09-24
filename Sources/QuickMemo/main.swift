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

let appSupportDir: URL = {
    let fm = FileManager.default
    let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QuickMemo", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()
let tabsFileURL = appSupportDir.appendingPathComponent("tabs.json")
let legacyNoteFileURL = appSupportDir.appendingPathComponent("note.txt")

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class TabButton: NSButton {
    var tabIndex: Int = 0
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    var panel: OverlayPanel!
    var tabBarScroll: NSScrollView!
    var tabStack: NSStackView!
    var scrollView: NSScrollView!
    var textView: NSTextView!
    var hotKeyRef: EventHotKeyRef?
    var statusItem: NSStatusItem!
    var localMonitor: Any?
    var saveDebounce: Timer?

    var tabs: [NoteTab] = []
    var selectedIndex: Int = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon, menu-bar only
        loadState()
        setupStatusItem()
        setupPanel()
        registerGlobalHotKey()
    }

    // MARK: - State load/save

    func loadState() {
        if let data = try? Data(contentsOf: tabsFileURL),
           let state = try? JSONDecoder().decode(TabsState.self, from: data),
           !state.tabs.isEmpty {
            tabs = state.tabs
            selectedIndex = min(max(state.selectedIndex, 0), tabs.count - 1)
        } else if let legacyText = try? String(contentsOf: legacyNoteFileURL, encoding: .utf8), !legacyText.isEmpty {
            tabs = [NoteTab(id: UUID().uuidString, text: legacyText)]
            selectedIndex = 0
        } else {
            tabs = [NoteTab(id: UUID().uuidString, text: "")]
            selectedIndex = 0
        }
    }

    func persistState() {
        let state = TabsState(tabs: tabs, selectedIndex: selectedIndex)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: tabsFileURL, options: .atomic)
        }
    }

    func commitCurrentText() {
        guard tabs.indices.contains(selectedIndex), textView != nil else { return }
        tabs[selectedIndex].text = textView.string
    }

    // MARK: - Menu bar item

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "QuickMemo")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "메모 토글 (⌘')", action: #selector(toggleOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "새 탭 (⌘T)", action: #selector(addTabAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "탭 닫기 (⌘W)", action: #selector(closeCurrentTab), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Overlay panel

    func setupPanel() {
        let width: CGFloat = 480
        let height: CGFloat = 340

        panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.delegate = self
        panel.backgroundColor = .clear
        panel.minSize = NSSize(width: 320, height: 220)

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
        visualEffect.layer?.masksToBounds = true
        panel.contentView = visualEffect

        // Tab bar (horizontally scrollable strip of tab buttons)
        tabBarScroll = NSScrollView()
        tabBarScroll.hasHorizontalScroller = false
        tabBarScroll.hasVerticalScroller = false
        tabBarScroll.drawsBackground = false
        tabBarScroll.horizontalScrollElasticity = .allowed
        tabBarScroll.verticalScrollElasticity = .none

        tabStack = NSStackView()
        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.spacing = 4
        tabBarScroll.documentView = tabStack
        visualEffect.addSubview(tabBarScroll)

        // Text editor
        scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        visualEffect.addSubview(scrollView)

        textView = scrollView.documentView as? NSTextView
        textView.delegate = self
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = tabs[selectedIndex].text

        layoutContent()
        rebuildTabBar()

        // Local shortcuts that only apply while the overlay is key.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { // Escape
                self.hideOverlay()
                return nil
            }
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "t":
                    self.addTabAction()
                    return nil
                case "w":
                    self.closeCurrentTab()
                    return nil
                default:
                    break
                }
            }
            return event
        }
    }

    func layoutContent() {
        guard let contentView = panel.contentView else { return }
        let bounds = contentView.bounds
        let outerInset: CGFloat = 12
        let tabBarHeight: CGFloat = 28
        let gap: CGFloat = 6

        tabBarScroll.frame = NSRect(
            x: outerInset,
            y: bounds.height - outerInset - tabBarHeight,
            width: bounds.width - outerInset * 2,
            height: tabBarHeight
        )
        let scrollHeight = bounds.height - outerInset * 2 - tabBarHeight - gap
        scrollView.frame = NSRect(
            x: outerInset,
            y: outerInset,
            width: bounds.width - outerInset * 2,
            height: max(40, scrollHeight)
        )
        resizeTabStackToFit()
    }

    func resizeTabStackToFit() {
        tabStack.layoutSubtreeIfNeeded()
        let width = max(tabStack.fittingSize.width, tabBarScroll.bounds.width)
        tabStack.frame = NSRect(x: 0, y: 0, width: width, height: tabBarScroll.bounds.height)
    }

    func windowDidResize(_ notification: Notification) {
        layoutContent()
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
        centerPanelOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    func hideOverlay() {
        guard panel.isVisible else { return }
        saveDebounce?.invalidate()
        commitCurrentText()
        persistState()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hideOverlay()
    }

    func textDidChange(_ notification: Notification) {
        commitCurrentText()
        saveDebounce?.invalidate()
        saveDebounce = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.persistState()
            self.rebuildTabBar()
        }
    }

    // MARK: - Tabs

    func tabTitle(for tab: NoteTab, index: Int) -> String {
        let firstLine = tab.text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if firstLine.isEmpty {
            return "메모 \(index + 1)"
        }
        if firstLine.count > 14 {
            return String(firstLine.prefix(14)) + "…"
        }
        return firstLine
    }

    func makeTabWrapper(index: Int, tab: NoteTab) -> NSStackView {
        let selectButton = TabButton(title: tabTitle(for: tab, index: index), target: self, action: #selector(tabButtonClicked(_:)))
        selectButton.tabIndex = index
        selectButton.isBordered = false
        selectButton.bezelStyle = .inline
        selectButton.setButtonType(.momentaryChange)
        selectButton.font = .systemFont(ofSize: 12, weight: index == selectedIndex ? .semibold : .regular)
        selectButton.contentTintColor = index == selectedIndex ? .labelColor : .secondaryLabelColor

        let closeButton = TabButton(title: "×", target: self, action: #selector(tabCloseClicked(_:)))
        closeButton.tabIndex = index
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.font = .systemFont(ofSize: 12)
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.isHidden = tabs.count <= 1

        let wrapper = NSStackView(views: [selectButton, closeButton])
        wrapper.orientation = .horizontal
        wrapper.spacing = 2
        wrapper.alignment = .centerY
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = 6
        wrapper.layer?.backgroundColor = index == selectedIndex
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        wrapper.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 6)
        return wrapper
    }

    func rebuildTabBar() {
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (idx, tab) in tabs.enumerated() {
            tabStack.addArrangedSubview(makeTabWrapper(index: idx, tab: tab))
        }

        let addButton = TabButton(title: "+", target: self, action: #selector(addTabAction))
        addButton.isBordered = false
        addButton.bezelStyle = .inline
        addButton.font = .systemFont(ofSize: 14, weight: .medium)
        addButton.contentTintColor = .secondaryLabelColor
        tabStack.addArrangedSubview(addButton)

        resizeTabStackToFit()
    }

    func scrollTabBarToSelected() {
        guard let documentView = tabBarScroll.documentView else { return }
        let point = NSPoint(x: max(0, documentView.bounds.width - tabBarScroll.bounds.width), y: 0)
        tabBarScroll.contentView.scroll(to: point)
        tabBarScroll.reflectScrolledClipView(tabBarScroll.contentView)
    }

    @objc func tabButtonClicked(_ sender: TabButton) {
        selectTab(sender.tabIndex)
    }

    @objc func tabCloseClicked(_ sender: TabButton) {
        closeTab(sender.tabIndex)
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        if index != selectedIndex {
            commitCurrentText()
            selectedIndex = index
            textView.string = tabs[index].text
            persistState()
            rebuildTabBar()
        }
        panel.makeFirstResponder(textView)
    }

    @objc func addTabAction() {
        commitCurrentText()
        tabs.append(NoteTab(id: UUID().uuidString, text: ""))
        selectedIndex = tabs.count - 1
        textView.string = ""
        persistState()
        rebuildTabBar()
        panel.makeFirstResponder(textView)
        scrollTabBarToSelected()
    }

    func closeTab(_ index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if index < selectedIndex {
            selectedIndex -= 1
        } else if index == selectedIndex {
            selectedIndex = min(selectedIndex, tabs.count - 1)
        }
        textView.string = tabs[selectedIndex].text
        persistState()
        rebuildTabBar()
    }

    @objc func closeCurrentTab() {
        closeTab(selectedIndex)
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

        let hotKeyID = EventHotKeyID(signature: OSType(0x514D454D), id: 1) // 'QMEM'
        let keyCode = UInt32(kVK_ANSI_Quote)
        let modifiers = UInt32(cmdKey)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc func quit() {
        saveDebounce?.invalidate()
        commitCurrentText()
        persistState()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
