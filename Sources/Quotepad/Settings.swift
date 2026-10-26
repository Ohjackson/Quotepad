import Cocoa
import ServiceManagement

enum ThemeMode: Int, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "시스템"
        case .light: return "라이트"
        case .dark: return "다크"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum EditorFont: Int, CaseIterable {
    case system, monospaced, serif

    var title: String {
        switch self {
        case .system: return "시스템"
        case .monospaced: return "고정폭"
        case .serif: return "세리프"
        }
    }

    func font(size: CGFloat) -> NSFont {
        switch self {
        case .system:
            return .systemFont(ofSize: size)
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .serif:
            let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
        }
    }
}

/// How numbers in nested ordered lists are shown. The note always stores plain Markdown ("1.").
enum ListNumbering: Int, CaseIterable {
    case outline, letters, plain

    var title: String {
        switch self {
        case .outline: return "3.1 · 3.2"
        case .letters: return "a · b · c"
        case .plain: return "1 · 2 · 3"
        }
    }
}

enum OpenPosition: Int, CaseIterable {
    case topCenter, lastPosition

    var title: String {
        switch self {
        case .topCenter: return "화면 위쪽 가운데"
        case .lastPosition: return "마지막 위치"
        }
    }
}

struct BackgroundTint {
    let id: String
    let name: String
    let color: NSColor? // nil = plain translucent material

    static let all: [BackgroundTint] = [
        BackgroundTint(id: "none", name: "기본", color: nil),
        BackgroundTint(id: "yellow", name: "노랑", color: .dynamic(light: 0xFFF1A8, dark: 0x4D4318)),
        BackgroundTint(id: "green", name: "초록", color: .dynamic(light: 0xD3F2DB, dark: 0x1E3D29)),
        BackgroundTint(id: "blue", name: "파랑", color: .dynamic(light: 0xD4E6FF, dark: 0x1B2D47)),
        BackgroundTint(id: "purple", name: "보라", color: .dynamic(light: 0xE6DBFF, dark: 0x302447)),
        BackgroundTint(id: "pink", name: "분홍", color: .dynamic(light: 0xFFDCE7, dark: 0x472131)),
        BackgroundTint(id: "graphite", name: "그래파이트", color: .dynamic(light: 0xE9E9EB, dark: 0x242426)),
    ]

    static func find(_ id: String) -> BackgroundTint {
        all.first { $0.id == id } ?? all[0]
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

/// User preferences in UserDefaults. Every setter posts `didChange` so the UI re-applies live.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("Quotepad.settingsDidChange")

    private let defaults = UserDefaults.standard

    private enum Key {
        static let theme = "theme"
        static let tint = "backgroundTint"
        static let opacity = "backgroundOpacity"
        static let fontSize = "fontSize"
        static let editorFont = "editorFont"
        static let listNumbering = "listNumbering"
        static let codeShortcuts = "codeShortcuts"
        static let snippetShortcuts = "snippetShortcuts"
        static let spellCheck = "spellCheck"
        static let hideOnFocusLoss = "hideOnFocusLoss"
        static let openPosition = "openPosition"
        static let lastFrame = "lastFrame"
        static let resettable = [theme, tint, opacity, fontSize, editorFont, listNumbering, codeShortcuts, snippetShortcuts, spellCheck, hideOnFocusLoss, openPosition]
    }

    static let fontSizeRange: ClosedRange<Double> = 11...24
    static let opacityRange: ClosedRange<Double> = 0.4...1.0

    private init() {
        defaults.register(defaults: [
            Key.theme: ThemeMode.system.rawValue,
            Key.tint: "none",
            Key.opacity: 1.0,
            Key.fontSize: 14.0,
            Key.editorFont: EditorFont.system.rawValue,
            Key.listNumbering: ListNumbering.outline.rawValue,
            Key.codeShortcuts: "/ㅋㄷ",
            Key.snippetShortcuts: "",
            Key.spellCheck: false,
            Key.hideOnFocusLoss: true,
            Key.openPosition: OpenPosition.topCenter.rawValue,
        ])
    }

    var theme: ThemeMode {
        get { ThemeMode(rawValue: defaults.integer(forKey: Key.theme)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.theme); changed() }
    }

    var tint: BackgroundTint {
        get { BackgroundTint.find(defaults.string(forKey: Key.tint) ?? "none") }
        set { defaults.set(newValue.id, forKey: Key.tint); changed() }
    }

    var opacity: Double {
        get { defaults.double(forKey: Key.opacity).clamped(to: Self.opacityRange) }
        set { defaults.set(newValue.clamped(to: Self.opacityRange), forKey: Key.opacity); changed() }
    }

    var fontSize: Double {
        get { defaults.double(forKey: Key.fontSize).clamped(to: Self.fontSizeRange) }
        set { defaults.set(newValue.clamped(to: Self.fontSizeRange), forKey: Key.fontSize); changed() }
    }

    var editorFont: EditorFont {
        get { EditorFont(rawValue: defaults.integer(forKey: Key.editorFont)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.editorFont); changed() }
    }

    var listNumbering: ListNumbering {
        get { ListNumbering(rawValue: defaults.integer(forKey: Key.listNumbering)) ?? .outline }
        set { defaults.set(newValue.rawValue, forKey: Key.listNumbering); changed() }
    }

    /// Extra words that make a code block / a one-line box, as typed in Settings ("/c, /코").
    var codeShortcuts: String {
        get { defaults.string(forKey: Key.codeShortcuts) ?? "" }
        set { defaults.set(newValue, forKey: Key.codeShortcuts); changed() }
    }

    var snippetShortcuts: String {
        get { defaults.string(forKey: Key.snippetShortcuts) ?? "" }
        set { defaults.set(newValue, forKey: Key.snippetShortcuts); changed() }
    }

    /// "/c, 코 /x" → ["/c", "/코", "/x"]: split on commas and spaces, "/" added where missing, lowercased.
    static func shortcutSet(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { word in
            let word = word.lowercased()
            return word.hasPrefix("/") ? word : "/" + word
        }.filter { $0.count > 1 })
    }

    var spellCheck: Bool {
        get { defaults.bool(forKey: Key.spellCheck) }
        set { defaults.set(newValue, forKey: Key.spellCheck); changed() }
    }

    var hideOnFocusLoss: Bool {
        get { defaults.bool(forKey: Key.hideOnFocusLoss) }
        set { defaults.set(newValue, forKey: Key.hideOnFocusLoss); changed() }
    }

    var openPosition: OpenPosition {
        get { OpenPosition(rawValue: defaults.integer(forKey: Key.openPosition)) ?? .topCenter }
        set { defaults.set(newValue.rawValue, forKey: Key.openPosition); changed() }
    }

    /// Panel frame from the last move/resize. Size is always restored; origin only for `.lastPosition`.
    var lastFrame: NSRect? {
        get { defaults.string(forKey: Key.lastFrame).map(NSRectFromString) }
        set { defaults.set(newValue.map(NSStringFromRect), forKey: Key.lastFrame) }
    }

    func resetToDefaults() {
        Key.resettable.forEach(defaults.removeObject(forKey:))
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

enum LoginItem {
    /// Login items need a real .app bundle; a bare `swift build` binary has no bundle id.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message to show the user, or nil on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            if service.status != .requiresApproval { return error.localizedDescription }
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        return nil
    }
}

func showAlert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
}
