import AppKit

// Commands: the editor's keyboard shortcuts and the actions they run.
extension EditorWindowController {
    func handleCommand(_ key: String, shift: Bool) -> Bool {
        // Typing in the canvas's text or a toolbar field (the counter's number): editing shortcuts go to the text.
        if canvas.isEditingText || window?.firstResponder is NSText {
            // Without an Edit menu, the text field's standard editing shortcuts need to be sent by hand.
            let actions: [String: Selector] = [
                "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
                "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
            ]
            guard let action = actions[key] else { return false }
            return NSApp.sendAction(action, to: nil, from: self)
        }
        switch (key, shift) {
        case ("c", false): copyImage()
        case ("s", false): saveToFolder()
        case ("s", true): saveAs()
        case ("d", false): return canvas.duplicateSelection()
        case ("p", false): printImage()
        case ("z", false): canvas.undo()
        case ("z", true): canvas.redo()
        case ("w", _): close()
        default: return false
        }
        return true
    }


    @objc func widthChanged(_ sender: NSSlider) {
        canvas.lineWidth = CGFloat(sender.doubleValue.rounded())
    }

    @objc func zoomChanged() {
        canvas.zoomLevel = Self.zoomChoices[zoomPopup.indexOfSelectedItem].1
        window?.makeFirstResponder(canvas)
    }

    @objc func done() {
        // Return while cropping applies the crop instead of finishing.
        if canvas.tool == .crop, NSApp.currentEvent?.type == .keyDown {
            canvas.tool = .select
            return
        }
        onDone?(canvas.renderedShot())
        close()
    }

    func copyImage() {
        Exporter.copy(canvas.renderedShot())
        close()
    }

    func pinImage() {
        let frame = window?.frame ?? .zero
        onPin?(canvas.renderedShot(), frame)
        close()
    }

    private func saveToFolder() {
        do {
            try Exporter.save(canvas.renderedShot())
            close()
        } catch {
            showError(error)
        }
    }

    @objc func saveAs() {
        guard let window else { return }
        let save = ImageSavePanel(shot: canvas.renderedShot())
        save.panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            do {
                try save.write()
                self?.close()
            } catch {
                self?.showError(error)
            }
        }
    }

    private func printImage() {
        guard let window else { return }
        let shot = canvas.renderedShot()
        let size = NSSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: shot.image, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        if size.width > size.height { info.orientation = .landscape }
        NSPrintOperation(view: view, printInfo: info).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func share(from sender: NSView) {
        guard let url = Exporter.writeTemporary(canvas.renderedShot()) else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func showError(_ error: Error) {
        if let window { SaveErrorAlert.show(error, sheetOn: window) }
    }

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.white.withAlphaComponent(0.4).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }
}
