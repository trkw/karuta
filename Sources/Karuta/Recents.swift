import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Turns image files and the clipboard into a `Shot`, reading the DPI so Retina images keep their point size.
enum ImageLoader {
    static func shot(contentsOf url: URL) -> Shot? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return shot(from: source)
    }

    static func shot(from data: Data) -> Shot? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return shot(from: source)
    }

    /// The image on the clipboard: PNG / TIFF data first (keeps the DPI), then anything NSImage can read.
    static func shotFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Shot? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let shot = shot(from: data) { return shot }
        }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
           let shot = shot(contentsOf: url) {
            return shot
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return Shot(image: cgImage, scale: max(1, CGFloat(cgImage.width) / max(image.size.width, 1)).rounded())
    }

    /// Asks for an image file (for "open in the editor" and "pin").
    static func chooseImage(prompt: String) -> Shot? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = prompt
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return shot(contentsOf: url)
    }

    private static func shot(from source: CGImageSource) -> Shot? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let image: CGImage?
        if orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            // A rotated photo (EXIF orientation): let ImageIO turn the pixels upright, at full size.
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image else { return nil }
        return Shot(image: image, scale: max(1, (CGFloat(dpi) / 72).rounded()))
    }
}

/// Quick Access cards that were closed, so "最近閉じたものを戻す" can bring them back (CleanShot's
/// "Restore Recently Closed File"). They are written as PNGs to the caches folder instead of being kept in
/// memory, newest last, at most `limit`. A card that got an automatic background also keeps the capture
/// without it, so the background stays adjustable after restoring.
@MainActor
enum ClosedShots {
    struct Entry {
        let shot: Shot
        let original: Shot?
    }

    private struct Files {
        let shot: URL
        let original: URL?
        var all: [URL] { [shot] + (original.map { [$0] } ?? []) }
    }

    private static let limit = 5
    private static var files: [Files] = []
    /// Entries still being written, so one closed a moment ago can come back before its files exist.
    private static var pending: [URL: Entry] = [:]

    private static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("Karuta/Closed", isDirectory: true)
        // Start empty each launch: leftovers belong to a previous session.
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func add(_ shot: Shot, original: Shot?) {
        let id = UUID().uuidString
        let entryFiles = Files(shot: directory.appendingPathComponent("\(id).png"),
                               original: original.map { _ in directory.appendingPathComponent("\(id)-original.png") })
        let key = entryFiles.shot
        files.append(entryFiles)
        pending[key] = Entry(shot: shot, original: original)
        while files.count > limit { discard(files.removeFirst()) }
        // Encoding a large PNG takes a moment, so do it off the main thread.
        Task.detached(priority: .utility) {
            let data = Exporter.pngData(shot)
            let originalData = original.flatMap { Exporter.pngData($0) }
            await MainActor.run {
                // Skip it if it was restored or dropped meanwhile.
                guard pending.removeValue(forKey: key) != nil else { return }
                try? data?.write(to: entryFiles.shot)
                if let url = entryFiles.original { try? originalData?.write(to: url) }
            }
        }
    }

    /// The most recently closed card, removed from the list.
    static func popLast() -> Entry? {
        while let entryFiles = files.popLast() {
            if let entry = pending.removeValue(forKey: entryFiles.shot) { return entry }
            defer { discard(entryFiles) }
            if let shot = ImageLoader.shot(contentsOf: entryFiles.shot) {
                return Entry(shot: shot, original: entryFiles.original.flatMap(ImageLoader.shot(contentsOf:)))
            }
        }
        return nil
    }

    private static func discard(_ entryFiles: Files) {
        pending[entryFiles.shot] = nil
        entryFiles.all.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
