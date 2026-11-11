import AppKit

// Menu and shortcut actions: run a shortcut, open the history and the settings.
extension AppDelegate {
    func perform(_ action: ShortcutAction) {
        switch action {
        case .allInOne: capture(.allInOne)
        case .area: capture(.area)
        case .window: capture(.window)
        case .fullscreen: capture(.fullscreen)
        case .previousArea: capture(.previousArea)
        case .selfTimer: capture(.selfTimer)
        case .scrollingCapture: scrollingCapture()
        case .recordScreen: toggleRecording()
        case .areaCopy: capture(.area, delivery: .copy)
        case .areaSave: capture(.area, delivery: .save)
        case .areaAnnotate: capture(.area, delivery: .annotate)
        case .areaPin: capture(.area, delivery: .pin)
        case .openClipboard:
            guard let shot = ImageLoader.shotFromPasteboard() else {
                NSSound.beep()
                return
            }
            openEditor(shot)
        case .openFile:
            if let shot = ImageLoader.chooseImage(prompt: "編集") { openEditor(shot) }
        case .pinFile:
            // Centred on the screen under the mouse.
            if let shot = ImageLoader.chooseImage(prompt: "ピン留め") { pin(shot, near: NSScreen.underMouse.visibleFrame) }
        case .restoreClosed:
            if !overlay.restoreClosed(on: NSScreen.underMouse) { NSSound.beep() }
        case .openHistory: openHistory()
        case .togglePins:
            // Hide them all if any is showing, otherwise bring them all back.
            let anyVisible = pins.contains { $0.isVisible }
            pins.forEach { anyVisible ? $0.orderOut(nil) : $0.orderFrontRegardless() }
        case .unlockPins: pins.forEach { $0.isLocked = false }
        case .closeAllPins: let all = pins; all.forEach { $0.close() }
        case .toggleOverlays: overlay.toggleHidden()
        case .saveAllOverlays: overlay.saveAll()
        case .closeAllOverlays: overlay.closeAll()
        }
    }

    func openHistory() {
        if history == nil {
            let controller = HistoryWindowController()
            controller.onEdit = { [weak self] shot in self?.openEditor(shot) }
            controller.onPin = { [weak self] shot in self?.pin(shot, near: NSScreen.underMouse.visibleFrame) }
            controller.onOverlay = { [weak self] shot in self?.overlay.show(shot, on: NSScreen.underMouse) }
            controller.onClose = { [weak self] in self?.history = nil }
            history = controller
        }
        NSApp.activate()
        history?.showWindow(nil)
        history?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openSettings() {
        showSettings(nil)
    }

    func showSettings(_ page: SettingsPage?) {
        if settings == nil {
            let controller = SettingsWindowController()
            controller.onClose = { [weak self] in self?.settings = nil }
            controller.onRecordingShortcut = { [weak self] recording in
                // Pause global hot keys so the combination being recorded reaches the field.
                if recording { HotKeyCenter.shared.unregisterAll() } else { self?.registerHotKeys() }
            }
            settings = controller
        }
        if let page { settings?.select(page) }
        NSApp.activate()
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }
}
