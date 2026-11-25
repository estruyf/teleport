import Foundation

/// Logs to stderr and to `~/.teleport/<role>.log`.
public enum Log {
    nonisolated(unsafe) static var file: LogFile?
    static let lock = NSLock()
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Rotate at 10 MB, keeping three old files.
    static let maxBytes: UInt64 = 10 * 1024 * 1024

    public static func setup(role: String) {
        file = LogFile(name: "\(role).log")
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

    /// The timestamp every log line starts with.
    public static func timestamp(_ date: Date = Date()) -> String { formatter.string(from: date) }

    static func write(_ level: String, _ message: String) {
        let line = "\(timestamp()) [\(level)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
        file?.write(line)
    }
}

/// An append-only file in `~/.teleport` that rotates like the logs: at 10 MB, keeping three old files.
///
/// It is checked on every write as well as at launch: a host runs for weeks, and `stats.log`
/// grows by a line a second for every open portal.
public final class LogFile: @unchecked Sendable {
    public let url: URL
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private let lock = NSLock()

    public init(name: String) {
        url = TeleportConfig.directory.appendingPathComponent(name)
        lock.lock()
        defer { lock.unlock() }
        open()
    }

    private func open() {
        try? FileManager.default.createDirectory(at: TeleportConfig.directory, withIntermediateDirectories: true)
        Log.rotateIfNeeded(url)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = handle?.seekToEndOfFile() ?? 0
    }

    public func write(_ line: String) {
        let data = Data(line.utf8)
        lock.lock()
        defer { lock.unlock() }
        handle?.write(data)
        size += UInt64(data.count)
        if size > Log.maxBytes {
            try? handle?.close()
            open()
        }
    }
}
