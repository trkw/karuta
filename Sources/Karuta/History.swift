import AppKit
import ImageIO
import KarutaCore

/// Capture History, like CleanShot's: every capture is kept as a PNG in Application Support for the number
/// of days chosen in Settings, so it can be copied, edited, pinned or brought back later.
/// The index is a small JSON file; images are only read when shown.
@MainActor
enum CaptureHistory {
    static let didChange = Notification.Name("KarutaHistoryDidChange")

    enum Kind: String, Codable, CaseIterable {
        case area, window, fullscreen

        var title: String {
            switch self {
            case .area: "範囲"
            case .window: "ウィンドウ"
            case .fullscreen: "全画面"
            }
        }
    }

    struct Item: Codable, Equatable {
        let id: String
        let date: Date
        let kind: Kind
        let width: Int
        let height: Int
        let scale: Double
        let app: String?
    }

    private static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("\(Bench.folderName)/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// Newest first. Loaded on first use.
    private(set) static var items: [Item] = {
        guard let data = try? Data(contentsOf: indexURL),
              let items = try? JSONDecoder().decode([Item].self, from: data)
        else { return [] }
        return items
    }()

    private static let thumbnails = NSCache<NSString, CGImage>()
    /// Bumped whenever everything is removed, so captures still being encoded don't come back afterwards.
    private static var generation = 0

    static func url(for item: Item) -> URL { directory.appendingPathComponent("\(item.id).png") }

    static func add(_ shot: Shot, kind: Kind) {
        let days = Preferences.historyDays
        guard days > 0 else { return }
        let item = Item(id: UUID().uuidString, date: Date(), kind: kind, width: shot.image.width,
                        height: shot.image.height, scale: Double(shot.scale), app: shot.app)
        let url = url(for: item)
        let started = generation
        // Encode off the main thread; the item shows up once its file exists.
        Task.detached(priority: .utility) {
            guard let data = Exporter.pngData(shot), (try? data.write(to: url)) != nil else { return }
            await MainActor.run {
                guard generation == started, Preferences.historyDays > 0 else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                // Encodes can finish out of order (a big fullscreen after a small area); keep newest first.
                items.insert(item, at: HistoryRules.insertionIndex(for: item.date, in: items.map(\.date)))
                prune()
                save()
            }
        }
    }

    /// Drops what is older than the retention period (and everything when history is off).
    static func prune() {
        let days = Preferences.historyDays
        let now = Date()
        if days <= 0 { generation += 1 }
        let expired = items.filter { HistoryRules.isExpired($0.date, days: days, now: now) }
        guard !expired.isEmpty else { return }
        remove(expired)
    }

    static func remove(_ removed: [Item]) {
        let ids = Set(removed.map(\.id))
        for item in removed {
            try? FileManager.default.removeItem(at: url(for: item))
            thumbnails.removeObject(forKey: item.id as NSString)
        }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    static func clear() {
        generation += 1
        remove(items)
    }

    static func shot(for item: Item) -> Shot? {
        guard var shot = ImageLoader.shot(contentsOf: url(for: item)) else { return nil }
        shot.app = item.app
        return shot
    }

    /// A small image for the history window, cached while the app runs.
    static func thumbnail(for item: Item) -> CGImage? {
        if let cached = thumbnails.object(forKey: item.id as NSString) { return cached }
        guard let source = CGImageSourceCreateWithURL(url(for: item) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        thumbnails.setObject(image, forKey: item.id as NSString)
        return image
    }

    private static func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
