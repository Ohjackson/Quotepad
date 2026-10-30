import Foundation

/// A note's Markdown as HTML, for the clipboard: apps like Notion can't open the note's relative
/// `images/…` paths, so pictures go in as `data:` URLs carrying the image itself.
enum MarkdownHTML {
    static func convert(_ markdown: String) -> String {
        var html = ""
        var lists: [(indent: Int, tag: String)] = []
        var lines = markdown.components(separatedBy: "\n")[...]

        func closeLists(to depth: Int = 0) {
            while lists.count > depth { html += "</li></\(lists.removeLast().tag)>" }
        }

        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code: ``` one-line boxes and ~~~ code blocks.
            if trimmed == NoteCodec.fence || NoteCodec.codeFenceLanguage(trimmed) != nil {
                closeLists()
                let closing = trimmed == NoteCodec.fence ? NoteCodec.fence : NoteCodec.codeFence
                var code: [String] = []
                while let next = lines.popFirst(), next.trimmingCharacters(in: .whitespaces) != closing { code.append(next) }
                html += "<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>"
                continue
            }

            // Tables: a "|" row followed by a "|---|" separator.
            if trimmed.hasPrefix("|"), let separator = lines.first, isTableSeparator(separator) {
                closeLists()
                lines.removeFirst()
                html += "<table><tr>" + cells(trimmed).map { "<th>\(inline($0))</th>" }.joined() + "</tr>"
                while let row = lines.first?.trimmingCharacters(in: .whitespaces), row.hasPrefix("|") {
                    lines.removeFirst()
                    html += "<tr>" + cells(row).map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
                }
                html += "</table>"
                continue
            }

            if let item = listItem(line) {
                while let top = lists.last, item.indent < top.indent { html += "</li></\(lists.removeLast().tag)>" }
                if let top = lists.last, item.indent == top.indent {
                    if top.tag == item.tag {
                        html += "</li>"
                    } else {
                        html += "</li></\(lists.removeLast().tag)><\(item.tag)>"
                        lists.append((item.indent, item.tag))
                    }
                } else {
                    html += "<\(item.tag)>" // nested inside the open <li>, or a new list
                    lists.append((item.indent, item.tag))
                }
                html += "<li>" + inline(item.content)
                continue
            }
            closeLists()

            if trimmed.isEmpty { continue }
            if let level = headingLevel(trimmed) {
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                html += "<h\(level)>\(inline(text))</h\(level)>"
            } else if isRule(trimmed) {
                html += "<hr>"
            } else if trimmed.hasPrefix(">") {
                html += "<blockquote>\(inline(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))</blockquote>"
            } else {
                html += "<p>\(inline(trimmed))</p>"
            }
        }
        closeLists()
        return "<meta charset=\"utf-8\">" + html
    }

    // MARK: - Blocks

    private static func listItem(_ line: String) -> (indent: Int, tag: String, content: String)? {
        let ns = line as NSString
        guard let m = listPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let indent = ns.substring(with: m.range(at: 1)).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let ordered = m.range(at: 3).location != NSNotFound
        var content = ns.substring(from: NSMaxRange(m.range))
        if !ordered, let box = content.range(of: #"^\[([ xX])\][ \t]+"#, options: .regularExpression) {
            content = (content[box].hasPrefix("[ ]") ? "☐ " : "☑ ") + content[box.upperBound...]
        }
        return (indent, ordered ? "ol" : "ul", content)
    }

    private static let listPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|(\d{1,9})[.)])[ \t]+"#)

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("-") && trimmed.contains("|") && trimmed.allSatisfy { "|-: \t".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var parts = row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    // MARK: - Inline

    private static func inline(_ text: String) -> String {
        var html = escape(text)
        for (pattern, template) in inlineRules {
            html = pattern.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: template)
        }
        return replacingImages(in: html)
    }

    private static let inlineRules: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"`([^`]+)`"#), "<code>$1</code>"),
        (try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#), "<strong>$2</strong>"),
        (try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#), "<del>$1</del>"),
        (try! NSRegularExpression(pattern: #"(?<!\*)\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)"#), "<em>$1</em>"),
    ]

    /// `![|320](images/x.png)` → an `<img>` carrying the picture's data.
    private static func replacingImages(in html: String) -> String {
        let ns = html as NSString
        var result = ""
        var cursor = 0
        for match in ImageStore.reference.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let file = ns.substring(with: match.range(at: 2))
            let width = match.range(at: 1).location == NSNotFound ? "" : " width=\"\(ns.substring(with: match.range(at: 1)))\""
            if let data = try? Data(contentsOf: imagesDir.appendingPathComponent(file)) {
                result += "<img src=\"data:\(mimeType(of: file));base64,\(data.base64EncodedString())\"\(width)>"
            }
            cursor = NSMaxRange(match.range)
        }
        return result + ns.substring(from: cursor)
    }

    private static func mimeType(of file: String) -> String {
        switch (file as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        default: return "image/png"
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
