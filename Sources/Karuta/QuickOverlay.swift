import AppKit

/// Small panel in the bottom-left corner after a capture: copy, save, edit, or drag the image out.
@MainActor
final class QuickOverlay: NSObject {
    var onEdit: ((Shot) -> Void)?

    private var panel: NSPanel?
    private var thumbnail: ThumbnailView?
    private var shot: Shot?
    private var dismissTask: Task<Void, Never>?

    func show(_ shot: Shot, on screen: NSScreen) {
        close()
        self.shot = shot

        let pixelSize = NSSize(width: shot.image.width, height: shot.image.height)
        let fit = min(240 / pixelSize.width, 150 / pixelSize.height, 1)
        let thumbSize = NSSize(width: max((pixelSize.width * fit).rounded(), 40),
                               height: max((pixelSize.height * fit).rounded(), 40))
        let pad: CGFloat = 8
        let buttonHeight: CGFloat = 24
        let size = NSSize(width: max(thumbSize.width, 200) + pad * 2,
                          height: thumbSize.height + buttonHeight + pad * 3)

        let panel = OverlayPanel(
            contentRect: NSRect(origin: NSPoint(x: screen.visibleFrame.minX + 16, y: screen.visibleFrame.minY + 16),
                                size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let thumbnail = ThumbnailView(frame: NSRect(
            x: (size.width - thumbSize.width) / 2, y: buttonHeight + pad * 2,
            width: thumbSize.width, height: thumbSize.height
        ))
        thumbnail.image = NSImage(cgImage: shot.image, size: .zero)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.makeFile = { [weak self] in self?.shot.flatMap(Exporter.writeTemporary) }
        thumbnail.onDropped = { [weak self] in self?.close() }
        thumbnail.onDoubleClick = { [weak self] in self?.editImage() }
        background.addSubview(thumbnail)

        let buttons = NSStackView(views: [
            button("コピー", #selector(copyImage)),
            button("保存", #selector(saveImage)),
            button("編集", #selector(editImage)),
            button("閉じる", #selector(dismiss)),
        ])
        buttons.distribution = .fillEqually
        buttons.spacing = 6
        buttons.frame = NSRect(x: pad, y: pad, width: size.width - pad * 2, height: buttonHeight)
        background.addSubview(buttons)

        panel.contentView = background
        panel.orderFrontRegardless()
        self.panel = panel
        self.thumbnail = thumbnail
        scheduleDismiss(after: 6)
    }

    func close() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
        thumbnail = nil
        shot = nil
    }

    @objc private func copyImage() {
        if let shot { Exporter.copy(shot) }
        close()
    }

    @objc private func saveImage() {
        guard let shot else { return }
        do {
            try Exporter.save(shot)
            close()
        } catch {
            // Keep the overlay so the capture can still be copied or dragged out.
            dismissTask?.cancel()
            let alert = NSAlert(error: error)
            alert.messageText = "保存できませんでした"
            NSApp.activate()
            alert.runModal()
            scheduleDismiss(after: 6)
        }
    }

    @objc private func editImage() {
        guard let shot else { return }
        close()
        onEdit?(shot)
    }

    @objc private func dismiss() {
        close()
    }

    /// Closes after a delay, but waits while the pointer is over the panel or a drag is in progress.
    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            if panel.frame.contains(NSEvent.mouseLocation) || self.thumbnail?.isDragging == true {
                self.scheduleDismiss(after: 2)
            } else {
                self.close()
            }
        }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = FirstMouseButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ThumbnailView: NSImageView, NSDraggingSource {
    var makeFile: (() -> URL?)?
    var onDropped: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private(set) var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let image, let url = makeFile?() else { return }
        isDragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        if !operation.isEmpty { onDropped?() }
    }
}
