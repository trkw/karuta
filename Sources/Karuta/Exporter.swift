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

    /// The image in the format chosen in Settings (JPEG at 90% quality).
    static func fileData(_ shot: Shot, format: Preferences.ImageFormat) -> Data? {
        guard format == .jpeg else { return pngData(shot) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let dpi = 72 * shot.scale
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
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
    static func save(_ shot: Shot, in directory: URL = Preferences.saveDirectory) throws -> URL {
        let format = Preferences.format
        guard let data = fileData(shot, format: format) else { throw CocoaError(.fileWriteUnknown) }
        let url = uniqueURL(in: directory, extension: format.fileExtension)
        try data.write(to: url)
        return url
    }

    /// Writes into a temp folder for drag & drop out of the quick overlay.
    static func writeTemporary(_ shot: Shot) -> URL? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Karuta", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try? save(shot, in: directory)
    }

    /// "Karuta yyyy-MM-dd HH.mm.ss.png"
    static func defaultFileName(extension ext: String) -> String {
        "\(baseName()).\(ext)"
    }

    private static func baseName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Karuta \(formatter.string(from: Date()))"
    }

    private static func uniqueURL(in directory: URL, extension ext: String) -> URL {
        let base = baseName()
        var url = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}
