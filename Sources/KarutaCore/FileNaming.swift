import Foundation

/// How capture files are named: the template from Settings, and " (2)", " (3)"… when a name is taken.
/// Kept free of AppKit and settings so `karuta-check` can test it.
public enum FileNaming {
    /// `{date}` → 2026-10-31, `{time}` → 13.05.09, `{app}` → the app in front at capture time (empty when unknown).
    /// "/" and ":" can't be in a file name; the spaces an empty `{app}` leaves are collapsed. Never empty.
    public static func baseName(template: String, app: String?, date: Date, timeZone: TimeZone = .current) -> String {
        func formatted(_ format: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            return formatter.string(from: date)
        }
        let name = template
            .replacingOccurrences(of: "{date}", with: formatted("yyyy-MM-dd"))
            .replacingOccurrences(of: "{time}", with: formatted("HH.mm.ss"))
            .replacingOccurrences(of: "{app}", with: app ?? "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return name.isEmpty ? "Karuta" : name
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
