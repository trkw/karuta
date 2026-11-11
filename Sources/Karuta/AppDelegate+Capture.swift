import AppKit
import ScreenCaptureKit

// Capturing: pick the area, window or screen, take the shot and hand it to deliver.
extension AppDelegate {
    /// `initial` overrides All-In-One's starting area (normally the previous one).
    func capture(_ mode: CaptureMode, delivery: Delivery = .settings, initial: CGRect? = nil) {
        guard !isCapturing else { return }
        isCapturing = true
        // Before the selection overlay brings Karuta forward: the app being captured, for the file name.
        let app = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0.localizedName }
        Task {
            defer { self.isCapturing = false }
            do {
                let content = try await Capturer.shareableContent()
                var shot: Shot
                let screen: NSScreen
                let frame: NSRect // where the shot was on screen (AppKit global), for pinning it in place
                var delivery = delivery
                var isWindow = false
                switch mode {
                case .fullscreen:
                    screen = NSScreen.underMouse
                    frame = screen.frame
                    shot = try await Capturer.captureDisplay(of: screen, rect: nil, content: content)
                case let .fixed(rect, fixedScreen):
                    screen = fixedScreen
                    frame = rect
                    // Like a dragged area, it becomes the previous area.
                    if let id = screen.displayID {
                        self.lastArea = (rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), id)
                    }
                    shot = try await Capturer.captureDisplay(of: screen, rect: rect, content: content)
                case .previousArea:
                    guard let last = self.lastArea,
                          let lastScreen = NSScreen.screens.first(where: { $0.displayID == last.displayID })
                    else {
                        NSSound.beep()
                        return
                    }
                    let rect = last.rect.offsetBy(dx: lastScreen.frame.minX, dy: lastScreen.frame.minY)
                        .intersection(lastScreen.frame)
                    guard !rect.isEmpty else {
                        NSSound.beep()
                        return
                    }
                    screen = lastScreen
                    frame = rect
                    shot = try await Capturer.captureDisplay(of: screen, rect: rect, content: content)
                case .area, .window, .selfTimer, .allInOne:
                    var timed = mode == .selfTimer
                    let candidates = Capturer.orderedWindows(in: content)
                    // Freeze the screen first, so the selection is made on (and cut from) a still image.
                    // The self-timer captures the live screen after the countdown, so it never freezes.
                    var frozen: [CGDirectDisplayID: Shot] = [:]
                    if Preferences.freezeScreen && !timed { frozen = await Capturer.freezeDisplays(content: content) }
                    // All-In-One starts on the given area or the previous one, ready to adjust.
                    var start: CGRect?
                    if mode == .allInOne {
                        start = initial ?? self.lastArea.flatMap { last in
                            NSScreen.screens.first { $0.displayID == last.displayID }
                                .map { last.rect.offsetBy(dx: $0.frame.minX, dy: $0.frame.minY) }
                        }
                    }
                    let result = await self.selection.run(windowMode: mode == .window, candidates: candidates,
                                                          frozen: frozen, allInOne: mode == .allInOne,
                                                          initial: start)
                    if mode == .allInOne {
                        switch self.selection.action {
                        case .capture: break
                        case .copy: delivery = .copy
                        case .save: delivery = .save
                        case .annotate: delivery = .annotate
                        case .pin: delivery = .pin
                        case .timer: timed = true
                        }
                    }
                    // Holding ⌃ while finishing the selection copies instead (CleanShot does the same).
                    if delivery == .settings && NSEvent.modifierFlags.contains(.control) { delivery = .copy }
                    switch result {
                    case .cancelled:
                        return
                    case let .area(rect, selectedScreen):
                        screen = selectedScreen
                        frame = rect
                        let id = screen.displayID
                        if let id { self.lastArea = (rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), id) }
                        if timed {
                            guard await SelfTimer.countdown(Preferences.selfTimerSeconds, over: rect) else { return }
                            // The screen has changed during the countdown (that's the point), so ask again.
                            let fresh = try await Capturer.shareableContent()
                            shot = try await Capturer.captureDisplay(of: screen, rect: rect, content: fresh)
                        } else if let full = id.flatMap({ frozen[$0] }),
                                  let cropped = Capturer.crop(full, to: rect, on: screen) {
                            shot = cropped
                        } else {
                            shot = try await Capturer.captureDisplay(of: screen, rect: rect, content: content)
                        }
                    case let .window(window):
                        screen = NSScreen.underMouse
                        frame = Geometry.appKitRect(fromCG: window.frame)
                        if timed {
                            guard await SelfTimer.countdown(Preferences.selfTimerSeconds, over: frame) else { return }
                        }
                        shot = try await Capturer.captureWindow(window)
                        isWindow = true
                    }
                }
                shot.app = app
                let kind: CaptureHistory.Kind = mode == .fullscreen ? .fullscreen : isWindow ? .window : .area
                self.deliver(shot, on: screen, frame: frame, isWindow: isWindow, kind: kind, delivery: delivery)
            } catch {
                NSLog("Karuta: capture failed: \(error)")
                if !CGPreflightScreenCaptureAccess() { self.showPermissionAlert() }
            }
        }
    }
}
