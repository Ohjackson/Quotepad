import Cocoa

// Regex-based syntax coloring for code blocks, close to VS Code's Dark+ / Light+ themes.
// Not a parser: one pass of a combined pattern per language (comments, strings, numbers, words),
// with words sorted into keywords, types (Capitalized) and function calls (followed by "(").

struct CodeLanguage {
    /// Stored after the fence (`~~~python`) and accepted after `/code `.
    let id: String
    let name: String
    var aliases: [String] = []
    var keywords: Set<String> = []
    var literals: Set<String> = []
    var lineComments: [String] = []
    var blockComments = false
    var tripleQuotes = false
    var singleQuoteStrings = true
    var backtickStrings = false
    var decorators = false
    var directives = false
    var shellVariables = false
    var keys = false
    var caseInsensitive = false

    static let all: [CodeLanguage] = [python, java, javascript, typescript, kotlin, swift, c, cpp, csharp, go, rust, sql, shell, json, yaml]

    static func find(_ name: String) -> CodeLanguage? {
        let name = name.lowercased()
        return all.first { $0.id == name || $0.aliases.contains(name) }
    }
}

enum SyntaxHighlighter {
    static func highlight(_ storage: NSTextStorage, language: CodeLanguage?, font: NSFont) {
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: whole)
        if let language {
            let text = storage.string as NSString
            for match in pattern(for: language).matches(in: storage.string, range: whole) {
                if let color = color(of: match, in: text, language: language) {
                    storage.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
        }
        storage.endEditing()
    }

    private static func color(of match: NSTextCheckingResult, in text: NSString, language: CodeLanguage) -> NSColor? {
        func has(_ group: String) -> Bool { match.range(withName: group).location != NSNotFound }
        if has("comment") { return Palette.comment }
        if has("directive") { return Palette.control }
        if has("key") { return Palette.key }
        if has("string") { return Palette.string }
        if has("decorator") { return Palette.function }
        if has("variable") { return Palette.key }
        if has("number") { return Palette.number }
        guard has("word") else { return nil }

        let word = text.substring(with: match.range)
        let lookup = language.caseInsensitive ? word.lowercased() : word
        if language.keywords.contains(lookup) {
            return controlFlow.contains(word.lowercased()) ? Palette.control : Palette.keyword
        }
        if language.literals.contains(lookup) { return Palette.keyword }
        if isFollowedByParenthesis(match.range, in: text) { return Palette.function }
        if !language.caseInsensitive, let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first),
           word.contains(where: \.isLowercase) {
            return Palette.type
        }
        return nil
    }

    private static func isFollowedByParenthesis(_ range: NSRange, in text: NSString) -> Bool {
        var index = NSMaxRange(range)
        while index < text.length, text.character(at: index) == 0x20 { index += 1 }
        return index < text.length && text.character(at: index) == 0x28 // "("
    }

    /// Keywords VS Code colors as control flow (pink) rather than declarations (blue).
    private static let controlFlow: Set<String> = [
        "if", "else", "elif", "for", "foreach", "while", "do", "return", "break", "continue", "switch", "case",
        "default", "try", "catch", "except", "finally", "throw", "throws", "raise", "import", "from", "export",
        "yield", "await", "with", "pass", "goto", "guard", "defer", "match", "when", "loop", "repeat", "then",
        "fi", "done", "esac", "until", "using", "package", "use", "include",
    ]

    // MARK: - Patterns

    private static var cache: [String: NSRegularExpression] = [:]

    private static func pattern(for language: CodeLanguage) -> NSRegularExpression {
        if let cached = cache[language.id] { return cached }
        var comment: [String] = []
        if language.blockComments { comment.append(#"/\*[\s\S]*?(?:\*/|\z)"#) }
        for prefix in language.lineComments {
            // "#" must not be part of "$#" or "${#var}" in shell.
            let guardPrefix = prefix == "#" ? #"(?<![$\{\w])"# : ""
            comment.append(guardPrefix + NSRegularExpression.escapedPattern(for: prefix) + #"[^\n]*"#)
        }

        var string: [String] = []
        if language.tripleQuotes { string += [#""""[\s\S]*?(?:"""|\z)"#, #"'''[\s\S]*?(?:'''|\z)"#] }
        if language.backtickStrings { string.append(#"`(?:[^`\\]|\\[\s\S])*(?:`|\z)"#) }
        string.append(#""(?:[^"\\\n]|\\.)*"?"#) // unterminated: colored to the end of the line, like editors do
        // Closing quote required: Rust lifetimes ('a) and apostrophes in comments-free text stay plain.
        if language.singleQuoteStrings { string.append(#"'(?:[^'\\\n]|\\.)*'"#) }

        var parts: [String] = []
        if !comment.isEmpty { parts.append("(?<comment>\(comment.joined(separator: "|")))") }
        if language.directives { parts.append(#"(?<directive>(?m:^[ \t]*#[ \t]*\w+))"#) }
        if language.keys {
            parts.append(#"(?<key>"(?:[^"\\\n]|\\.)*"(?=[ \t]*:)|(?m:^[ \t]*(?:-[ \t]+)?[\w.-]+(?=[ \t]*:(?:[ \t]|$))))"#)
        }
        parts.append("(?<string>\(string.joined(separator: "|")))")
        if language.decorators { parts.append(#"(?<decorator>@[A-Za-z_][\w.]*)"#) }
        if language.shellVariables { parts.append(#"(?<variable>\$(?:\{[^}\n]*\}?|[A-Za-z_]\w*|[0-9@#?*!$-]))"#) }
        parts.append(#"(?<number>(?<![\w.])(?:0[xX][\da-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)[A-Za-z]*)"#)
        parts.append(#"(?<word>[A-Za-z_][\w]*)"#)

        let regex = try! NSRegularExpression(pattern: parts.joined(separator: "|"))
        cache[language.id] = regex
        return regex
    }

    // MARK: - Colors

    private enum Palette {
        static let keyword = color(dark: 0x569CD6, light: 0x0000FF)
        static let control = color(dark: 0xC586C0, light: 0xAF00DB)
        static let string = color(dark: 0xCE9178, light: 0xA31515)
        static let comment = color(dark: 0x6A9955, light: 0x008000)
        static let number = color(dark: 0xB5CEA8, light: 0x098658)
        static let type = color(dark: 0x4EC9B0, light: 0x267F99)
        static let function = color(dark: 0xDCDCAA, light: 0x795E26)
        static let key = color(dark: 0x9CDCFE, light: 0x0451A5)

        private static func color(dark: UInt32, light: UInt32) -> NSColor {
            NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                               green: CGFloat((hex >> 8) & 0xFF) / 255,
                               blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
        }
    }
}

// MARK: - Languages

private func words(_ list: String) -> Set<String> {
    Set(list.split(separator: " ").map(String.init))
}

extension CodeLanguage {
    static let python = CodeLanguage(
        id: "python", name: "Python", aliases: ["py"],
        keywords: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self"),
        literals: words("True False None"),
        lineComments: ["#"], tripleQuotes: true, decorators: true)

    static let java = CodeLanguage(
        id: "java", name: "Java",
        keywords: words("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while var record yield"),
        literals: words("true false null"),
        lineComments: ["//"], blockComments: true, decorators: true)

    private static let javascriptKeywords = words("async await break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new of return static super switch this throw try typeof var void while with yield get set")

    static let javascript = CodeLanguage(
        id: "javascript", name: "JavaScript", aliases: ["js", "jsx", "node"],
        keywords: javascriptKeywords,
        literals: words("true false null undefined NaN"),
        lineComments: ["//"], blockComments: true, backtickStrings: true)

    static let typescript = CodeLanguage(
        id: "typescript", name: "TypeScript", aliases: ["ts", "tsx"],
        keywords: javascriptKeywords.union(words("type interface enum implements private protected public readonly declare namespace abstract as keyof any number string boolean never unknown")),
        literals: words("true false null undefined NaN"),
        lineComments: ["//"], blockComments: true, backtickStrings: true, decorators: true)

    static let kotlin = CodeLanguage(
        id: "kotlin", name: "Kotlin", aliases: ["kt", "kts"],
        keywords: words("as break class continue do else for fun if in interface is object package return super this throw try typealias typeof val var when while by catch constructor finally get set import init override private protected public internal open data sealed suspend companion lateinit const enum abstract inline"),
        literals: words("true false null"),
        lineComments: ["//"], blockComments: true, tripleQuotes: true, decorators: true)

    static let swift = CodeLanguage(
        id: "swift", name: "Swift",
        keywords: words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private protocol public rethrows static struct subscript typealias var break case continue default defer do else fallthrough for guard if in repeat return switch where while as catch is self Self super throw throws try async await some any final lazy mutating override weak"),
        literals: words("true false nil"),
        lineComments: ["//"], blockComments: true, tripleQuotes: true, singleQuoteStrings: false, decorators: true)

    private static let cKeywords = words("auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool")

    static let c = CodeLanguage(
        id: "c", name: "C", aliases: ["h"],
        keywords: cKeywords,
        literals: words("true false NULL"),
        lineComments: ["//"], blockComments: true, directives: true)

    static let cpp = CodeLanguage(
        id: "cpp", name: "C++", aliases: ["c++", "cc", "hpp", "cxx"],
        keywords: cKeywords.union(words("class namespace template typename public private protected virtual override new delete this using try catch throw auto constexpr friend operator explicit mutable noexcept static_cast dynamic_cast reinterpret_cast const_cast")),
        literals: words("true false nullptr NULL"),
        lineComments: ["//"], blockComments: true, directives: true)

    static let csharp = CodeLanguage(
        id: "csharp", name: "C#", aliases: ["cs", "c#"],
        keywords: words("abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw try typeof uint ulong unchecked unsafe ushort using virtual void volatile while var async await get set record"),
        literals: words("true false null"),
        lineComments: ["//"], blockComments: true)

    static let go = CodeLanguage(
        id: "go", name: "Go", aliases: ["golang"],
        keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float32 float64 string bool byte rune error any"),
        literals: words("true false nil iota"),
        lineComments: ["//"], blockComments: true, backtickStrings: true)

    static let rust = CodeLanguage(
        id: "rust", name: "Rust", aliases: ["rs"],
        keywords: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
        literals: words("true false"),
        lineComments: ["//"], blockComments: true)

    static let sql = CodeLanguage(
        id: "sql", name: "SQL",
        keywords: words("select from where insert into values update set delete create table drop alter add column join left right inner outer full cross on as and or not in is null like between group by order having limit offset distinct union all case when then else end primary key foreign references index view default exists count sum avg min max int integer bigint varchar char text boolean date timestamp asc desc with returning unique check constraint"),
        literals: words("true false"),
        lineComments: ["--"], blockComments: true, caseInsensitive: true)

    static let shell = CodeLanguage(
        id: "shell", name: "Shell", aliases: ["sh", "bash", "zsh", "console", "terminal"],
        keywords: words("if then else elif fi for while until do done case esac in function return break continue local export readonly declare source alias echo exit set unset shift cd sudo"),
        literals: words("true false"),
        lineComments: ["#"], shellVariables: true)

    static let json = CodeLanguage(
        id: "json", name: "JSON",
        literals: words("true false null"),
        singleQuoteStrings: false, keys: true)

    static let yaml = CodeLanguage(
        id: "yaml", name: "YAML", aliases: ["yml"],
        literals: words("true false null yes no on off"),
        lineComments: ["#"], keys: true)
}
