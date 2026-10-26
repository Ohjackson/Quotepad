import Cocoa
import UniformTypeIdentifiers

// Pictures in notes. The files live in the data folder's `images/`; the note only holds a Markdown
// image line pointing at one, so notes stay plain text:
//
//     ![](images/5F1C…E2.png)

let imagesDir: URL = {
    let dir = appSupportDir.appendingPathComponent("images", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

protocol ImageBlockHost: AnyObject {
    /// One click: select the picture (a ring around it, not a text highlight).
    func imageBlockClicked(_ attachment: ImageAttachment)
}

/// A picture as a block, like Notion: the whole line, the picture centered in it.
final class ImageAttachment: NSTextAttachment {
    static let maxHeight: CGFloat = 400
    static let verticalMargin: CGFloat = 6

    /// File name inside `imagesDir`.
    let fileName: String
    weak var host: ImageBlockHost?
    weak var liveView: ImageBlockView?
    var isSelected = false { didSet { liveView?.needsDisplay = true } }

    var fileURL: URL { imagesDir.appendingPathComponent(fileName) }
    /// The picture itself. `image` stays a blank 1×1: TextKit draws `image` under the view, stretched to the whole line.
    let picture: NSImage?

    init(fileName: String) {
        self.fileName = fileName
        picture = NSImage(contentsOf: imagesDir.appendingPathComponent(fileName))
            ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "사진 없음")
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = NSImage(size: NSSize(width: 1, height: 1))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The picture's size in a line `width` wide: never larger than the picture itself nor taller than `maxHeight`.
    func pictureSize(fitting width: CGFloat) -> CGSize {
        guard let size = picture?.size, size.width > 0, size.height > 0 else { return CGSize(width: 32, height: 32) }
        let scale = min(1, width / size.width, Self.maxHeight / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
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
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            NSWorkspace.shared.open(attachment.fileURL) // a closer look in Preview
        } else {
            attachment.host?.imageBlockClicked(attachment)
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

enum ImageStore {
    /// Markdown image lines that point into `images/`.
    static let reference = try! NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(images/([^)\s/]+)\)"#)

    static func markdown(for fileName: String) -> String { "![](images/\(fileName))" }

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
                used.insert((note as NSString).substring(with: match.range(at: 1)))
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path)) ?? []
        for file in files where !used.contains(file) && !file.hasPrefix(".") {
            try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(file))
        }
    }
}
