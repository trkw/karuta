import Foundation

/// How capture files are named: the template from Settings, and " (2)", " (3)"… when a name is taken.
/// Kept free of AppKit and settings so `karuta-check` can test it.
public enum FileNaming {
    /// `{date}` → 2026-10-31, `{time}` → 13.05.09, `{app}` → the app in front at capture time (empty when unknown).
    /// "/" and ":" can't be in a file name; the spaces an empty `{app}` leaves are collapsed. Never empty.
    public static func baseName(template: String, app: String?, date: Date, timeZone: TimeZone = .current) -> String {
        func formatted(_ format: String) -> String { Formatters.string(from: date, format: format, timeZone: timeZone) }
        let name = template
            .replacingOccurrences(of: "{date}", with: formatted("yyyy-MM-dd"))
            .replacingOccurrences(of: "{time}", with: formatted("HH.mm.ss"))
            .replacingOccurrences(of: "{app}", with: app ?? "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return name.isEmpty ? "Karuta" : name
    }

    /// The extensions the image formats use (and "jpeg", which people type by hand).
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]

    /// `name` with its image extension swapped for `ext` (the Save As panel's 形式 menu). Only a known image
    /// extension is removed, so the dots of `{time}` (13.05.09) or "v1.2" stay when the extension isn't shown.
    public static func replacingImageExtension(of name: String, with ext: String) -> String {
        let current = (name as NSString).pathExtension
        let base = imageExtensions.contains(current.lowercased()) ? (name as NSString).deletingPathExtension : name
        return "\(base).\(ext)"
    }

    /// `<base>.<ext>` in `directory`, or `<base> (2).<ext>`, `<base> (3).<ext>`… if that exists.
    public static func uniqueURL(in directory: URL, base: String, extension ext: String,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var url = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while exists(url) {
            url = directory.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}

/// DateFormatter is costly to create, so one is kept per format and time zone (refactoring K8).
/// DateFormatter isn't safe to share across threads, so the cache and each use are behind a lock.
private enum Formatters {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    static func string(from date: Date, format: String, timeZone: TimeZone) -> String {
        lock.lock()
        defer { lock.unlock() }
        let key = format + "\u{0}" + timeZone.identifier
        let formatter: DateFormatter
        if let cached = cache[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            cache[key] = formatter
        }
        return formatter.string(from: date)
    }
}
