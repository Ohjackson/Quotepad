import Cocoa

// A "code box": a one-line, horizontally scrolling field with a copy button, embedded in the
// note as a TextKit 2 view attachment. On disk it's a Markdown fence, so notes stay plain text:
//
//     ```
//     someone@example.com
//     ```

protocol CodeBlockHost: AnyObject {
    func codeBlockDidChange(_ attachment: CodeBlockAttachment)
    /// Move the caret out of the box, to the line after it (`after`) or before it.
    func codeBlockRequestsExit(_ attachment: CodeBlockAttachment, after: Bool)
    func codeBlockRequestsRemoval(_ attachment: CodeBlockAttachment)
}

final class CodeBlockAttachment: NSTextAttachment {
    var content: String
    weak var host: CodeBlockHost?
    /// Set when the box is created by the user; the view grabs focus as soon as it's on screen.
    var focusWhenLoaded = false
    weak var liveView: CodeBlockView?

    init(content: String) {
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
        return CGRect(x: 0, y: -CodeBlockView.baselineOffset, width: width, height: CodeBlockView.height)
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
    static let height: CGFloat = 40
    static let baselineOffset: CGFloat = 12
    private static let verticalMargin: CGFloat = 3
    private static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))

    let attachment: CodeBlockAttachment
    private let box = BoxBackgroundView()
    private let scrollView = HorizontalScrollView()
    private let editor = NSTextView()
    private let placeholder = NSTextField(labelWithString: "이메일, 명령어 등 복사할 내용")
    private let copyButton = IconButton(symbolName: "doc.on.doc", pointSize: 11, weight: .medium, cornerRadius: 5, label: "복사")
    private var copyResetWork: DispatchWorkItem?

    init(attachment: CodeBlockAttachment) {
        self.attachment = attachment
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Self.height))
        addSubview(box)

        editor.isRichText = false
        editor.font = Self.font
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.allowsUndo = true
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: Self.lineHeight)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: Self.lineHeight)
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

        placeholder.font = Self.font
        placeholder.textColor = .placeholderTextColor
        placeholder.isHidden = !attachment.content.isEmpty
        addSubview(placeholder, positioned: .below, relativeTo: scrollView)

        copyButton.toolTip = "복사"
        copyButton.onClick = { [weak self] in self?.copyContent() }
        addSubview(copyButton)

        setAccessibilityRole(.group)
        setAccessibilityLabel("코드 박스")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        box.frame = bounds.insetBy(dx: 0, dy: Self.verticalMargin)
        let buttonSize: CGFloat = 22
        copyButton.frame = NSRect(x: box.frame.maxX - 6 - buttonSize, y: box.frame.midY - buttonSize / 2, width: buttonSize, height: buttonSize)
        let textX = box.frame.minX + 12
        let textFrame = NSRect(
            x: textX,
            y: box.frame.midY - Self.lineHeight / 2,
            width: max(0, copyButton.frame.minX - 8 - textX),
            height: Self.lineHeight
        )
        scrollView.frame = textFrame
        placeholder.frame = textFrame
        // Fill the visible width so clicks on the empty right side still land in the editor.
        editor.minSize = NSSize(width: textFrame.width, height: Self.lineHeight)
        editor.frame.size = NSSize(width: max(editor.frame.width, textFrame.width), height: Self.lineHeight)
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
        attachment.content = editor.string
        placeholder.isHidden = !editor.string.isEmpty
        attachment.host?.codeBlockDidChange(attachment)
    }

    /// Single line: pasted line breaks become spaces.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard let replacementString, replacementString.contains(where: \.isNewline) else { return true }
        let flattened = replacementString.split(whereSeparator: \.isNewline).joined(separator: " ")
        textView.insertText(flattened, replacementRange: range)
        return false
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
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
}

// MARK: - Plain text <-> attributed note

enum NoteCodec {
    static let fence = "```"
    static let triggers: Set<String> = ["/code", "/코드", "/챙ㄷ"] // "/챙ㄷ" = "/code" typed with the Korean layout on

    static func attachmentString(_ attachment: CodeBlockAttachment, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// Turns fenced one-line blocks into code boxes.
    static func decode(_ text: String, attributes: [NSAttributedString.Key: Any], host: CodeBlockHost?) -> NSAttributedString {
        let lines = text.components(separatedBy: "\n")
        let result = NSMutableAttributedString()
        var index = 0
        while index < lines.count {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
            if lines[index] == fence, index + 2 < lines.count, lines[index + 2] == fence {
                let attachment = CodeBlockAttachment(content: lines[index + 1])
                attachment.host = host
                result.append(attachmentString(attachment, attributes: attributes))
                index += 3
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
            output += "\(fence)\n\(block.content)\n\(fence)"
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
        guard let text = pboard.string(forType: .string), text.contains(NoteCodec.fence), let storage = textStorage else {
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
