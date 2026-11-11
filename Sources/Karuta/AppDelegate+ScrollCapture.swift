import AppKit
import ScreenCaptureKit

// Scrolling capture: select an area, scroll through it, and stitch one tall image.
extension AppDelegate {
    /// Captures an area while it scrolls and stitches it into one tall image. Calling it again while it
    /// runs finishes it.
    func scrollingCapture(area: (CGRect, NSScreen)? = nil, autoScroll: Bool = false) {
        if let scrollSession {
            scrollSession.finish()
            return
        }
        guard !isCapturing else { return }
        isCapturing = true
        let app = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0.localizedName }
        Task {
            defer { self.isCapturing = false }
            do {
                let content = try await Capturer.shareableContent()
                let rect: CGRect
                let screen: NSScreen
                if let area {
                    rect = area.0
                    screen = area.1
                } else {
                    let result = await self.selection.run(windowMode: false, candidates: Capturer.orderedWindows(in: content),
                                                          frozen: [:])
                    switch result {
                    case .cancelled:
                        return
                    case let .area(selected, selectedScreen):
                        rect = selected
                        screen = selectedScreen
                    case let .window(window):
                        // A window: its area on the screen it's on (scrolling happens inside it).
                        let frame = Geometry.appKitRect(fromCG: window.frame)
                        guard let windowScreen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return }
                        rect = frame.intersection(windowScreen.frame)
                        screen = windowScreen
                    }
                }
                guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id })
                else { throw CaptureError.displayNotFound }

                let config = SCStreamConfiguration()
                config.sourceRect = Capturer.sourceRect(rect, on: screen)
                config.width = Int((rect.width * screen.backingScaleFactor).rounded())
                config.height = Int((rect.height * screen.backingScaleFactor).rounded())
                config.showsCursor = false
                let session = ScrollCapture(rect: rect, screen: screen,
                                            filter: Capturer.recordingFilter(for: display, content: content), config: config)
                self.scrollSession = session
                let image = await session.run(autoScroll: autoScroll)
                self.scrollSession = nil
                guard let image else { return }
                var shot = Shot(image: image, scale: screen.backingScaleFactor)
                shot.app = app
                self.deliver(shot, on: screen, frame: rect, isWindow: false, kind: .area, delivery: .settings)
            } catch {
                NSLog("Karuta: scrolling capture failed: \(error)")
                if !CGPreflightScreenCaptureAccess() { self.showPermissionAlert() } else { NSSound.beep() }
            }
        }
    }
}
