import Cocoa

// Live Markdown look for the note editor. Only attributes change, never the text: syntax marks
// stay in the note but are drawn invisibly (list, rule and fence marks stay visible, dimmed),
// so notes remain plain Markdown on disk and when copied.
//
//     # Heading        **bold**   *italic*   ~~strike~~   `code`
//     - item / 1. item / - [ ] task / - [x] done
//     > quote          ---        ``` fenced lines ```

enum Markdown {
    private static let heading = regex(#"^(#{1,6})[ \t]+"#)
    private static let titleHeading = regex(#"^#{1,6}(?:[ \t]+|$)"#) // also a bare "##" (titles are trimmed)
    private static let rule = regex(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let quote = regex(#"^ {0,3}>[ \t]?"#)
    private static let task = regex(#"^([ \t]*)([-*+])[ \t]+(\[([ xX])\])[ \t]+"#)
    private static let list = regex(#"^([ \t]*)([-*+]|(\d{1,9})([.)]))[ \t]+"#)
    private static let fence = regex(#"^ {0,3}```"#)

    private static let code = regex(#"`[^`\n]+`"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let italicStar = regex(#"(?<!\*)\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)"#)
    private static let italicUnderscore = regex(#"(?<![_\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#)

    private static let headingScale: [CGFloat] = [1.5, 1.3, 1.15, 1.05, 1, 1]
    private static let markColor = NSColor.tertiaryLabelColor
    private static let codeColor = NSColor.systemPink
    private static let quoteIndent: CGFloat = 14
    private static let hiddenFont = NSFont.systemFont(ofSize: 0.01)

    /// Marks syntax characters that are drawn invisibly; the value is a `HiddenKind` raw value.
    static let hiddenKey = NSAttributedString.Key("QuotepadMarkdownHidden")

    enum HiddenKind: String {
        /// "## " or "> " at the start of a line: the caret never stops inside or before it.
        case block
        /// "**", "`" etc. around inline text: the caret may sit on either side.
        case inline
    }

    struct HiddenRun {
        let range: NSRange
        let kind: HiddenKind
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    // MARK: - Styling

    /// Restyles the whole note. `base` is the plain editor look (font + color).
    static func style(_ storage: NSTextStorage, base: [NSAttributedString.Key: Any]) {
        guard let baseFont = base[.font] as? NSFont else { return }
        let text = storage.string as NSString
        let whole = NSRange(location: 0, length: text.length)

        storage.beginEditing()
        storage.addAttributes(base, range: whole)
        storage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: whole)
        storage.removeAttribute(.strikethroughStyle, range: whole)
        storage.removeAttribute(hiddenKey, range: whole)

        var inFence = false
        text.enumerateSubstrings(in: whole, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let isFence = match(fence, in: text, line) != nil
            if isFence || inFence {
                if isFence { inFence.toggle() }
                let mono = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                storage.addAttribute(.font, value: mono, range: line)
                if isFence { storage.addAttribute(.foregroundColor, value: markColor, range: line) }
                return
            }
            styleLine(line, in: storage, text: text, baseFont: baseFont)
        }
        storage.endEditing()
    }

    private static func styleLine(_ line: NSRange, in storage: NSTextStorage, text: NSString, baseFont: NSFont) {
        guard line.length > 0 else { return }
        var content = line // what's left for inline styling after the block marker

        if let m = match(heading, in: text, line) {
            storage.addAttributes(headingAttributes(level: m.range(at: 1).length, baseFont: baseFont), range: line)
            hide(m.range, .block, in: storage)
            content = after(m.range, in: line)
        } else if match(rule, in: text, line) != nil {
            storage.addAttribute(.foregroundColor, value: markColor, range: line)
            return
        } else if let m = match(quote, in: text, line) {
            storage.addAttributes(quoteAttributes(baseFont: baseFont), range: line)
            hide(m.range, .block, in: storage)
            content = after(m.range, in: line)
        } else if let m = match(task, in: text, line) {
            hangIndent(line, marker: m.range, in: storage, text: text, font: baseFont)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range(at: 2))
            storage.addAttribute(.foregroundColor, value: markColor, range: m.range(at: 3))
            content = after(m.range, in: line)
            if m.range(at: 4).length > 0, text.substring(with: m.range(at: 4)) != " " {
                storage.addAttributes([
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ], range: content)
            }
        } else if let m = match(list, in: text, line) {
            hangIndent(line, marker: m.range, in: storage, text: text, font: baseFont)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range(at: 2))
            content = after(m.range, in: line)
        }

        styleInline(content, in: storage, text: text)
    }

    private static func styleInline(_ range: NSRange, in storage: NSTextStorage, text: NSString) {
        guard range.length > 0 else { return }
        var taken: [NSRange] = []

        for m in code.matches(in: text as String, range: range) {
            storage.enumerateAttribute(.font, in: m.range) { value, sub, _ in
                guard let font = value as? NSFont else { return }
                let mono = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: font.isBold ? .bold : .regular)
                storage.addAttribute(.font, value: mono, range: sub)
            }
            storage.addAttribute(.foregroundColor, value: codeColor, range: m.range)
            hideMarks(m.range, markLength: 1, in: storage)
            taken.append(m.range)
        }

        func each(_ pattern: NSRegularExpression, markLength: Int, apply: (NSRange) -> Void) {
            for m in pattern.matches(in: text as String, range: range)
            where !taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                apply(m.range)
                hideMarks(m.range, markLength: markLength, in: storage)
            }
        }
        each(bold, markLength: 2) { addTraits(.bold, to: $0, in: storage) }
        each(strike, markLength: 2) { storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: $0) }
        each(italicStar, markLength: 1) { slant($0, in: storage) }
        each(italicUnderscore, markLength: 1) { slant($0, in: storage) }
    }

    // MARK: - Helpers

    private static func match(_ pattern: NSRegularExpression, in text: NSString, _ line: NSRange) -> NSTextCheckingResult? {
        pattern.firstMatch(in: text as String, options: [.anchored], range: line)
    }

    private static func after(_ marker: NSRange, in line: NSRange) -> NSRange {
        NSRange(location: NSMaxRange(marker), length: NSMaxRange(line) - NSMaxRange(marker))
    }

    /// Near-zero width and fully transparent. Later font changes (bold, slant) keep the tiny size.
    private static func hide(_ range: NSRange, _ kind: HiddenKind, in storage: NSTextStorage) {
        storage.addAttributes([
            .font: hiddenFont,
            .foregroundColor: NSColor.clear,
            hiddenKey: kind.rawValue,
        ], range: range)
    }

    private static func hideMarks(_ range: NSRange, markLength: Int, in storage: NSTextStorage) {
        hide(NSRange(location: range.location, length: markLength), .inline, in: storage)
        hide(NSRange(location: NSMaxRange(range) - markLength, length: markLength), .inline, in: storage)
    }

    private static func headingAttributes(level: Int, baseFont: NSFont) -> [NSAttributedString.Key: Any] {
        let size = (baseFont.pointSize * headingScale[level - 1]).rounded()
        let font = withTraits(baseFont.withSize(size), .bold)
        return [.font: font, .paragraphStyle: lineHeightStyle(for: font)]
    }

    private static func quoteAttributes(baseFont: NSFont) -> [NSAttributedString.Key: Any] {
        let style = lineHeightStyle(for: baseFont)
        style.firstLineHeadIndent = quoteIndent
        style.headIndent = quoteIndent
        return [.foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
    }

    /// Keeps a line holding only a hidden marker ("## ") from collapsing to the hidden font's height.
    private static func lineHeightStyle(for font: NSFont) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        return style
    }

    /// Wrapped lines of a list item line up with the item's text, not its marker.
    private static func hangIndent(_ line: NSRange, marker: NSRange, in storage: NSTextStorage, text: NSString, font: NSFont) {
        let prefix = text.substring(with: marker).replacingOccurrences(of: "\t", with: "    ")
        let style = NSMutableParagraphStyle()
        style.headIndent = ceil((prefix as NSString).size(withAttributes: [.font: font]).width)
        storage.addAttribute(.paragraphStyle, value: style, range: line)
    }

    private static func addTraits(_ traits: NSFontDescriptor.SymbolicTraits, to range: NSRange, in storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(.font, value: withTraits(font, traits), range: sub)
        }
    }

    /// Synthetic slant (a skewed font matrix) instead of an italic font: Hangul fallback fonts have
    /// no italic, so a real italic would leave Korean text upright. TextKit 2 ignores `.obliqueness`.
    private static func slant(_ range: NSRange, in storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            let skew = AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)
            let slanted = NSFont(descriptor: font.fontDescriptor.withMatrix(skew), size: font.pointSize) ?? font
            storage.addAttribute(.font, value: slanted, range: sub)
        }
    }

    private static func withTraits(_ font: NSFont, _ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    // MARK: - Hidden marks

    /// The hidden run the caret at `location` would be stuck in: strictly inside any run, or at the
    /// start of a block marker (typing there would break the "## ").
    static func hiddenRun(trapping location: Int, in storage: NSTextStorage) -> HiddenRun? {
        guard let run = hiddenRun(at: location, in: storage) else { return nil }
        return run.range.location < location || run.kind == .block ? run : nil
    }

    /// The hidden run right before the caret, if any.
    static func hiddenRun(endingAt location: Int, in storage: NSTextStorage) -> HiddenRun? {
        guard location > 0, let run = hiddenRun(at: location - 1, in: storage),
              NSMaxRange(run.range) == location else { return nil }
        return run
    }

    private static func hiddenRun(at location: Int, in storage: NSTextStorage) -> HiddenRun? {
        guard location < storage.length else { return nil }
        var range = NSRange()
        let value = storage.attribute(hiddenKey, at: location, longestEffectiveRange: &range,
                                      in: NSRange(location: 0, length: storage.length))
        guard let raw = value as? String, let kind = HiddenKind(rawValue: raw) else { return nil }
        return HiddenRun(range: range, kind: kind)
    }

    /// What newly typed text on the caret's line should look like before the next restyle: the
    /// line's block look (heading, quote) without any inline style or hidden-mark attributes.
    static func typingAttributes(at caret: Int, in text: NSString, base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        guard let baseFont = base[.font] as? NSFont else { return base }
        var start = 0, contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(caret, text.length), length: 0))
        let line = NSRange(location: start, length: contentsEnd - start)
        var attributes = base
        if let m = match(heading, in: text, line) {
            attributes.merge(headingAttributes(level: m.range(at: 1).length, baseFont: baseFont)) { $1 }
        } else if match(quote, in: text, line) != nil {
            attributes.merge(quoteAttributes(baseFont: baseFont)) { $1 }
        }
        return attributes
    }

    // MARK: - Return key in lists

    enum Continuation {
        /// Start the next line with this marker.
        case next(String)
        /// The item is empty: remove its marker to end the list.
        case end(NSRange)
    }

    /// What Return should do on a list or quote line, given the caret position. Nil for normal lines.
    static func continuation(in text: NSString, caret: Int) -> Continuation? {
        var start = 0, contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: caret, length: 0))
        let line = NSRange(location: start, length: contentsEnd - start)
        guard match(rule, in: text, line) == nil else { return nil }

        let marker: NSRange
        let next: String
        if let m = match(task, in: text, line) {
            marker = m.range
            next = text.substring(with: m.range(at: 1)) + text.substring(with: m.range(at: 2)) + " [ ] "
        } else if let m = match(list, in: text, line) {
            marker = m.range
            let indent = text.substring(with: m.range(at: 1))
            if m.range(at: 3).location != NSNotFound, let number = Int(text.substring(with: m.range(at: 3))) {
                next = indent + "\(number + 1)" + text.substring(with: m.range(at: 4)) + " "
            } else {
                next = indent + text.substring(with: m.range(at: 2)) + " "
            }
        } else if let m = match(quote, in: text, line) {
            marker = m.range
            next = text.substring(with: m.range).hasSuffix(">") ? text.substring(with: m.range) + " " : text.substring(with: m.range)
        } else {
            return nil
        }

        guard caret >= NSMaxRange(marker) else { return nil } // caret inside the marker: plain Return
        if NSMaxRange(marker) == NSMaxRange(line) { return .end(marker) }
        return .next(next)
    }

    /// The text of a heading line without its leading "#"s, for tab titles.
    static func strippingHeading(_ line: String) -> String {
        let ns = line as NSString
        guard let m = match(titleHeading, in: ns, NSRange(location: 0, length: ns.length)) else { return line }
        return ns.substring(from: NSMaxRange(m.range))
    }
}

private extension NSFont {
    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
}

