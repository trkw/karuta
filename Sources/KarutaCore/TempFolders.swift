import Foundation

/// Folders for files handed to other apps (drag & drop, sharing). Each file gets a folder of its own, so it
/// keeps the name from the template instead of picking up " (2)", " (3)"… from earlier drags.
public enum TempFolders {
    /// The temp folders Karuta writes to, each under the app's folder in the system temp directory.
    public enum Kind: String, Sendable {
        /// "Copy as a file": only the latest copy is kept.
        case clipboard = "Clipboard"
        /// Drag & drop and sharing: one folder per file, see `fresh(in:maxAge:now:)`.
        case drag = "Drag"
        /// Recordings while they're in Quick Access.
        case recordings = "Recordings"
    }

    /// The app's folder name under the temp folder, Application Support and Caches. The bench copy
    /// (scripts/make-bench-copy.sh) uses its own so it never touches the real app's files.
    public static func folderName(bench: Bool) -> String {
        bench ? "Karuta Bench" : "Karuta"
    }

    /// Where files of `kind` go, e.g. `$TMPDIR/Karuta/Clipboard`.
    public static func directory(_ kind: Kind, folderName: String,
                                 base: URL = FileManager.default.temporaryDirectory) -> URL {
        base.appendingPathComponent("\(folderName)/\(kind.rawValue)", isDirectory: true)
    }

    /// A new empty folder inside `parent`. Folders there older than `maxAge` are removed first; recent ones
    /// stay, since the app the file went to may still be reading it.
    public static func fresh(in parent: URL, maxAge: TimeInterval = 60 * 60, now: Date = Date()) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let old = (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in old {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > maxAge { try? fileManager.removeItem(at: url) }
        }
        let folder = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
}
