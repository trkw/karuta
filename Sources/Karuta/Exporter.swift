import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Exporter {
    /// PNG with DPI metadata so Retina captures open at their point size.
    static func pngData(_ shot: Shot) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        let dpi = 72 * shot.scale
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(destination, shot.image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func copy(_ shot: Shot) {
        guard let data = pngData(shot) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    @discardableResult
    static func save(_ shot: Shot, in directory: URL = desktop) throws -> URL {
        guard let data = pngData(shot) else { throw CocoaError(.fileWriteUnknown) }
        let url = uniqueURL(in: directory)
        try data.write(to: url)
        return url
    }

    /// Writes into a temp folder for drag & drop out of the quick overlay.
    static func writeTemporary(_ shot: Shot) -> URL? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Karuta", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try? save(shot, in: directory)
    }

    private static var desktop: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    private static func uniqueURL(in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Karuta \(formatter.string(from: Date()))"
        var url = directory.appendingPathComponent("\(base).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(n)).png")
            n += 1
        }
        return url
    }
}
