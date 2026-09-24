import Foundation

/// JSON file store whose writes survive app crashes and sudden power loss:
/// write temp file → F_FULLFSYNC → atomic rename → sync the directory entry.
/// A crash at any point leaves either the previous or the new file intact, never a partial one.
final class DurableStore {
    let url: URL
    private let queue = DispatchQueue(label: "Quotepad.DurableStore")
    private var lastWritten: Data? // only touched on `queue`

    init(url: URL) {
        self.url = url
    }

    func loadData() -> Data? {
        try? Data(contentsOf: url)
    }

    /// Moves an unreadable file aside so the next save can't overwrite what might be recoverable.
    func quarantineCorruptFile() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "\(url.deletingPathExtension().lastPathComponent).corrupt-\(stamp).\(url.pathExtension)"
        try? FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(name))
    }

    /// Queues a durable write; identical consecutive payloads are skipped.
    func save(_ data: Data) {
        queue.async { [self] in
            guard data != lastWritten else { return }
            do {
                try writeDurably(data)
                lastWritten = data
            } catch {
                NSLog("Quotepad: save failed: \(error)")
            }
        }
    }

    /// Blocks until every queued write has hit the disk.
    func flush() {
        queue.sync {}
    }

    private func writeDurably(_ data: Data) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp")

        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw currentPOSIXError() }
        do {
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw currentPOSIXError()
                    }
                    offset += written
                }
            }
            // Plain fsync on macOS doesn't flush the drive's own write cache; F_FULLFSYNC does.
            if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        } catch {
            close(fd)
            throw error
        }
        close(fd)

        guard rename(tmp.path, url.path) == 0 else { throw currentPOSIXError() }

        let dirFD = open(dir.path, O_RDONLY)
        if dirFD >= 0 {
            if fcntl(dirFD, F_FULLFSYNC) != 0 { fsync(dirFD) }
            close(dirFD)
        }
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
