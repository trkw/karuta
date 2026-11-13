import AppKit
import KarutaCore

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
        shown = HistoryRules.items(CaptureHistory.items, ofKind: kind)
        collection.reloadData()
        empty.isHidden = !shown.isEmpty
    }

    @objc private func filterChanged() {
        let index = filter.selectedSegment
        kind = HistoryRules.kind(forSegment: index)
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
        let selected = collection.selectionIndexPaths.map(\.item)
        return HistoryRules.targets(around: index, selected: selected, count: shown.count).map { shown[$0] }
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
