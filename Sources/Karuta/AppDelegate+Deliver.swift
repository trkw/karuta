import AppKit

// After a capture: deliver the shot as chosen in Settings, pin it, or open it in the editor.
extension AppDelegate {
    /// What happens after a capture, as chosen in Settings.
    func deliver(_ raw: Shot, on screen: NSScreen, frame: NSRect, isWindow: Bool, kind: CaptureHistory.Kind,
                         delivery: Delivery) {
        if Preferences.playSound { Sounds.shutter()?.play() }
        let backdrop = switch Preferences.autoBackdrop {
        case .off: false
        case .windows: isWindow
        case .all: true
        }
        // The editor gets the plain shot with the background switched on, so the backdrop stays adjustable.
        let shot = backdrop ? Backdrop.compose(raw) : raw
        CaptureHistory.add(shot, kind: kind)
        switch delivery {
        case .settings:
            break
        case .copy:
            Exporter.copy(shot)
            return
        case .save:
            do {
                try Exporter.save(shot)
            } catch {
                NSLog("Karuta: save failed: \(error)")
                // Keep the shot in Quick Access so it isn't lost, then say why it wasn't saved.
                overlay.show(shot, original: backdrop ? raw : nil, on: screen)
                QuickOverlay.showSaveError(error)
            }
            return
        case .annotate:
            openEditor(raw, background: backdrop)
            return
        case .pin:
            pin(shot, near: frame)
            return
        }
        // Copy once even when both the general and the area-only setting are on.
        if Preferences.copyToClipboard || (kind == .area && Preferences.copyAreaCaptureToClipboard) {
            Exporter.copy(shot)
        }
        var saveError: Error?
        if Preferences.saveToFile {
            do {
                try Exporter.save(shot)
            } catch {
                NSLog("Karuta: save failed: \(error)")
                saveError = error
            }
        }
        // A shot that couldn't be saved stays in Quick Access even when the overlay is off.
        if Preferences.showOverlay || saveError != nil { overlay.show(shot, original: backdrop ? raw : nil, on: screen) }
        if Preferences.openEditor { openEditor(raw, background: backdrop) }
        if let saveError { QuickOverlay.showSaveError(saveError) }
    }

    func pin(_ shot: Shot, near frame: NSRect) {
        let window = PinWindow(shot: shot, frame: frame)
        window.onClose = { [weak self, weak window] in
            self?.pins.removeAll { $0 === window }
        }
        window.onEdit = { [weak self] shot in self?.openEditor(shot) }
        window.onCloseAll = { [weak self] in self?.perform(.closeAllPins) }
        pins.append(window)
        window.orderFrontRegardless()
    }

    func openEditor(_ shot: Shot, background: Bool = false) {
        let editor = EditorWindowController(shot: shot, background: background)
        editor.onDone = { [weak self] edited in self?.overlay.show(edited, on: NSScreen.underMouse) }
        editor.onPin = { [weak self] edited, frame in self?.pin(edited, near: frame) }
        editor.onClose = { [weak self, weak editor] in
            self?.editors.removeAll { $0 === editor }
        }
        editors.append(editor)
        NSApp.activate()
        editor.showWindow(nil)
    }
}
