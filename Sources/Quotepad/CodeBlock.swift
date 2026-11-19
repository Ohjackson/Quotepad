import Cocoa
import UniformTypeIdentifiers

// Boxes with a copy button, embedded in the note as TextKit 2 view attachments. On disk they're
// Markdown fences, so notes stay plain text. Three kinds:
//
//  - Snippet (`/p`): one line for emails, keys, commands.
//  - Command (`/c`): one shell command, with a button that runs it in a new Terminal window.
//  - Code (`/code`): multi-line code with syntax coloring for the language picked in its header.
//
// Typing a trigger and then Space (or Return) turns the line into the box.
//
//     ```                         ```sh                      ~~~python
//     someone@example.com         npm run dev                def hello():
//     ```                         ```                            print("hi")
//                                                            ~~~
//
// Both scroll horizontally instead of wrapping.

protocol CodeBlockHost: AnyObject {
    func codeBlockDidChange(_ attachment: CodeBlockAttachment)
    /// The box's line count changed, so its height did too.
    func codeBlockDidResize(_ attachment: CodeBlockAttachment)
    /// Move the caret out of the box, to the line after it (`after`) or before it.
    func codeBlockRequestsExit(_ attachment: CodeBlockAttachment, after: Bool)
    func codeBlockRequestsRemoval(_ attachment: CodeBlockAttachment)
}

enum CodeBlockKind {
    /// One line, created with `/p`, stored between ``` fences.
    case snippet
    /// One shell command, created with `/c`, stored between ```sh and ``` fences.
    case command
    /// Multi-line, created with `/code`, stored between ~~~ fences.
    case code
}

final class CodeBlockAttachment: NSTextAttachment {
    let kind: CodeBlockKind
    var content: String
    /// `CodeLanguage.id` of a code block; nil for plain text.
    var language: String?
    weak var host: CodeBlockHost?
    /// Set when the box is created by the user; the view grabs focus as soon as it's on screen.
    var focusWhenLoaded = false
    weak var liveView: CodeBlockView?

    var lineCount: Int { kind == .code ? content.components(separatedBy: "\n").count : 1 }

    init(content: String, kind: CodeBlockKind, language: String? = nil) {
        self.kind = kind
        self.content = content
        self.language = language
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        // Without an image, TextKit also draws a generic document icon under the view,
        // which shows through the box's translucent background.
        image = NSImage(size: NSSize(width: 1, height: 1))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = CodeBlockViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

final class CodeBlockViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let attachment = textAttachment as? CodeBlockAttachment else { return }
        let view = CodeBlockView(attachment: attachment)
        attachment.liveView = view
        self.view = view
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        let padding = textContainer?.lineFragmentPadding ?? 5
        let width = max(120, proposedLineFragment.width - padding * 2)
        guard let attachment = textAttachment as? CodeBlockAttachment else { return .zero }
        return CGRect(x: 0, y: -CodeBlockView.baselineOffset, width: width, height: CodeBlockView.height(for: attachment))
    }
}

private final class BoxBackgroundView: NSView {
    /// A command box: dark like a terminal, with a green edge.
    var isTerminal = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        if isTerminal {
            layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.45).cgColor
            layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.12, alpha: 0.92).cgColor
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Horizontal-only scroller that hands vertical swipes to the note's scroll view.
private final class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
    override var mouseDownCanMoveWindow: Bool { false }
}

final class CodeBlockView: NSView, NSTextViewDelegate {
    static let baselineOffset: CGFloat = 12
    private static let verticalMargin: CGFloat = 3
    private static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
    /// Space above and below the text inside the box (a one-line box is 40pt tall).
    private static let innerPadding: CGFloat = (40 - verticalMargin * 2 - lineHeight) / 2
    private static let indent = "    "
    /// Code blocks have a row above the code for the language menu and the copy button.
    private static let headerHeight: CGFloat = 26

    static func height(for attachment: CodeBlockAttachment) -> CGFloat {
        let text = CGFloat(attachment.lineCount) * lineHeight
        switch attachment.kind {
        case .snippet, .command: return text + (innerPadding + verticalMargin) * 2
        case .code: return text + headerHeight + innerPadding + verticalMargin * 2
        }
    }

    let attachment: CodeBlockAttachment
    private let box = BoxBackgroundView()
    private let scrollView = HorizontalScrollView()
    private let editor = NSTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let copyButton = IconButton(symbolName: "doc.on.doc", pointSize: 11, weight: .medium, cornerRadius: 5, label: "복사")
    private let runButton = IconButton(symbolName: "play.fill", pointSize: 10, weight: .medium, cornerRadius: 5, label: "터미널에서 실행")
    /// The dimmed "$" in front of a command.
    private let prompt = NSTextField(labelWithString: "$")
    private let languageMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The guessed language while the block has none picked (`attachment.language == nil`).
    private var detectedLanguage: CodeLanguage?
    private var detectWork: DispatchWorkItem?
    private var copyResetWork: DispatchWorkItem?
    private var runResetWork: DispatchWorkItem?
    private var isCode: Bool { attachment.kind == .code }
    private var isCommand: Bool { attachment.kind == .command }

    init(attachment: CodeBlockAttachment) {
        self.attachment = attachment
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Self.height(for: attachment)))
        if isCommand {
            appearance = NSAppearance(named: .darkAqua) // light text and buttons on the terminal-dark box
            box.isTerminal = true
        }
        addSubview(box)

        editor.isRichText = false
        editor.font = Self.font
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.allowsUndo = true
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = isCode
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        let maxHeight = isCode ? CGFloat.greatestFiniteMagnitude : Self.lineHeight
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: maxHeight)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: maxHeight)
        // Emails, keys and commands must be copied back exactly as typed.
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.string = attachment.content
        editor.delegate = self

        scrollView.documentView = editor
        scrollView.drawsBackground = false
        // No visible scroller: a one-line box has no room for one. Trackpad/wheel scrolling and
        // caret-follow scrolling still work without it.
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        addSubview(scrollView)

        placeholder.stringValue = isCode ? "코드" : isCommand ? "실행할 명령어 (▶ 또는 ⌘↩로 실행)" : "이메일, 명령어 등 복사할 내용"
        placeholder.font = Self.font
        placeholder.textColor = .placeholderTextColor
        placeholder.isHidden = !attachment.content.isEmpty
        addSubview(placeholder, positioned: .below, relativeTo: scrollView)

        copyButton.toolTip = "복사"
        copyButton.onClick = { [weak self] in self?.copyContent() }
        addSubview(copyButton)

        if isCommand {
            prompt.font = Self.font
            prompt.textColor = NSColor.systemGreen.withAlphaComponent(0.8)
            addSubview(prompt)
            runButton.toolTip = "터미널에서 실행 (⌘↩)"
            runButton.onClick = { [weak self] in self?.runCommand() }
            addSubview(runButton)
        }

        if isCode {
            languageMenu.isBordered = false
            languageMenu.controlSize = .small
            languageMenu.font = .systemFont(ofSize: 11)
            languageMenu.addItem(withTitle: "Text")
            languageMenu.lastItem?.representedObject = CodeLanguage.plainTextID
            for language in CodeLanguage.all {
                languageMenu.addItem(withTitle: language.name)
                languageMenu.lastItem?.representedObject = language.id
            }
            if attachment.language == nil { detectedLanguage = LanguageDetector.detect(attachment.content) }
            syncLanguageMenu()
            languageMenu.target = self
            languageMenu.action = #selector(languageChosen)
            addSubview(languageMenu)
            highlight()
        }

        setAccessibilityRole(.group)
        setAccessibilityLabel(isCode ? "코드 블록" : isCommand ? "실행 박스" : "복사 박스")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        box.frame = bounds.insetBy(dx: 0, dy: Self.verticalMargin)
        let buttonSize: CGFloat = 22
        var textX = box.frame.minX + 12
        let textHeight = CGFloat(attachment.lineCount) * Self.lineHeight
        let textFrame: NSRect
        if isCode {
            // Header row: language menu on the left, copy button on the right; code below at full width.
            let headerMidY = box.frame.maxY - Self.headerHeight / 2
            copyButton.frame = NSRect(x: box.frame.maxX - 6 - buttonSize, y: headerMidY - buttonSize / 2, width: buttonSize, height: buttonSize)
            // Sized to the chosen name (sizeToFit would use the longest one), plus room for the arrows.
            languageMenu.sizeToFit()
            let menuHeight = languageMenu.frame.height
            let title = (languageMenu.titleOfSelectedItem ?? "") as NSString
            let titleWidth = title.size(withAttributes: [.font: languageMenu.font ?? .systemFont(ofSize: 11)]).width
            languageMenu.frame = NSRect(x: textX - 4, y: (headerMidY - menuHeight / 2).rounded(), width: ceil(titleWidth) + 28, height: menuHeight)
            textFrame = NSRect(
                x: textX,
                y: box.frame.maxY - Self.headerHeight - textHeight,
                width: max(0, box.frame.maxX - 12 - textX),
                height: textHeight
            )
        } else {
            // The copy button sits beside the only line; a command's run button before it, and its "$" in front.
            copyButton.frame = NSRect(x: box.frame.maxX - 6 - buttonSize, y: box.frame.midY - buttonSize / 2, width: buttonSize, height: buttonSize)
            var buttonsMinX = copyButton.frame.minX
            if isCommand {
                runButton.frame = copyButton.frame.offsetBy(dx: -(buttonSize + 2), dy: 0)
                buttonsMinX = runButton.frame.minX
                let promptWidth = ceil(("$ " as NSString).size(withAttributes: [.font: Self.font]).width)
                prompt.frame = NSRect(x: textX - 2, y: box.frame.midY - Self.lineHeight / 2, width: promptWidth + 4, height: Self.lineHeight)
                textX += promptWidth
            }
            textFrame = NSRect(
                x: textX,
                y: box.frame.midY - textHeight / 2,
                width: max(0, buttonsMinX - 8 - textX),
                height: textHeight
            )
        }
        scrollView.frame = textFrame
        placeholder.frame = NSRect(x: textX, y: textFrame.maxY - Self.lineHeight, width: textFrame.width, height: Self.lineHeight)
        // Fill the visible width so clicks on the empty right side still land in the editor.
        editor.minSize = NSSize(width: textFrame.width, height: textHeight)
        editor.frame.size = NSSize(width: max(editor.frame.width, textFrame.width), height: textHeight)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard attachment.focusWhenLoaded, window != nil else { return }
        attachment.focusWhenLoaded = false
        DispatchQueue.main.async { [weak self] in self?.focusEditor() }
    }

    func focusEditor() {
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    override func mouseDown(with event: NSEvent) { focusEditor() }
    override var mouseDownCanMoveWindow: Bool { false }

    private func copyContent() {
        guard !attachment.content.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(attachment.content, forType: .string)
        copyButton.setSymbol("checkmark", label: "복사됨")
        copyButton.toolTip = "복사됨"
        copyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.copyButton.setSymbol("doc.on.doc", label: "복사")
            self?.copyButton.toolTip = "복사"
        }
        copyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// Runs a command box's command in a new Terminal window. False for other boxes.
    @discardableResult
    func runCommand() -> Bool {
        guard isCommand else { return false }
        let command = attachment.content.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return true }
        CommandRunner.run(command)
        runButton.setSymbol("checkmark", label: "실행함")
        runResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runButton.setSymbol("play.fill", label: "터미널에서 실행") }
        runResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        return true
    }

    // MARK: - NSTextViewDelegate

    @objc private func languageChosen() {
        // Picking anything, "Text" included, is a choice: detection stops for this block.
        attachment.language = languageMenu.selectedItem?.representedObject as? String
        detectWork?.cancel()
        detectedLanguage = nil
        syncLanguageMenu()
        highlight()
        attachment.host?.codeBlockDidChange(attachment)
        window?.makeFirstResponder(editor)
    }

    /// The picked language, else the guessed one; nil means plain text.
    private var effectiveLanguage: CodeLanguage? {
        guard let id = attachment.language else { return detectedLanguage }
        return CodeLanguage.find(id)
    }

    private func syncLanguageMenu() {
        let id = attachment.language ?? detectedLanguage?.id ?? CodeLanguage.plainTextID
        languageMenu.selectItem(at: max(0, languageMenu.indexOfItem(withRepresentedObject: id)))
        languageMenu.toolTip = attachment.language == nil && detectedLanguage != nil ? "언어 (자동 인식)" : "언어"
        resizeSubviews(withOldSize: bounds.size) // the menu's width follows the name
    }

    private func highlight() {
        guard isCode, !editor.hasMarkedText(), let storage = editor.textStorage else { return }
        SyntaxHighlighter.highlight(storage, language: effectiveLanguage, font: Self.font)
    }

    /// Re-guesses once typing pauses, so detection never runs per keystroke.
    private func scheduleDetection() {
        guard isCode, attachment.language == nil else { return }
        detectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.attachment.language == nil else { return }
            let guess = LanguageDetector.detect(self.attachment.content)
            guard guess?.id != self.detectedLanguage?.id else { return }
            self.detectedLanguage = guess
            self.syncLanguageMenu()
            self.highlight()
        }
        detectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func textDidChange(_ notification: Notification) {
        let oldLineCount = attachment.lineCount
        attachment.content = editor.string
        highlight()
        scheduleDetection()
        placeholder.isHidden = !editor.string.isEmpty
        if attachment.lineCount != oldLineCount {
            attachment.host?.codeBlockDidResize(attachment) // the new frame lays out the subviews
        }
        attachment.host?.codeBlockDidChange(attachment)
    }

    /// The note's scroll view follows the caret as a code block grows past the visible area.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard isCode, window != nil, let caret = caretLineRect() else { return }
        DispatchQueue.main.async { [weak self] in self?.scrollToVisible(caret.insetBy(dx: 0, dy: -Self.innerPadding)) }
    }

    private func caretLineRect() -> NSRect? {
        let text = editor.string as NSString
        let caret = min(editor.selectedRange().location, text.length)
        let line = text.substring(to: caret).components(separatedBy: "\n").count - 1
        let y = scrollView.frame.maxY - CGFloat(line + 1) * Self.lineHeight
        return NSRect(x: scrollView.frame.minX, y: y, width: 1, height: Self.lineHeight)
    }

    /// Single line: pasted line breaks become spaces. Code keeps them.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !isCode, let replacementString, replacementString.contains(where: \.isNewline) else { return true }
        let flattened = replacementString.split(whereSeparator: \.isNewline).joined(separator: " ")
        textView.insertText(flattened, replacementRange: range)
        return false
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if isCode { return handleCodeCommand(selector, in: textView) }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.moveDown(_:)):
            attachment.host?.codeBlockRequestsExit(attachment, after: true)
            return true
        case #selector(NSResponder.moveUp(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            attachment.host?.codeBlockRequestsExit(attachment, after: false)
            return true
        case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty:
            attachment.host?.codeBlockRequestsRemoval(attachment)
            return true
        default:
            return false
        }
    }

    /// Return and Tab type into the block; ↑ on the first line and ↓ on the last line leave it.
    private func handleCodeCommand(_ selector: Selector, in textView: NSTextView) -> Bool {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Keep the current line's indentation.
            let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let line = text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            textView.insertText("\n" + indent, replacementRange: selection)
            return true
        case #selector(NSResponder.insertTab(_:)):
            textView.insertText(Self.indent, replacementRange: selection)
            return true
        case #selector(NSResponder.moveDown(_:)) where !text.substring(from: NSMaxRange(selection)).contains("\n"):
            attachment.host?.codeBlockRequestsExit(attachment, after: true)
            return true
        case #selector(NSResponder.moveUp(_:)) where !text.substring(to: selection.location).contains("\n"),
             #selector(NSResponder.insertBacktab(_:)):
            attachment.host?.codeBlockRequestsExit(attachment, after: false)
            return true
        case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty:
            attachment.host?.codeBlockRequestsRemoval(attachment)
            return true
        default:
            return false
        }
    }
}

// MARK: - Plain text <-> attributed note

enum NoteCodec {
    static let fence = "```"
    static let commandFence = "```sh"
    static let codeFence = "~~~"
    // Typed with the Korean layout on, "/p" comes out as "/ㅔ" and "/code" as "/챙ㄷ".
    static let snippetTriggers: Set<String> = ["/p", "/ㅔ"]
    static let codeTriggers: Set<String> = ["/code", "/코드", "/챙ㄷ"]
    static let commandTriggers: Set<String> = ["/c", "/ㅊ"]
    /// "/ㅗ디ㅔ" = "/help" typed with the Korean layout on.
    static let helpTriggers: Set<String> = ["/help", "/도움말", "/ㅗ디ㅔ"]

    /// The box a trigger line asks for: the built-in words, or the user's own from Settings.
    static func trigger(_ line: String) -> CodeBlockKind? {
        if snippetTriggers.contains(line) || Settings.shortcutSet(Settings.shared.snippetShortcuts).contains(line) { return .snippet }
        if codeTriggers.contains(line) || Settings.shortcutSet(Settings.shared.codeShortcuts).contains(line) { return .code }
        if commandTriggers.contains(line) || Settings.shortcutSet(Settings.shared.commandShortcuts).contains(line) { return .command }
        return nil
    }

    /// "~~~" or "~~~python": the language after a code fence, "" for none.
    static func codeFenceLanguage(_ line: String) -> String? {
        guard line.hasPrefix(codeFence) else { return nil }
        let tag = line.dropFirst(codeFence.count).trimmingCharacters(in: .whitespaces)
        return tag.contains("~") ? nil : tag
    }

    static func containsFence(_ text: String) -> Bool {
        text.contains(fence) || text.contains(codeFence)
    }

    static func attachmentString(_ attachment: CodeBlockAttachment, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// Turns ``` fenced one-line blocks into snippets, ```sh ones into command boxes and ~~~ fenced
    /// blocks into code blocks.
    static func decode(_ text: String, attributes: [NSAttributedString.Key: Any], host: CodeBlockHost?) -> NSAttributedString {
        let lines = text.components(separatedBy: "\n")
        let result = NSMutableAttributedString()
        var index = 0
        while index < lines.count {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
            if lines[index] == fence || lines[index] == commandFence, index + 2 < lines.count, lines[index + 2] == fence {
                let attachment = CodeBlockAttachment(content: lines[index + 1], kind: lines[index] == fence ? .snippet : .command)
                attachment.host = host
                result.append(attachmentString(attachment, attributes: attributes))
                index += 3
            } else if let tag = codeFenceLanguage(lines[index]),
                      let close = lines[(index + 1)...].firstIndex(of: codeFence) {
                let content = lines[(index + 1)..<close].joined(separator: "\n")
                // Unknown tags (e.g. "ruby") are kept as written, just not colored.
                let language = tag.isEmpty ? nil : CodeLanguage.find(tag)?.id ?? tag
                let attachment = CodeBlockAttachment(content: content, kind: .code, language: language)
                attachment.host = host
                result.append(attachmentString(attachment, attributes: attributes))
                index = close + 1
            } else {
                result.append(decodeImages(in: lines[index], attributes: attributes, host: host))
                index += 1
            }
        }
        return result
    }

    /// A line of text with its `![](images/…)` references turned into pictures.
    private static func decodeImages(in line: String, attributes: [NSAttributedString.Key: Any], host: CodeBlockHost?) -> NSAttributedString {
        let ns = line as NSString
        let result = NSMutableAttributedString()
        var cursor = 0
        for match in ImageStore.reference.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            result.append(NSAttributedString(string: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), attributes: attributes))
            let width = match.range(at: 1).location == NSNotFound ? nil : Double(ns.substring(with: match.range(at: 1)))
            let attachment = ImageAttachment(fileName: ns.substring(with: match.range(at: 2)), width: width.map { CGFloat($0) })
            attachment.host = host as? ImageBlockHost
            let picture = NSMutableAttributedString(attachment: attachment)
            picture.addAttributes(attributes, range: NSRange(location: 0, length: picture.length))
            result.append(picture)
            cursor = NSMaxRange(match.range)
        }
        result.append(NSAttributedString(string: ns.substring(from: cursor), attributes: attributes))
        return result
    }

    static func encode(_ attributed: NSAttributedString) -> String {
        let source = attributed.string as NSString
        var output = ""
        var cursor = 0
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let picture = value as? ImageAttachment {
                output += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
                output += ImageStore.markdown(for: picture)
                cursor = range.location + range.length
                return
            }
            guard let block = value as? CodeBlockAttachment else { return }
            output += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
            switch block.kind {
            case .snippet: output += "\(fence)\n\(block.content)\n\(fence)"
            case .command: output += "\(commandFence)\n\(block.content)\n\(fence)"
            case .code: output += "\(codeFence)\(block.language ?? "")\n\(block.content)\n\(codeFence)"
            }
            cursor = range.location + range.length
        }
        output += source.substring(from: cursor)
        return output
    }
}

/// Main note editor: copy/cut write code boxes as Markdown fences, and pasting fences makes boxes.
final class NoteTextView: NSTextView {
    weak var codeBlockHost: CodeBlockHost?
    /// Called for a typed space; returns true when it completed a trigger like "/code" and was used up.
    var spaceHandler: (() -> Bool)?

    // Pinch on the trackpad: spread to make the text bigger, pinch to make it smaller. It changes the
    // font size setting in whole points, so the settings slider follows.
    private var pinchStartSize: Double = 0
    private var pinchAmount: CGFloat = 0

    override func magnify(with event: NSEvent) {
        if event.phase == .began || pinchStartSize == 0 {
            pinchStartSize = Settings.shared.fontSize
            pinchAmount = 0
        }
        pinchAmount += event.magnification
        let range = Settings.fontSizeRange
        let size = min(max((pinchStartSize * Double(1 + pinchAmount)).rounded(), range.lowerBound), range.upperBound)
        if size != Settings.shared.fontSize { Settings.shared.fontSize = size }
        if event.phase == .ended || event.phase == .cancelled { pinchStartSize = 0 }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string
        if text == " ", !hasMarkedText(), spaceHandler?() == true { return }
        // A picture keeps its line to itself: text typed right beside it goes on the next line (indented
        // like the picture, so a picture's caption in a list stays in its item).
        if !hasMarkedText(), let storage = textStorage, let text, !text.isEmpty, !text.hasPrefix("\n") {
            let caret = replacementRange.location == NSNotFound ? selectedRange().location : replacementRange.location
            if caret > 0, caret <= storage.length, storage.attribute(.attachment, at: caret - 1, effectiveRange: nil) is ImageAttachment {
                let line = (storage.string as NSString).lineRange(for: NSRange(location: caret - 1, length: 0))
                let indent = (storage.string as NSString).substring(with: line).prefix { $0 == " " || $0 == "\t" }
                super.insertText("\n" + indent, replacementRange: replacementRange)
                return super.insertText(string, replacementRange: selectedRange())
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Copies Markdown, made for pasting into an AI prompt: prompts can't take text and pictures in one
    /// paste, so pictures go in as their files' full paths (a coding assistant can open them). A lone
    /// picture goes on as the image itself.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard textStorage != nil, selectedRange().length > 0 else {
            return super.writeSelection(to: pboard, types: types)
        }
        return write(selectedRange(), to: pboard)
    }

    /// A selected picture shows as a ring with the caret parked after it, not as a text selection;
    /// ⌘C / ⌘X then take that picture.
    private var selectedPictureRange: NSRange? {
        let caret = selectedRange()
        guard caret.length == 0, caret.location > 0, let storage = textStorage, caret.location <= storage.length,
              storage.attribute(.attachment, at: caret.location - 1, effectiveRange: nil) is ImageAttachment else { return nil }
        return NSRange(location: caret.location - 1, length: 1)
    }

    override func copy(_ sender: Any?) {
        guard let picture = selectedPictureRange else { return super.copy(sender) }
        _ = write(picture, to: .general)
    }

    /// ⌘⇧C: a copy that carries the pictures themselves, as HTML, for apps like Notion (which can't
    /// open the note's `images/` paths).
    func copyWithPictures() {
        let range = selectedPictureRange ?? selectedRange()
        guard range.length > 0 else { return }
        _ = write(range, to: .general, withPictures: true)
    }

    override func cut(_ sender: Any?) {
        guard let picture = selectedPictureRange else { return super.cut(sender) }
        _ = write(picture, to: .general)
        doCommand(by: #selector(NSResponder.deleteBackward(_:))) // removes the picture with its line
    }

    private func write(_ range: NSRange, to pboard: NSPasteboard, withPictures: Bool = false) -> Bool {
        guard let storage = textStorage else { return false }
        let selection = storage.attributedSubstring(from: range)
        let markdown = NoteCodec.encode(selection)
        var pictures: [ImageAttachment] = []
        selection.enumerateAttribute(.attachment, in: NSRange(location: 0, length: selection.length)) { value, _, _ in
            if let picture = value as? ImageAttachment { pictures.append(picture) }
        }
        pboard.clearContents()
        guard !pictures.isEmpty else { return pboard.setString(markdown, forType: .string) }

        // Quotepad itself reads the Markdown from its own type, so pictures paste back as the same
        // files at the same widths.
        let onlyPicture = pictures.count == 1
            && selection.string.allSatisfy { $0 == "\u{FFFC}" || $0.isNewline || $0.isWhitespace }
        // A lone picture goes on as an image only, like a screenshot: with text beside it, chat prompts
        // paste the text (or nothing) instead of attaching the picture.
        if onlyPicture, let image = pictures[0].picture, let tiff = image.tiffRepresentation {
            pboard.declareTypes([Self.markdownType, .png, .tiff], owner: nil)
            pboard.setString(markdown, forType: Self.markdownType)
            pboard.setData(tiff, forType: .tiff)
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                pboard.setData(png, forType: .png)
            }
            return true
        }
        if withPictures {
            pboard.declareTypes([Self.markdownType, .string, .html], owner: nil)
            pboard.setString(markdown, forType: .string)
            pboard.setString(MarkdownHTML.convert(markdown), forType: .html)
        } else {
            pboard.declareTypes([Self.markdownType, .string], owner: nil)
            pboard.setString(Self.withPicturePaths(markdown), forType: .string)
        }
        pboard.setString(markdown, forType: Self.markdownType)
        return true
    }

    /// `![](images/x.png)` → the picture file's full path.
    private static func withPicturePaths(_ markdown: String) -> String {
        let ns = markdown as NSString
        var text = ""
        var cursor = 0
        for match in ImageStore.reference.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            text += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            text += imagesDir.appendingPathComponent(ns.substring(with: match.range(at: 2))).path
            cursor = NSMaxRange(match.range)
        }
        return text + ns.substring(from: cursor)
    }

    /// The note's Markdown, for pasting back into Quotepad.
    private static let markdownType = NSPasteboard.PasteboardType("com.quotepad.markdown")

    // Pictures: pasted (screenshots, copied images, copied image files) or dragged in.
    private static let imageTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.markdownType] + super.readablePasteboardTypes + Self.imageTypes
    }

    /// What a screenshot's floating thumbnail (and apps like Photos) drag: a file that's only written
    /// once the drop happens, so there's nothing to wait for on the Desktop.
    private static let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + Self.imageTypes + Self.promiseTypes
    }

    override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        Self.promiseTypes.contains(type) ? .copy : super.dragOperation(for: dragInfo, type: type)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pboard = sender.draggingPasteboard
        guard pboard.availableType(from: Self.imageTypes) == nil,
              let promises = pboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] else {
            return super.performDragOperation(sender)
        }
        let images = promises.filter { $0.fileTypes.contains { UTType($0)?.conforms(to: .image) == true } }
        guard !images.isEmpty else { return super.performDragOperation(sender) }

        let drop = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QuotepadDrops/" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String] = []
        let group = DispatchGroup()
        for promise in images {
            group.enter()
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: Self.promiseQueue) { url, error in
                let name = error == nil ? ImageStore.importFile(url) : nil
                DispatchQueue.main.async {
                    if let name { names.append(name) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            try? FileManager.default.removeItem(at: folder)
            guard let self, !names.isEmpty, let storage = self.textStorage else { return }
            self.window?.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: min(drop, storage.length), length: 0))
            _ = self.insertPictures(names)
        }
        return true
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        insertCopiedMarkdown(from: pboard) || insertImages(from: pboard) || super.readSelection(from: pboard)
    }

    /// A picture copied in Quotepad: the same file at the same width, not a new copy of the image.
    private func insertCopiedMarkdown(from pboard: NSPasteboard) -> Bool {
        guard let markdown = pboard.string(forType: Self.markdownType), let storage = textStorage else { return false }
        let decoded = NoteCodec.decode(markdown, attributes: typingAttributes, host: codeBlockHost)
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: decoded.string) else { return true }
        storage.replaceCharacters(in: range, with: decoded)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + decoded.length, length: 0))
        return true
    }

    /// Each picture goes on a line of its own. In a list it goes inside the item, indented, so the
    /// numbering goes on after it.
    private func insertImages(from pboard: NSPasteboard) -> Bool {
        insertPictures(ImageStore.importImages(from: pboard))
    }

    /// Pictures already in `imagesDir`, at the selection.
    private func insertPictures(_ names: [String]) -> Bool {
        guard !names.isEmpty, let storage = textStorage else { return false }
        var range = selectedRange()
        let text = storage.string as NSString
        let inList = Markdown.listPictures(in: text, replacing: range)
        if let inList { range = inList.range }
        let pictures = NSMutableAttributedString()
        func append(_ string: String) {
            if !string.isEmpty { pictures.append(NSAttributedString(string: string, attributes: typingAttributes)) }
        }
        if inList?.newlineBefore ?? (range.location > 0 && text.character(at: range.location - 1) != 0x0A) {
            append("\n")
        }
        for (index, name) in names.enumerated() {
            if index > 0 { append("\n") }
            append(inList?.indent ?? "")
            let attachment = ImageAttachment(fileName: name)
            attachment.host = codeBlockHost as? ImageBlockHost
            let picture = NSMutableAttributedString(attachment: attachment)
            picture.addAttributes(typingAttributes, range: NSRange(location: 0, length: picture.length))
            pictures.append(picture)
        }
        append(inList?.after ?? "\n")
        guard shouldChangeText(in: range, replacementString: pictures.string) else { return true }
        storage.replaceCharacters(in: range, with: pictures)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + pictures.length, length: 0))
        return true
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == Self.markdownType, insertCopiedMarkdown(from: pboard) { return true }
        // Pictures before anything else: a drop (e.g. a screenshot's floating thumbnail) also carries
        // its file's path as text, which the text view would otherwise prefer and type in.
        if pboard.availableType(from: Self.imageTypes) != nil, insertImages(from: pboard) { return true }
        guard let pasted = pboard.string(forType: .string), let storage = textStorage else {
            return super.readSelection(from: pboard, type: type)
        }
        // "3.1" / "a." style lists become nested Markdown lists, shown in the chosen numbering style.
        let text = Markdown.normalizingPastedLists(pasted)
        guard text != pasted || NoteCodec.containsFence(text) else {
            return super.readSelection(from: pboard, type: type)
        }
        let decoded = NoteCodec.decode(text, attributes: typingAttributes, host: codeBlockHost)
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: decoded.string) else { return false }
        storage.replaceCharacters(in: range, with: decoded)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + decoded.length, length: 0))
        return true
    }
}

/// Runs a command box's command: it's written into a temporary `.command` file, which macOS opens in
/// Terminal (or whatever app the user picked for such files), so no permission to control Terminal is
/// needed. The shell stays open afterwards, in the home folder, for whatever comes next.
enum CommandRunner {
    static func run(_ command: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Quotepad", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("run-\(UUID().uuidString.prefix(8)).command")
        do {
            try script(for: command).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(file)
        // Terminal reads the file as it starts; give it time (a cold launch is slow), then clean up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The `.command` file: the user's login shell, the home folder, the command, then a shell to keep.
    static func script(for command: String) -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return "#!\(shell) -l\ncd ~\n\(command)\nexec \"\(shell)\" -l\n"
    }
}
