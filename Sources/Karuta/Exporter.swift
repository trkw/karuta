import AppKit
import KarutaCore
import ImageIO
import UniformTypeIdentifiers

/// The alert for a save that failed, shown the same way from every place that saves (docs/refactoring.md K4).
/// Each caller keeps its own headline.
@MainActor
enum SaveErrorAlert {
    /// `message` replaces the headline; nil keeps the error's own description. With `window` it's a sheet on
    /// that window; otherwise Karuta comes to the front and shows it as a modal alert.
    static func show(_ error: Error, message: String? = "保存できませんでした", sheetOn window: NSWindow? = nil) {
        let alert = NSAlert(error: error)
        if let message { alert.messageText = message }
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate()
            alert.runModal()
        }
    }
}

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
        return context.makeImage().map { Shot(image: $0, scale: 1, app: shot.app) } ?? shot
    }

    static func copy(_ shot: Shot) {
        if let video = shot.video {
            // A recording goes on the clipboard as the file, ready to paste into Finder, Slack, etc.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([video as NSURL])
            return
        }
        guard let data = encode(exported(shot), as: .png) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard Preferences.copyAsFile, let file = writeClipboardFile(shot) else {
            pasteboard.setData(data, forType: .png)
            return
        }
        // One item with both: apps that take images get the PNG, Finder and chat apps get the file.
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        item.setString(file.absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])
    }

    /// The file behind "copy as a file": in the format chosen in Settings, named from the template,
    /// in a temp folder (never the save folder). Only the latest copy is kept; older ones are removed.
    static func writeClipboardFile(_ shot: Shot) -> URL? {
        let directory = TempFolders.directory(.clipboard, folderName: Bench.folderName)
        let fileManager = FileManager.default
        if let old = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in old { try? fileManager.removeItem(at: url) }
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try? save(shot, in: directory)
    }

    @discardableResult
    static func save(_ shot: Shot, in directory: URL = Preferences.saveDirectory) throws -> URL {
        if let video = shot.video {
            let url = uniqueURL(in: directory, extension: video.pathExtension, app: shot.app)
            try FileManager.default.copyItem(at: video, to: url)
            return url
        }
        let format = Preferences.format
        guard let data = fileData(shot, format: format) else { throw CocoaError(.fileWriteUnknown) }
        let url = uniqueURL(in: directory, extension: format.fileExtension, app: shot.app)
        try data.write(to: url)
        return url
    }

    /// Asks where to save (starting in the save folder). Returns whether it was saved.
    @MainActor
    static func saveAs(_ shot: Shot) -> Bool {
        if let video = shot.video {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: video.pathExtension) ?? .mpeg4Movie]
            panel.directoryURL = Preferences.saveDirectory
            panel.nameFieldStringValue = defaultFileName(extension: video.pathExtension, app: shot.app)
            NSApp.activate()
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            do {
                try? FileManager.default.removeItem(at: url) // the panel already asked about replacing it
                try FileManager.default.copyItem(at: video, to: url)
                return true
            } catch {
                SaveErrorAlert.show(error, message: nil)
                return false
            }
        }
        let save = ImageSavePanel(shot: shot)
        NSApp.activate()
        guard save.panel.runModal() == .OK else { return false }
        do {
            try save.write()
            return true
        } catch {
            SaveErrorAlert.show(error, message: nil)
            return false
        }
    }

    /// Writes into a temp folder for drag & drop out of the quick overlay and the editor, and for sharing.
    /// Each file gets its own folder, so it's named from the template without " (2)" from earlier drags.
    static func writeTemporary(_ shot: Shot) -> URL? {
        if let video = shot.video { return video }
        let parent = TempFolders.directory(.drag, folderName: Bench.folderName)
        guard let directory = try? TempFolders.fresh(in: parent) else { return nil }
        return try? save(shot, in: directory)
    }

    /// From the template in Settings, e.g. "Karuta 2026-10-31 13.05.09.png".
    /// Where recordings are written while they're in Quick Access (cleared by the system like any temp file).
    static var recordingsDirectory: URL {
        let directory = TempFolders.directory(.recordings, folderName: Bench.folderName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func temporaryRecordingURL(app: String?) -> URL {
        uniqueURL(in: recordingsDirectory, extension: "mp4", app: app)
    }

    static func defaultFileName(extension ext: String, app: String?) -> String {
        "\(baseName(app: app)).\(ext)"
    }

    /// What a capture taken now would be called with `template` (for the example in Settings).
    static func exampleFileName(template: String, extension ext: String, app: String?) -> String {
        let template = template.trimmingCharacters(in: .whitespaces)
        return "\(baseName(app: app, template: template.isEmpty ? Preferences.defaultFileNameTemplate : template)).\(ext)"
    }

    /// `app` is the one that was in front at capture time (empty when unknown, e.g. a file or the clipboard).
    private static func baseName(app: String?, template: String = Preferences.fileNameTemplate) -> String {
        FileNaming.baseName(template: template, app: app, date: Date())
    }

    private static func uniqueURL(in directory: URL, extension ext: String, app: String?) -> URL {
        FileNaming.uniqueURL(in: directory, base: baseName(app: app), extension: ext)
    }
}

/// The "別名で保存" panel for an image, shared by the quick overlay, pins, history and the editor: it starts in the save
/// folder with the template name, and a 形式 menu (PNG・JPEG・HEIC) picks the format for this file only.
/// The menu starts at the format chosen in Settings; choosing another one doesn't change the setting.
@MainActor
final class ImageSavePanel: NSObject {
    let panel = NSSavePanel()
    private(set) var format: Preferences.ImageFormat
    private let shot: Shot
    private let menu = NSPopUpButton(frame: .zero, pullsDown: false)

    init(shot: Shot) {
        self.shot = shot
        format = Preferences.format
        super.init()
        panel.allowedContentTypes = [format.utType]
        panel.directoryURL = Preferences.saveDirectory
        panel.nameFieldStringValue = Exporter.defaultFileName(extension: format.fileExtension, app: shot.app)
        menu.addItems(withTitles: Preferences.ImageFormat.allCases.map(\.title))
        menu.selectItem(at: Preferences.ImageFormat.allCases.firstIndex(of: format) ?? 0)
        menu.target = self
        menu.action = #selector(formatChanged)
        let row = NSStackView(views: [NSTextField(labelWithString: "形式:"), menu])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        panel.accessoryView = row
    }

    @objc private func formatChanged() {
        format = Preferences.ImageFormat.allCases[menu.indexOfSelectedItem]
        panel.allowedContentTypes = [format.utType]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
    }

    /// Writes the image in the chosen format to the chosen place (after the panel returned OK).
    func write() throws {
        guard let url = panel.url, let data = Exporter.fileData(shot, format: format) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
