import Cocoa

// Boxes with a copy button, embedded in the note as TextKit 2 view attachments. On disk they're
// Markdown fences, so notes stay plain text. Two kinds:
//
//  - Snippet (`/p`): one line for emails, keys, commands.  - Code (`/code`): multi-line code.
//
//     ```                                                   ~~~
//     someone@example.com                                   func hello() {
//     ```                                                       print("hi")
//                                                           }
//                                                           ~~~
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
    /// Multi-line, created with `/code`, stored between ~~~ fences.
    case code
}

final class CodeBlockAttachment: NSTextAttachment {
    let kind: CodeBlockKind
    var content: String
    weak var host: CodeBlockHost?
    /// Set when the box is created by the user; the view grabs focus as soon as it's on screen.
    var focusWhenLoaded = false
    weak var liveView: CodeBlockView?

    var lineCount: Int { kind == .snippet ? 1 : content.components(separatedBy: "\n").count }

    init(content: String, kind: CodeBlockKind) {
        self.kind = kind
        self.content = content
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
        let lines = (textAttachment as? CodeBlockAttachment)?.lineCount ?? 1
        return CGRect(x: 0, y: -CodeBlockView.baselineOffset, width: width, height: CodeBlockView.height(lines: lines))
    }
}

private final class BoxBackgroundView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
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

    static func height(lines: Int) -> CGFloat {
        CGFloat(max(1, lines)) * lineHeight + (innerPadding + verticalMargin) * 2
    }

    let attachment: CodeBlockAttachment
    private let box = BoxBackgroundView()
    private let scrollView = HorizontalScrollView()
    private let editor = NSTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let copyButton = IconButton(symbolName: "doc.on.doc", pointSize: 11, weight: .medium, cornerRadius: 5, label: "복사")
    private var copyResetWork: DispatchWorkItem?
    private var isCode: Bool { attachment.kind == .code }

    init(attachment: CodeBlockAttachment) {
        self.attachment = attachment
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Self.height(lines: attachment.lineCount)))
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

        placeholder.stringValue = isCode ? "코드" : "이메일, 명령어 등 복사할 내용"
        placeholder.font = Self.font
        placeholder.textColor = .placeholderTextColor
        placeholder.isHidden = !attachment.content.isEmpty
        addSubview(placeholder, positioned: .below, relativeTo: scrollView)

        copyButton.toolTip = "복사"
        copyButton.onClick = { [weak self] in self?.copyContent() }
        addSubview(copyButton)

        setAccessibilityRole(.group)
        setAccessibilityLabel(isCode ? "코드 블록" : "복사 박스")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        box.frame = bounds.insetBy(dx: 0, dy: Self.verticalMargin)
        let buttonSize: CGFloat = 22
        // The copy button sits beside the first line (the only line of a snippet).
        let firstLineMidY = box.frame.maxY - Self.innerPadding - Self.lineHeight / 2
        copyButton.frame = NSRect(x: box.frame.maxX - 6 - buttonSize, y: firstLineMidY - buttonSize / 2, width: buttonSize, height: buttonSize)
        let textX = box.frame.minX + 12
        let textHeight = CGFloat(attachment.lineCount) * Self.lineHeight
        let textFrame = NSRect(
            x: textX,
            y: box.frame.maxY - Self.innerPadding - textHeight,
            width: max(0, copyButton.frame.minX - 8 - textX),
            height: textHeight
        )
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

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        let oldLineCount = attachment.lineCount
        attachment.content = editor.string
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
    static let codeFence = "~~~"
    // Typed with the Korean layout on, "/p" comes out as "/ㅔ" and "/code" as "/챙ㄷ".
    static let snippetTriggers: Set<String> = ["/p", "/ㅔ"]
    static let codeTriggers: Set<String> = ["/code", "/코드", "/챙ㄷ"]

    static func trigger(_ line: String) -> CodeBlockKind? {
        if snippetTriggers.contains(line) { return .snippet }
        if codeTriggers.contains(line) { return .code }
        return nil
    }

    static func containsFence(_ text: String) -> Bool {
        text.contains(fence) || text.contains(codeFence)
    }

    static func attachmentString(_ attachment: CodeBlockAttachment, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// Turns ``` fenced one-line blocks into snippets and ~~~ fenced blocks into code blocks.
    static func decode(_ text: String, attributes: [NSAttributedString.Key: Any], host: CodeBlockHost?) -> NSAttributedString {
        let lines = text.components(separatedBy: "\n")
        let result = NSMutableAttributedString()
        var index = 0
        while index < lines.count {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
            if lines[index] == fence, index + 2 < lines.count, lines[index + 2] == fence {
                let attachment = CodeBlockAttachment(content: lines[index + 1], kind: .snippet)
                attachment.host = host
                result.append(attachmentString(attachment, attributes: attributes))
                index += 3
            } else if lines[index] == codeFence,
                      let close = lines[(index + 1)...].firstIndex(of: codeFence) {
                let content = lines[(index + 1)..<close].joined(separator: "\n")
                let attachment = CodeBlockAttachment(content: content, kind: .code)
                attachment.host = host
                result.append(attachmentString(attachment, attributes: attributes))
                index = close + 1
            } else {
                result.append(NSAttributedString(string: lines[index], attributes: attributes))
                index += 1
            }
        }
        return result
    }

    static func encode(_ attributed: NSAttributedString) -> String {
        let source = attributed.string as NSString
        var output = ""
        var cursor = 0
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let block = value as? CodeBlockAttachment else { return }
            output += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let blockFence = block.kind == .snippet ? fence : codeFence
            output += "\(blockFence)\n\(block.content)\n\(blockFence)"
            cursor = range.location + range.length
        }
        output += source.substring(from: cursor)
        return output
    }
}

/// Main note editor: copy/cut write code boxes as Markdown fences, and pasting fences makes boxes.
final class NoteTextView: NSTextView {
    weak var codeBlockHost: CodeBlockHost?

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage, selectedRange().length > 0 else {
            return super.writeSelection(to: pboard, types: types)
        }
        pboard.clearContents()
        return pboard.setString(NoteCodec.encode(storage.attributedSubstring(from: selectedRange())), forType: .string)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let text = pboard.string(forType: .string), NoteCodec.containsFence(text), let storage = textStorage else {
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
