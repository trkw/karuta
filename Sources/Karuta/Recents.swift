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
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return Shot(image: image, scale: max(1, (CGFloat(dpi) / 72).rounded()))
    }
}

/// Quick Access cards that were closed, so "最近閉じたものを戻す" can bring them back (CleanShot's
/// "Restore Recently Closed File"). They are written as PNGs to the caches folder instead of being kept in
/// memory, newest last, at most `limit`.
@MainActor
enum ClosedShots {
    private static let limit = 5
    private static var files: [URL] = []
    /// Shots still being written, so one closed a moment ago can come back before its file exists.
    private static var pending: [URL: Shot] = [:]

    private static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("Karuta/Closed", isDirectory: true)
        // Start empty each launch: leftovers belong to a previous session.
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var isEmpty: Bool { files.isEmpty }

    static func add(_ shot: Shot) {
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        files.append(url)
        pending[url] = shot
        while files.count > limit {
            let old = files.removeFirst()
            pending[old] = nil
            try? FileManager.default.removeItem(at: old)
        }
        // Encoding a large PNG takes a moment, so do it off the main thread.
        Task.detached(priority: .utility) {
            let data = Exporter.pngData(shot)
            await MainActor.run {
                // Skip it if it was restored or dropped meanwhile.
                guard pending.removeValue(forKey: url) != nil else { return }
                try? data?.write(to: url)
            }
        }
    }

    /// The most recently closed shot, removed from the list.
    static func popLast() -> Shot? {
        while let url = files.popLast() {
            if let shot = pending.removeValue(forKey: url) { return shot }
            defer { try? FileManager.default.removeItem(at: url) }
            if let shot = ImageLoader.shot(contentsOf: url) { return shot }
        }
        return nil
    }
}
