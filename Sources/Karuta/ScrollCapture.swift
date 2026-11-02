import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Scrolling capture: the chosen area is captured over and over while it scrolls (by hand, or with
/// automatic scrolling), and each new frame's newly revealed rows are stitched under the previous ones.
/// Rows that stay put between frames at the top and bottom (sticky headers, toolbars) are kept once.
@MainActor
final class ScrollCapture {
    private let rect: CGRect
    private let filter: SCContentFilter
    private let config: SCStreamConfiguration
    private var stitcher = Stitcher()
    private let panel: ScrollPanel
    private let outline: RecordingFrame
    private var timer: Timer?
    private var busy = false
    private var autoScrolling = false
    private var unchangedTicks = 0
    private var continuation: CheckedContinuation<CGImage?, Never>?

    /// `rect` in AppKit global coordinates; `config` already carries its sourceRect and pixel size.
    init(rect: CGRect, screen: NSScreen, filter: SCContentFilter, config: SCStreamConfiguration) {
        self.rect = rect
        self.filter = filter
        self.config = config
        outline = RecordingFrame(around: rect)
        panel = ScrollPanel(below: rect, on: screen)
        panel.onDone = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onAutoScroll = { [weak self] in self?.startAutoScroll() }
    }

    /// Runs until Done (the stitched image) or Cancel (nil).
    func run(autoScroll: Bool) async -> CGImage? {
        outline.orderFrontRegardless()
        panel.orderFrontRegardless()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.tick() // the first frame right away
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            if autoScroll { self.startAutoScroll() }
        }
    }

    func finish() {
        end(with: stitcher.image())
    }

    private func cancel() {
        end(with: nil)
    }

    private func end(with image: CGImage?) {
        timer?.invalidate()
        timer = nil
        autoScrolling = false
        outline.orderOut(nil)
        panel.orderOut(nil)
        continuation?.resume(returning: image)
        continuation = nil
    }

    private func tick() {
        guard !busy, continuation != nil else { return }
        busy = true
        Task {
            defer { self.busy = false }
            guard let frame = try? await SCScreenshotManager.captureImage(contentFilter: self.filter,
                                                                          configuration: self.config),
                  self.continuation != nil
            else { return }
            let grew = self.stitcher.add(frame)
            self.panel.show(height: self.stitcher.height, scale: CGFloat(frame.width) / max(self.rect.width, 1))
            if self.stitcher.isFull {
                self.finish()
                return
            }
            guard self.autoScrolling else { return }
            // Stop at the end of the page: nothing new for a while.
            self.unchangedTicks = grew ? 0 : self.unchangedTicks + 1
            if self.unchangedTicks >= 6 {
                self.finish()
            } else {
                self.scrollOnce()
            }
        }
    }

    /// Automatic scrolling posts scroll-wheel events, which needs Accessibility permission.
    private func startAutoScroll() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            panel.showMessage("自動スクロールには「アクセシビリティ」の許可が要ります")
            return
        }
        autoScrolling = true
        unchangedTicks = 0
        panel.showMessage("自動でスクロールしています…")
    }

    /// A third of the area per step, so consecutive frames overlap well.
    private func scrollOnce() {
        let step = Int32(max(20, rect.height / 3))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -step, wheel2: 0, wheel3: 0)
        else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: rect.midX, y: primaryHeight - rect.midY) // CG global: top-left origin
        event.post(tap: .cghidEventTap)
    }
}

// MARK: - Stitching

/// Joins frames of the same size, top to bottom. Each frame's rows are hashed; the scroll distance is the
/// shift that lines the most rows up with the previous frame. Only new rows are kept (copied out), so
/// memory grows with the result, not with the number of frames.
///
/// Columns that didn't change between two frames (a fixed sidebar beside the page) are left out of the
/// hashes, and so is the right edge, where an overlay scroll bar appears while scrolling: only the part
/// that moves is matched.
struct Stitcher {
    private struct Frame {
        let image: CGImage
        let pixels: [UInt32] // top row first
    }

    /// A tall page is cut off here (pixels), to keep the image manageable.
    static let maxHeight = 32000
    /// Pixels at the right edge never matched: the scroll bar fades in and moves while scrolling.
    static let scrollBarWidth = 24

    private var previous: Frame?
    /// Kept rows, top to bottom; the last frame's bottom band (a sticky footer) goes after them.
    private var segments: [CGImage] = []
    private var footer: CGImage?
    /// The previous frame's row (top-origin) where the kept page content ends; below it is its footer.
    private var keptEnd = 0

    var height: Int { segments.reduce(0) { $0 + $1.height } + (footer?.height ?? 0) }
    var isFull: Bool { height >= Self.maxHeight }

    /// Returns whether the frame added anything.
    mutating func add(_ image: CGImage) -> Bool {
        guard let pixels = Self.pixels(image) else { return false }
        let frame = Frame(image: image, pixels: pixels)
        guard let previous else {
            self.previous = frame
            segments = [Self.copyRows(image, 0, image.height)].compactMap { $0 }
            keptEnd = image.height
            return true
        }
        guard image.width == previous.image.width, image.height == previous.image.height,
              let columns = Self.movingColumns(previous.pixels, pixels, width: image.width, height: image.height)
        else { return false }
        let oldRows = Self.rowHashes(previous.pixels, width: image.width, columns: columns)
        let rows = Self.rowHashes(pixels, width: image.width, columns: columns)

        // Bands that didn't move at all: sticky headers at the top, toolbars or footers at the bottom.
        let h = rows.count
        var top = 0
        while top < h, rows[top] == oldRows[top] { top += 1 }
        var bottom = 0
        while bottom < h - top, rows[h - 1 - bottom] == oldRows[h - 1 - bottom] { bottom += 1 }
        let lo = top, hi = h - bottom
        let span = hi - lo
        guard span >= 24, let shift = Self.shift(oldRows, rows, lo: lo, hi: hi) else {
            // Scrolled back up, or the content changed: wait for a frame that continues the page.
            return false
        }

        // Rows kept as page content that turn out to be a fixed footer come off the end.
        if keptEnd > hi, let last = segments.last {
            let extra = min(keptEnd - hi, last.height)
            if extra == last.height {
                segments.removeLast()
            } else if let trimmed = Self.copyRows(last, 0, last.height - extra) {
                segments[segments.count - 1] = trimmed
            }
            keptEnd = hi
        }
        // The previous frame's row r is this frame's row r - shift.
        let start = max(lo, keptEnd - shift)
        if hi > start, let added = Self.copyRows(image, start, hi) { segments.append(added) }
        footer = bottom > 0 ? Self.copyRows(image, hi, h) : nil
        keptEnd = hi
        self.previous = frame
        return hi > start
    }

    /// The scroll distance in rows: the smallest shift `s` where the new frame's rows from `lo` match the
    /// previous frame's from `lo + s` best (at least 90% of the overlap, which must be a sixth of the span).
    private static func shift(_ old: [UInt64], _ new: [UInt64], lo: Int, hi: Int) -> Int? {
        let span = hi - lo
        let minOverlap = max(12, span / 6)
        guard span - minOverlap >= 1 else { return nil }
        var best: (shift: Int, score: Double)?
        for s in 1 ... (span - minOverlap) {
            let overlap = span - s
            var matches = 0
            for i in 0 ..< overlap where new[lo + i] == old[lo + s + i] { matches += 1 }
            let score = Double(matches) / Double(overlap)
            if score > (best?.score ?? 0.9) { best = (s, score) }
            if score == 1 { break } // can't do better; keep the smallest such shift
        }
        return best?.shift
    }

    /// The image as 32-bit pixels, top row first.
    private static func pixels(_ image: CGImage) -> [UInt32]? {
        let width = image.width, height = image.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// The columns to match: from the first to the last column that changed between the two frames,
    /// leaving out unchanged ones at either side and the scroll bar at the right edge. Nil when nothing moved.
    private static func movingColumns(_ old: [UInt32], _ new: [UInt32], width: Int, height: Int) -> Range<Int>? {
        var changed = [Bool](repeating: false, count: width)
        old.withUnsafeBufferPointer { a in
            new.withUnsafeBufferPointer { b in
                for y in 0 ..< height {
                    let row = y * width
                    for x in 0 ..< width where !changed[x] && a[row + x] != b[row + x] { changed[x] = true }
                }
            }
        }
        guard let first = changed.firstIndex(of: true), let last = changed.lastIndex(of: true) else { return nil }
        // A narrow area is matched whole; otherwise a change in the scroll bar alone isn't a scroll.
        guard width >= scrollBarWidth * 4 else { return first ..< last + 1 }
        let end = min(last + 1, width - scrollBarWidth)
        return first < end ? first ..< end : nil
    }

    /// One hash per pixel row, over `columns` (every other pixel).
    private static func rowHashes(_ pixels: [UInt32], width: Int, columns: Range<Int>) -> [UInt64] {
        let height = pixels.count / max(width, 1)
        var hashes = [UInt64](repeating: 0, count: height)
        pixels.withUnsafeBufferPointer { p in
            for y in 0 ..< height {
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                var i = y * width + columns.lowerBound
                let end = y * width + columns.upperBound
                while i < end {
                    hash = (hash ^ UInt64(p[i] & 0x00ff_ffff)) &* 0x0000_0100_0000_01b3
                    i += 2
                }
                hashes[y] = hash
            }
        }
        return hashes
    }

    /// Rows `from ..< to` (top-origin) copied into their own bitmap, so the frame can be released.
    private static func copyRows(_ image: CGImage, _ from: Int, _ to: Int) -> CGImage? {
        guard to > from, let cropped = image.cropping(to: CGRect(x: 0, y: from, width: image.width, height: to - from)),
              let context = AnnotationRenderer.bitmap(width: cropped.width, height: cropped.height, space: image.colorSpace)
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage()
    }

    /// Everything kept so far, as one image.
    func image() -> CGImage? {
        let parts = segments + (footer.map { [$0] } ?? [])
        guard let width = parts.first?.width else { return nil }
        let total = parts.reduce(0) { $0 + $1.height }
        guard let context = AnnotationRenderer.bitmap(width: width, height: total, space: parts.first?.colorSpace)
        else { return nil }
        var y = total // drawing from the top down, in a bottom-left-origin context
        for part in parts {
            y -= part.height
            context.draw(part, in: CGRect(x: 0, y: y, width: part.width, height: part.height))
        }
        return context.makeImage()
    }
}

// MARK: - Panel

/// The controls under the area while capturing: what to do, the height so far, and Done / Cancel.
/// It never takes focus, so the page under it keeps receiving the scroll.
private final class ScrollPanel: NSPanel {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAutoScroll: (() -> Void)?

    private let message = NSTextField(labelWithString: "スクロールしてください")
    private let size = NSTextField(labelWithString: "")

    init(below rect: CGRect, on screen: NSScreen) {
        let panelSize = NSSize(width: 420, height: 44)
        let visible = screen.visibleFrame
        var origin = NSPoint(x: rect.midX - panelSize.width / 2, y: rect.minY - panelSize.height - 12)
        if origin.y < visible.minY { origin.y = min(rect.maxY + 12, visible.maxY - panelSize.height) }
        if origin.y + panelSize.height > visible.maxY { origin.y = rect.minY + 12 } // area fills the screen: inside it
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        super.init(contentRect: NSRect(origin: origin, size: panelSize), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)

        let background = NSView(frame: NSRect(origin: .zero, size: panelSize))
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor

        message.font = .systemFont(ofSize: 12, weight: .medium)
        message.textColor = .white
        message.lineBreakMode = .byTruncatingTail
        size.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        size.textColor = .secondaryLabelColor
        let auto = Self.button("自動スクロール") { [weak self] in self?.onAutoScroll?() }
        let cancel = Self.button("キャンセル") { [weak self] in self?.onCancel?() }
        let done = Self.button("完了") { [weak self] in self?.onDone?() }
        done.bezelColor = .controlAccentColor

        let texts = NSStackView(views: [message, size])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [texts, auto, cancel, done])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        contentView = background
    }

    func show(height pixels: Int, scale: CGFloat) {
        size.stringValue = "高さ \(Int(CGFloat(pixels) / max(scale, 1))) pt"
    }

    func showMessage(_ text: String) {
        message.stringValue = text
    }

    private static func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = PanelButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private final class PanelButton: NSButton {
        private let handler: () -> Void

        init(title: String, action: @escaping () -> Void) {
            handler = action
            super.init(frame: .zero)
            self.title = title
            target = self
            self.action = #selector(fire)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @objc private func fire() { handler() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
