import Foundation

/// Reads the app's name out of a notification banner's accessibility description.
///
/// Notification Center describes a banner as its parts joined with ", ": the app's name, then the
/// title, subtitle and body that are not empty. Any of them can hold a comma themselves, so the
/// name is what comes before the known texts, not the first comma-separated part.
public enum BannerText {
    public static func appName(description: String, title: String, subtitle: String, body: String) -> String? {
        let texts = [title, subtitle, body].filter { !$0.isEmpty }
        let rest = texts.joined(separator: ", ")
        if !rest.isEmpty, description.hasSuffix(", " + rest) {
            return nonEmpty(String(description.dropLast(rest.count + 2)))
        }
        // The texts were cut short or put differently: everything before the first of them.
        if let first = texts.first, let range = description.range(of: ", " + first) {
            return nonEmpty(String(description[..<range.lowerBound]))
        }
        return nonEmpty(description.components(separatedBy: ", ").first ?? "")
    }

    /// Whether `name` from a banner is one of an app's names, ignoring case and diacritics.
    public static func matches(_ name: String, any names: [String]) -> Bool {
        names.contains { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
