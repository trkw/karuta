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
