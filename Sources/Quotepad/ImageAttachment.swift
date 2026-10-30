import Cocoa
import UniformTypeIdentifiers

// Pictures in notes. The files live in the data folder's `images/`; the note only holds a Markdown
// image line pointing at one, so notes stay plain text. A resized picture keeps its width in the
// alt text, as Obsidian does:
//
//     ![](images/5F1C…E2.png)        ![|320](images/5F1C…E2.png)

let imagesDir: URL = {
    let dir = appSupportDir.appendingPathComponent("images", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

protocol ImageBlockHost: AnyObject {
    /// One click: select the picture (a ring around it, not a text highlight).
    func imageBlockClicked(_ attachment: ImageAttachment)
    /// The picture is being resized: its line's height follows.
    func imageBlockDidResize(_ attachment: ImageAttachment)
    /// A resize ended: the new width is saved.
    func imageBlockDidChange(_ attachment: ImageAttachment)
}

/// A picture as a block, like Notion: the whole line, the picture centered in it.
final class ImageAttachment: NSTextAttachment {
    static let maxHeight: CGFloat = 400
    static let verticalMargin: CGFloat = 6
    static let minimumWidth: CGFloat = 60
    /// Room kept on each side so the selection ring around a full-width picture isn't cut off.
    static let ringInset: CGFloat = 4

    /// File name inside `imagesDir`.
    let fileName: String
    weak var host: ImageBlockHost?
    weak var liveView: ImageBlockView?
    var isSelected = false { didSet { liveView?.selectionChanged() } }
    /// The width the user resized it to; nil shows it at its natural size (fitted to the line).
    var width: CGFloat?

    var fileURL: URL { imagesDir.appendingPathComponent(fileName) }
    /// The picture itself. `image` stays a blank 1×1: TextKit draws `image` under the view, stretched to the whole line.
    let picture: NSImage?

    init(fileName: String, width: CGFloat? = nil) {
        self.fileName = fileName
        self.width = width
        picture = NSImage(contentsOf: imagesDir.appendingPathComponent(fileName))
            ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "사진 없음")
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = NSImage(size: NSSize(width: 1, height: 1))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The picture's size in a line `lineWidth` wide, always in its own proportions. Never larger than
    /// the picture itself or the line (less the ring's room); unless resized by hand, also no taller than `maxHeight`.
    func pictureSize(fitting lineWidth: CGFloat) -> CGSize {
        guard let size = picture?.size, size.width > 0, size.height > 0 else { return CGSize(width: 32, height: 32) }
        let room = max(1, lineWidth - Self.ringInset * 2)
        var scale = min(1, room / size.width)
        if let width {
            scale = min(scale, max(Self.minimumWidth, width) / size.width)
        } else {
            scale = min(scale, Self.maxHeight / size.height)
        }
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// The widest it can be resized to in a line `lineWidth` wide: the picture's own width, or the line's.
    func maximumWidth(fitting lineWidth: CGFloat) -> CGFloat {
        let room = lineWidth - Self.ringInset * 2
        return min(picture?.size.width ?? room, room)
    }

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = ImageBlockViewProvider(textAttachment: self, parentView: parentView,
                                              textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

final class ImageBlockViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let attachment = textAttachment as? ImageAttachment else { return }
        let view = ImageBlockView(attachment: attachment)
        attachment.liveView = view
        self.view = view
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        guard let attachment = textAttachment as? ImageAttachment else { return .zero }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let width = max(40, proposedLineFragment.width - padding * 2)
        let height = attachment.pictureSize(fitting: width).height + ImageAttachment.verticalMargin * 2
        return CGRect(x: 0, y: 0, width: width, height: height)
    }
}

final class ImageBlockView: NSView {
    let attachment: ImageAttachment
    /// Width of the side handles' grab area.
    private static let handleReach: CGFloat = 10
    /// While a handle is dragged: the picture's center, which stays put (the picture is centered).
    private var resizingCenterX: CGFloat?

    init(attachment: ImageAttachment) {
        self.attachment = attachment
        super.init(frame: .zero)
        setAccessibilityRole(.image)
        setAccessibilityLabel("사진")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var pictureRect: NSRect {
        let size = attachment.pictureSize(fitting: bounds.width)
        return NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ImageAttachment.verticalMargin,
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = pictureRect
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
        attachment.picture?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        if attachment.isSelected {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 8, yRadius: 8)
            ring.lineWidth = 3
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            ring.stroke()
            // Resize handles, like Notion: a short bar inside each side edge.
            for handle in handleBars(for: rect) {
                NSColor.black.withAlphaComponent(0.35).setStroke()
                let outline = NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3)
                outline.lineWidth = 1
                NSColor.white.withAlphaComponent(0.9).setFill()
                outline.fill()
                outline.stroke()
            }
        }
    }

    private func handleBars(for rect: NSRect) -> [NSRect] {
        let height = min(40, rect.height * 0.4)
        let y = rect.midY - height / 2
        return [NSRect(x: rect.minX + 6, y: y, width: 6, height: height),
                NSRect(x: rect.maxX - 12, y: y, width: 6, height: height)]
    }

    /// Where a press starts a resize: near the left or right edge of the selected picture.
    private func handleAreas() -> [NSRect] {
        guard attachment.isSelected else { return [] }
        let rect = pictureRect
        return [NSRect(x: rect.minX - Self.handleReach / 2, y: rect.minY, width: Self.handleReach * 1.5, height: rect.height),
                NSRect(x: rect.maxX - Self.handleReach, y: rect.minY, width: Self.handleReach * 1.5, height: rect.height)]
    }

    func selectionChanged() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        for area in handleAreas() { addCursorRect(area, cursor: .resizeLeftRight) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if handleAreas().contains(where: { $0.contains(point) }) {
            resizingCenterX = pictureRect.midX
            return
        }
        if event.clickCount == 2 {
            NSWorkspace.shared.open(attachment.fileURL) // a closer look in Preview
        } else {
            attachment.host?.imageBlockClicked(attachment)
        }
    }

    /// Dragging either handle sets the width; the height follows the picture's proportions.
    override func mouseDragged(with event: NSEvent) {
        guard let centerX = resizingCenterX else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let maximum = attachment.maximumWidth(fitting: bounds.width)
        let width = min(maximum, max(ImageAttachment.minimumWidth, (abs(x - centerX) * 2).rounded()))
        guard width != attachment.pictureSize(fitting: bounds.width).width else { return }
        attachment.width = width
        needsDisplay = true
        attachment.host?.imageBlockDidResize(attachment)
    }

    override func mouseUp(with event: NSEvent) {
        guard resizingCenterX != nil else { return }
        resizingCenterX = nil
        window?.invalidateCursorRects(for: self)
        attachment.host?.imageBlockDidChange(attachment)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

enum ImageStore {
    /// Markdown image lines that point into `images/`. Group 1: the width from "|320" in the alt
    /// text, if any; group 2: the file name.
    static let reference = try! NSRegularExpression(pattern: #"!\[[^\]\n|]*(?:\|(\d+))?\]\(images/([^)\s/]+)\)"#)

    static func markdown(for picture: ImageAttachment) -> String {
        let width = picture.width.map { "|\(Int($0))" } ?? ""
        return "![\(width)](images/\(picture.fileName))"
    }

    /// Pictures on a pasteboard (copied or dragged images, or image files), saved into `imagesDir`.
    /// Text wins: a pasteboard that also carries text (e.g. from a word processor) isn't treated as pictures.
    static func importImages(from pboard: NSPasteboard) -> [String] {
        let files = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let imageFiles = files.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !imageFiles.isEmpty {
            return imageFiles.compactMap { url in
                (try? Data(contentsOf: url)).flatMap { save($0, extension: url.pathExtension.lowercased()) }
            }
        }
        if let text = pboard.string(forType: .string), !text.isEmpty, URL(string: text)?.scheme == nil { return [] }
        if let png = pboard.data(forType: .png) { return save(png, extension: "png").map { [$0] } ?? [] }
        if let image = NSImage(pasteboard: pboard), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return save(png, extension: "png").map { [$0] } ?? []
        }
        return []
    }

    private static func save(_ data: Data, extension ext: String) -> String? {
        let name = UUID().uuidString + "." + (ext.isEmpty ? "png" : ext)
        do {
            try data.write(to: imagesDir.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// Deletes pictures no note points to any more. Run at launch only, so a picture deleted from a note
    /// can still come back with undo while the app is running.
    static func removeUnused(referencedBy notes: [String]) {
        var used = Set<String>()
        for note in notes {
            for match in reference.matches(in: note, range: NSRange(location: 0, length: (note as NSString).length)) {
                used.insert((note as NSString).substring(with: match.range(at: 2)))
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path)) ?? []
        for file in files where !used.contains(file) && !file.hasPrefix(".") {
            try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(file))
        }
    }
}
