import Foundation

/// File names that arrive from the other Mac.
enum FileNames {
    /// Only a plain file name: never "..", a hidden file, or a path.
    static func safe(_ name: String?) -> String {
        var name = (name ?? "").components(separatedBy: "/").last?.trimmingCharacters(in: .whitespaces) ?? ""
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "file" : name
    }

    /// "name.ext", or "name 2.ext" and so on when that is taken, like Finder does.
    static func freeURL(in folder: URL, for name: String) -> URL {
        let first = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 2 ... 999 {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
}
