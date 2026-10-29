import Foundation

/// Logs to stderr and to `~/.teleport/<role>.log`.
public enum Log {
    nonisolated(unsafe) static var handle: FileHandle?
    static let lock = NSLock()
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Rotate at 10 MB, keeping three old files.
    static let maxBytes: UInt64 = 10 * 1024 * 1024

    public static func setup(role: String) {
        try? FileManager.default.createDirectory(at: TeleportConfig.directory, withIntermediateDirectories: true)
        let url = TeleportConfig.directory.appendingPathComponent("\(role).log")
        rotateIfNeeded(url)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    static func rotateIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64), size > maxBytes else { return }
        for index in stride(from: 3, through: 1, by: -1) {
            let older = url.appendingPathExtension("\(index)")
            let newer = index == 1 ? url : url.appendingPathExtension("\(index - 1)")
            try? fm.removeItem(at: older)
            try? fm.moveItem(at: newer, to: older)
        }
    }

    public static func info(_ message: String) { write("info", message) }
    public static func warn(_ message: String) { write("warn", message) }
    public static func error(_ message: String) { write("error", message) }

    static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
        handle?.write(Data(line.utf8))
    }
}
