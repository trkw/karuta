import AppKit
import ImageIO

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
                items.insert(item, at: items.firstIndex { $0.date < item.date } ?? items.count)
                prune()
                save()
            }
        }
    }

    /// Drops what is older than the retention period (and everything when history is off).
    static func prune() {
        let days = Preferences.historyDays
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        if days <= 0 { generation += 1 }
        let expired = items.filter { days <= 0 || $0.date < cutoff }
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

// MARK: - Window

/// A grid of past captures, newest first, with a filter by kind. Double-click opens the editor; the context
/// menu copies, saves, pins, shows it in Quick Access or deletes; Delete removes the selection.
@MainActor
final class HistoryWindowController: NSWindowController, NSCollectionViewDataSource, NSWindowDelegate {
    var onEdit: ((Shot) -> Void)?
    var onPin: ((Shot) -> Void)?
    var onOverlay: ((Shot) -> Void)?
    var onClose: (() -> Void)?

    private let collection = HistoryCollectionView()
    private let filter = NSSegmentedControl()
    private let empty = NSTextField(labelWithString: "撮影履歴はまだありません")
    private var kind: CaptureHistory.Kind?
    private var shown: [CaptureHistory.Item] = []
    private var observer: NSObjectProtocol?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "撮影履歴"
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
        reload()
        observer = NotificationCenter.default.addObserver(forName: CaptureHistory.didChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        onClose?()
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let titles = ["すべて"] + CaptureHistory.Kind.allCases.map(\.title)
        filter.segmentCount = titles.count
        for (index, title) in titles.enumerated() { filter.setLabel(title, forSegment: index) }
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(filterChanged)

        let clear = NSButton(title: "すべて削除…", target: self, action: #selector(clearAll))
        clear.bezelStyle = .rounded

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 176, height: 148)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.dataSource = self
        collection.register(HistoryItem.self, forItemWithIdentifier: HistoryItem.identifier)
        collection.onDelete = { [weak self] in self?.deleteSelection() }
        collection.menuForItem = { [weak self] index in self?.menu(for: index) }
        collection.onOpen = { [weak self] index in self?.edit(at: index) }

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        empty.textColor = .secondaryLabelColor
        empty.alignment = .center

        let bar = NSStackView(views: [filter, NSView(), clear])
        bar.orientation = .horizontal
        for view in [bar, scroll, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    private func reload() {
        CaptureHistory.prune()
        shown = CaptureHistory.items.filter { kind == nil || $0.kind == kind }
        collection.reloadData()
        empty.isHidden = !shown.isEmpty
    }

    @objc private func filterChanged() {
        let index = filter.selectedSegment
        kind = index == 0 ? nil : CaptureHistory.Kind.allCases[index - 1]
        reload()
    }

    @objc private func clearAll() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "撮影履歴をすべて削除しますか？"
        alert.informativeText = "保存先に保存した画像は消えません。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { CaptureHistory.clear() }
        }
    }

    // MARK: Actions

    private func items(around index: Int) -> [CaptureHistory.Item] {
        // A right click on a selected item acts on the whole selection; otherwise on that item.
        let selected = collection.selectionIndexPaths.map(\.item).sorted()
        let indices = selected.contains(index) ? selected : [index]
        return indices.filter { $0 < shown.count }.map { shown[$0] }
    }

    private func edit(at index: Int) {
        guard index < shown.count, let shot = CaptureHistory.shot(for: shown[index]) else { return }
        onEdit?(shot)
    }

    private func deleteSelection() {
        let items = collection.selectionIndexPaths.map(\.item).filter { $0 < shown.count }.map { shown[$0] }
        if !items.isEmpty { CaptureHistory.remove(items) }
    }

    private func menu(for index: Int) -> NSMenu? {
        guard index < shown.count else { return nil }
        let targets = items(around: index)
        let single = targets.count == 1 ? CaptureHistory.shot(for: targets[0]) : nil
        let menu = NSMenu()
        if let shot = single {
            menu.addItem(MenuAction(title: "コピー") { Exporter.copy(shot) })
            menu.addItem(MenuAction(title: "別名で保存…") { _ = Exporter.saveAs(shot) })
            menu.addItem(.separator())
            menu.addItem(MenuAction(title: "編集") { [weak self] in self?.onEdit?(shot) })
            menu.addItem(MenuAction(title: "ピン留め") { [weak self] in self?.onPin?(shot) })
            menu.addItem(MenuAction(title: "クイックアクセスに表示") { [weak self] in self?.onOverlay?(shot) })
            menu.addItem(MenuAction(title: "Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting([CaptureHistory.url(for: targets[0])])
            })
            menu.addItem(.separator())
        }
        let title = targets.count == 1 ? "削除" : "\(targets.count) 件を削除"
        menu.addItem(MenuAction(title: title) { CaptureHistory.remove(targets) })
        return menu
    }

    // MARK: NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        shown.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let view = collectionView.makeItem(withIdentifier: HistoryItem.identifier, for: indexPath)
        if let cell = view as? HistoryItem { cell.show(shown[indexPath.item]) }
        return view
    }
}

/// Passes Delete, double-clicks and right clicks on items back to the window controller.
private final class HistoryCollectionView: NSCollectionView {
    var onDelete: (() -> Void)?
    var onOpen: ((Int) -> Void)?
    var menuForItem: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?() } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let index = index(at: event) { onOpen?(index) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: event) else { return nil }
        return menuForItem?(index)
    }

    private func index(at event: NSEvent) -> Int? {
        indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item
    }
}

private final class HistoryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("HistoryItem")

    private let thumbnail = NSImageView()
    private let caption = NSTextField(labelWithString: "")

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 4
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        for view in [thumbnail, caption] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            thumbnail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            thumbnail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            caption.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: 4),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            caption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
    }

    func show(_ item: CaptureHistory.Item) {
        thumbnail.image = CaptureHistory.thumbnail(for: item).map { NSImage(cgImage: $0, size: .zero) }
        let size = "\(Int(Double(item.width) / item.scale)) × \(Int(Double(item.height) / item.scale))"
        caption.stringValue = "\(Self.formatter.string(from: item.date))  \(size)"
        caption.toolTip = [item.kind.title, item.app].compactMap { $0 }.joined(separator: " · ")
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil
        }
    }
}
