import Cocoa

// Live Markdown look for the note editor. Only attributes change, never the text: syntax marks
// stay in the note but are drawn invisibly (list and fence marks stay visible, dimmed; a "---"
// line is drawn as a horizontal rule, tables as aligned columns), so notes remain plain Markdown
// on disk and when copied.
//
//     # Heading        **bold**   *italic*   ~~strike~~   `code`
//     - item / 1. item / - [ ] task / - [x] done
//     > quote          ---        ``` fenced lines ```
//     | a | b |
//     |---|---|        tables (rows must start with "|")

enum Markdown {
    private static let heading = regex(#"^(#{1,6})[ \t]+"#)
    private static let titleHeading = regex(#"^#{1,6}(?:[ \t]+|$)"#) // also a bare "##" (titles are trimmed)
    private static let rule = regex(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let quote = regex(#"^ {0,3}>[ \t]?"#)
    private static let task = regex(#"^([ \t]*)([-*+])[ \t]+(\[([ xX])\])[ \t]+"#)
    private static let list = regex(#"^([ \t]*)([-*+]|(\d{1,9})([.)]))[ \t]+"#)
    private static let fence = regex(#"^ {0,3}```"#)
    private static let tableRow = regex(#"^[ \t]*\|"#)
    private static let tableSeparator = regex(#"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)

    private static let code = regex(#"`[^`\n]+`"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let italicStar = regex(#"(?<!\*)\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)"#)
    private static let italicUnderscore = regex(#"(?<![_\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#)

    private static let headingScale: [CGFloat] = [1.5, 1.3, 1.15, 1.05, 1, 1]
    private static let markColor = NSColor.tertiaryLabelColor
    private static let quoteIndent: CGFloat = 14
    /// Room inside an inline code chip, on each side of its text.
    private static let codePadding: CGFloat = 3
    /// Space between table columns.
    private static let columnGap: CGFloat = 16
    private static let hiddenFont = NSFont.systemFont(ofSize: 0.01)

    /// Marks syntax characters that are drawn invisibly; the value is a `HiddenKind` raw value.
    static let hiddenKey = NSAttributedString.Key("QuotepadMarkdownHidden")
    /// Marks a line drawn by `MarkdownLayoutDelegate` as a horizontal rule ("---", or a table's
    /// header separator). The value is the rule's width as an `NSNumber`; 0 spans the whole line.
    static let ruleKey = NSAttributedString.Key("QuotepadMarkdownRule")
    /// Marks inline code (backticks included); `MarkdownLayoutDelegate` draws a chip behind it.
    static let codeKey = NSAttributedString.Key("QuotepadMarkdownCode")
    /// Marks a table row that gets a line under it; the value is the table width as an `NSNumber`.
    static let rowBorderKey = NSAttributedString.Key("QuotepadMarkdownRowBorder")

    enum HiddenKind: String {
        /// "## " or "> " at the start of a line: the caret never stops inside or before it.
        case block
        /// "**", "`" etc. around inline text: the caret may sit on either side.
        case inline
        /// A table's "|": the caret skips the one starting a row, and Backspace never deletes it.
        case pipe
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
        for key in [hiddenKey, ruleKey, codeKey, rowBorderKey, .kern] {
            storage.removeAttribute(key, range: whole)
        }

        var lines: [NSRange] = []
        text.enumerateSubstrings(in: whole, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            lines.append(line)
        }
        var inFence = false
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let isFence = match(fence, in: text, line) != nil
            if isFence || inFence {
                if isFence { inFence.toggle() }
                let mono = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                storage.addAttribute(.font, value: mono, range: line)
                if isFence { storage.addAttribute(.foregroundColor, value: markColor, range: line) }
                index += 1
            } else if let end = tableEnd(startingAt: index, in: lines, text: text) {
                styleTable(Array(lines[index..<end]), in: storage, text: text)
                index = end
            } else {
                styleLine(line, in: storage, text: text, baseFont: baseFont)
                index += 1
            }
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
            storage.addAttribute(ruleKey, value: NSNumber(value: 0), range: line)
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
            storage.addAttribute(codeKey, value: true, range: m.range)
            hideMarks(m.range, markLength: 1, in: storage)
            // The chip runs from the opening to the closing backtick; kerning opens room inside it.
            addKern(codePadding, at: m.range.location, in: storage)
            addKern(codePadding, at: NSMaxRange(m.range) - 2, in: storage)
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

    // MARK: - Tables

    /// A table needs a header row and a separator row; it runs until the first line that isn't a row.
    private static func tableEnd(startingAt index: Int, in lines: [NSRange], text: NSString) -> Int? {
        guard index + 1 < lines.count, match(tableRow, in: text, lines[index]) != nil,
              text.substring(with: lines[index + 1]).contains("|"),
              match(tableSeparator, in: text, lines[index + 1]) != nil else { return nil }
        var end = index + 2
        while end < lines.count, match(tableRow, in: text, lines[end]) != nil { end += 1 }
        return end
    }

    /// Hides the pipes and lines the columns up by kerning the end of each cell to its column's width.
    private static func styleTable(_ lines: [NSRange], in storage: NSTextStorage, text: NSString) {
        let rows = [lines[0]] + lines.dropFirst(2)
        let rowStyle = NSMutableParagraphStyle()
        rowStyle.paragraphSpacingBefore = 3
        rowStyle.paragraphSpacing = 3

        var cellsByRow: [[NSRange]] = []
        for (rowIndex, row) in rows.enumerated() {
            let pipes = pipePositions(in: row, text: text)
            var cells: [NSRange] = []
            for (n, pipe) in pipes.enumerated() {
                let end = n + 1 < pipes.count ? pipes[n + 1] : NSMaxRange(row)
                if n + 1 == pipes.count && end == pipe + 1 { break } // nothing after the closing pipe
                cells.append(NSRange(location: pipe + 1, length: end - pipe - 1))
            }
            storage.addAttribute(.paragraphStyle, value: rowStyle, range: row)
            if rowIndex == 0 { addTraits(.bold, to: row, in: storage) }
            for cell in cells { styleInline(cell, in: storage, text: text) }
            for pipe in pipes { hide(NSRange(location: pipe, length: 1), .pipe, in: storage) }
            cellsByRow.append(cells)
        }

        // Column widths, measured after the cells got their final fonts.
        var widths: [CGFloat] = []
        for cells in cellsByRow {
            for (column, cell) in cells.enumerated() {
                let width = ceil(storage.attributedSubstring(from: cell).size().width)
                if column < widths.count { widths[column] = max(widths[column], width) } else { widths.append(width) }
            }
        }
        for cells in cellsByRow {
            for (column, cell) in cells.enumerated().dropLast() {
                let width = ceil(storage.attributedSubstring(from: cell).size().width)
                // An empty cell's last character is the pipe before it.
                addKern(widths[column] + columnGap - width, at: NSMaxRange(cell) - 1, in: storage)
            }
        }
        let tableWidth = NSNumber(value: Double(widths.reduce(0, +) + columnGap * CGFloat(max(0, widths.count - 1))))

        // Header separator: drawn as a rule, its text hidden and its line kept short.
        let separator = lines[1]
        hide(separator, .block, in: storage)
        let separatorStyle = NSMutableParagraphStyle()
        separatorStyle.minimumLineHeight = 8
        separatorStyle.maximumLineHeight = 8
        storage.addAttributes([ruleKey: tableWidth, .paragraphStyle: separatorStyle], range: separator)
        for row in rows.dropFirst().dropLast() {
            storage.addAttribute(rowBorderKey, value: tableWidth, range: row)
        }
    }

    /// Positions of the "|" that split cells: not escaped ("\|") and not inside `code`.
    private static func pipePositions(in row: NSRange, text: NSString) -> [Int] {
        var positions: [Int] = []
        var inCode = false
        for index in row.location..<NSMaxRange(row) {
            switch text.character(at: index) {
            case 0x60: inCode.toggle() // `
            case 0x7C where !inCode && (index == 0 || text.character(at: index - 1) != 0x5C): positions.append(index) // | not after \
            default: break
            }
        }
        return positions
    }

    // MARK: - Helpers

    private static func addKern(_ amount: CGFloat, at index: Int, in storage: NSTextStorage) {
        let current = (storage.attribute(.kern, at: index, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
        storage.addAttribute(.kern, value: NSNumber(value: current + Double(amount)), range: NSRange(location: index, length: 1))
    }

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
        switch run.kind {
        case .block: return run
        case .inline: return run.range.location < location ? run : nil
        case .pipe: // only the pipe that starts a row
            let lineStart = location == 0 || (storage.string as NSString).character(at: location - 1) == 0x0A
            return lineStart ? run : nil
        }
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

    private static let titleMarks: [(NSRegularExpression, String)] = [
        (regex(#"`([^`\n]+)`"#), "$1"),
        (bold, "$2"),
        (strike, "$1"),
        (italicStar, "$1"),
        (italicUnderscore, "$1"),
    ]

    /// A line as a tab title: without heading "#"s and inline marks (`code`, **bold**, ...).
    static func plainTitle(_ line: String) -> String {
        var title = line
        let ns = line as NSString
        if let m = match(titleHeading, in: ns, NSRange(location: 0, length: ns.length)) {
            title = ns.substring(from: NSMaxRange(m.range))
        }
        for (pattern, template) in titleMarks {
            title = pattern.stringByReplacingMatches(in: title, range: NSRange(location: 0, length: (title as NSString).length), withTemplate: template)
        }
        return title
    }
}

private extension NSFont {
    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
}

// MARK: - Drawing

/// Gives lines that need extra drawing (rules, code chips, table row lines) their own layout fragment.
final class MarkdownLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, MarkdownLayoutFragment.needsDrawing(paragraph.attributedString) {
            return MarkdownLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

private final class MarkdownLayoutFragment: NSTextLayoutFragment {
    static func needsDrawing(_ string: NSAttributedString) -> Bool {
        guard string.length > 0 else { return false }
        if string.attribute(Markdown.ruleKey, at: 0, effectiveRange: nil) != nil
            || string.attribute(Markdown.rowBorderKey, at: 0, effectiveRange: nil) != nil { return true }
        var hasCode = false
        string.enumerateAttribute(Markdown.codeKey, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if value != nil { hasCode = true; stop.pointee = true }
        }
        return hasCode
    }

    private var string: NSAttributedString? { (textElement as? NSTextParagraph)?.attributedString }

    /// The text width of the container; `point.x` in `draw` is already past the left padding.
    private var lineWidth: CGFloat {
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 5
        return (textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width) - padding * 2
    }

    private func width(_ key: NSAttributedString.Key, in string: NSAttributedString) -> CGFloat? {
        guard let number = string.attribute(key, at: 0, effectiveRange: nil) as? NSNumber else { return nil }
        return number.doubleValue > 0 ? min(CGFloat(number.doubleValue), lineWidth) : lineWidth
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        guard let string, string.length > 0 else { return super.draw(at: point, in: context) }
        if let rule = width(Markdown.ruleKey, in: string) {
            // Keeps the line's height (and caret) but draws a rule instead of the text.
            let lineHeight = textLineFragments.first?.typographicBounds.height ?? layoutFragmentFrame.height
            strokeLine(at: point.y + lineHeight / 2, from: point.x, width: rule, in: context)
            return
        }
        drawCodeChips(string, at: point, in: context)
        super.draw(at: point, in: context)
        if let border = width(Markdown.rowBorderKey, in: string) {
            strokeLine(at: point.y + layoutFragmentFrame.height - 1, from: point.x, width: border, in: context)
        }
    }

    private func drawCodeChips(_ string: NSAttributedString, at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setFillColor(NSColor.labelColor.withAlphaComponent(0.1).cgColor)
        string.enumerateAttribute(Markdown.codeKey, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard value != nil else { return }
            for line in textLineFragments {
                let part = NSIntersectionRange(range, line.characterRange)
                guard part.length > 0 else { continue }
                let start = line.locationForCharacter(at: part.location).x
                let end = line.locationForCharacter(at: NSMaxRange(part)).x
                let bounds = line.typographicBounds
                let rect = CGRect(x: point.x + bounds.minX + start, y: point.y + bounds.minY + 1,
                                  width: end - start, height: bounds.height - 2)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            }
        }
        context.fillPath()
        context.restoreGState()
    }

    private func strokeLine(at y: CGFloat, from x: CGFloat, width: CGFloat, in context: CGContext) {
        let y = y.rounded() + 0.5
        context.saveGState()
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x + width, y: y))
        context.strokePath()
        context.restoreGState()
    }

    override var renderingSurfaceBounds: CGRect {
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        return super.renderingSurfaceBounds.union(CGRect(x: 0, y: 0, width: width, height: layoutFragmentFrame.height))
    }
}
