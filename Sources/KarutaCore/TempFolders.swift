import Foundation

/// Folders for files handed to other apps (drag & drop, sharing). Each file gets a folder of its own, so it
/// keeps the name from the template instead of picking up " (2)", " (3)"… from earlier drags.
public enum TempFolders {
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
