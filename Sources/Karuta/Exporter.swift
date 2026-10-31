import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Exporter {
    /// PNG with DPI metadata so Retina captures open at their point size (at full resolution).
    static func pngData(_ shot: Shot) -> Data? {
        encode(shot, as: .png)
    }

    /// The image as it is copied or saved: in the format chosen in Settings (JPEG / HEIC at 90% quality),
    /// at 1x when "Retina を 1x に縮小" is on.
    static func fileData(_ shot: Shot, format: Preferences.ImageFormat) -> Data? {
        encode(exported(shot), as: format.utType)
    }

    private static func encode(_ shot: Shot, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, type.identifier as CFString, 1, nil
        ) else { return nil }
        let dpi = 72 * shot.scale
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if type != .png { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(destination, shot.image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Scales a Retina shot down to 1x when that's chosen in Settings.
    private static func exported(_ shot: Shot) -> Shot {
        guard Preferences.scaleRetina, shot.scale > 1 else { return shot }
        let width = Int((CGFloat(shot.image.width) / shot.scale).rounded())
        let height = Int((CGFloat(shot.image.height) / shot.scale).rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: shot.image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return shot }
        context.interpolationQuality = .high
        context.draw(shot.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map { Shot(image: $0, scale: 1) } ?? shot
    }

    static func copy(_ shot: Shot) {
        guard let data = encode(exported(shot), as: .png) else { return }
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

    /// Asks where to save (starting in the save folder). Returns whether it was saved.
    @MainActor
    static func saveAs(_ shot: Shot) -> Bool {
        let format = Preferences.format
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.directoryURL = Preferences.saveDirectory
        panel.nameFieldStringValue = defaultFileName(extension: format.fileExtension)
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            guard let data = fileData(shot, format: format) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Writes into a temp folder for drag & drop out of the quick overlay.
    static func writeTemporary(_ shot: Shot) -> URL? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Karuta", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try? save(shot, in: directory)
    }

    /// From the template in Settings, e.g. "Karuta 2026-10-31 13.05.09.png".
    static func defaultFileName(extension ext: String) -> String {
        "\(baseName()).\(ext)"
    }

    private static func baseName() -> String {
        let now = Date()
        func formatted(_ format: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter.string(from: now)
        }
        let app = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0.localizedName } ?? ""
        let name = Preferences.fileNameTemplate
            .replacingOccurrences(of: "{date}", with: formatted("yyyy-MM-dd"))
            .replacingOccurrences(of: "{time}", with: formatted("HH.mm.ss"))
            .replacingOccurrences(of: "{app}", with: app)
            // "/" and ":" can't be in a file name; collapse the spaces an empty {app} leaves.
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return name.isEmpty ? "Karuta" : name
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
