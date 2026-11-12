import AppKit
import ScreenCaptureKit

// Screen recording: start and stop, the menu bar timer, and handing the video to Quick Access.
extension AppDelegate {
    struct Recording {
        let recorder: ScreenRecorder
        let started: Date
        let screen: NSScreen
        let app: String?
        let format: Preferences.RecordingFormat
        let outline: RecordingFrame?
        let timer: Timer
    }


    private enum RecordingSource {
        case area(CGRect, NSScreen)
        case window(SCWindow)
    }

    /// Stops the recording that's running, or starts one: on `area`, or on an area or window chosen like a
    /// screenshot. The countdown from Settings comes first; the menu bar item then shows the time and stops it.
    func toggleRecording(area: (CGRect, NSScreen)? = nil) {
        if recording != nil {
            stopRecording()
            return
        }
        guard !isCapturing else { return }
        isCapturing = true
        let app = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0.localizedName }
        Task { [self] in
            defer { self.isCapturing = false }
            do {
                let content = try await Capturer.shareableContent()
                let source: RecordingSource
                if let area {
                    source = .area(area.0, area.1)
                } else {
                    let result = await self.selection.run(windowMode: false, candidates: Capturer.orderedWindows(in: content),
                                                          frozen: [:])
                    switch result {
                    case .cancelled: return
                    case let .area(rect, screen): source = .area(rect, screen)
                    case let .window(window): source = .window(window)
                    }
                }

                let config = SCStreamConfiguration()
                config.showsCursor = true
                if #available(macOS 15.0, *) { config.showMouseClicks = Preferences.showClicks }
                let format = Preferences.recordingFormat
                let filter: SCContentFilter
                let frame: NSRect
                let screen: NSScreen
                switch source {
                case let .area(rect, areaScreen):
                    guard let id = areaScreen.displayID, let display = content.displays.first(where: { $0.displayID == id })
                    else { throw CaptureError.displayNotFound }
                    filter = Capturer.recordingFilter(for: display, content: content)
                    config.sourceRect = Capturer.sourceRect(rect, on: areaScreen)
                    let size = ScreenRecorder.outputSize(points: rect.size, scale: areaScreen.backingScaleFactor)
                    config.width = size.width
                    config.height = size.height
                    frame = rect
                    screen = areaScreen
                case let .window(window):
                    filter = SCContentFilter(desktopIndependentWindow: window)
                    let size = ScreenRecorder.outputSize(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
                    config.width = size.width
                    config.height = size.height
                    frame = Geometry.appKitRect(fromCG: window.frame)
                    screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
                        ?? NSScreen.underMouse
                }

                let countdown = Preferences.recordingCountdown
                if countdown > 0 {
                    guard await SelfTimer.countdown(countdown, over: frame) else { return }
                }
                let recorder = ScreenRecorder(url: Exporter.temporaryRecordingURL(app: app))
                recorder.onStop = { [weak self] error in
                    NSLog("Karuta: recording stopped: \(error)")
                    MainActor.assumeIsolated { self?.stopRecording() }
                }
                try await recorder.start(filter: filter, configuration: config, frameRate: Preferences.recordingFrameRate,
                                         audio: format == .mp4 && Preferences.recordSystemAudio)

                var outline: RecordingFrame?
                if case .area = source {
                    outline = RecordingFrame(around: frame)
                    outline?.orderFrontRegardless()
                }
                let started = Date()
                let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.showRecordingStatus(since: started) }
                }
                self.recording = Recording(recorder: recorder, started: started, screen: screen, app: app,
                                           format: format, outline: outline, timer: timer)
                self.showRecordingStatus(since: started)
            } catch {
                NSLog("Karuta: recording failed: \(error)")
                if !CGPreflightScreenCaptureAccess() { self.showPermissionAlert() } else { NSSound.beep() }
            }
        }
    }

    @objc private func stopRecordingClicked() {
        stopRecording()
    }

    func stopRecording() {
        guard let current = recording else { return }
        recording = nil
        current.timer.invalidate()
        current.outline?.orderOut(nil)
        showIdleStatusItem()
        Task {
            do {
                var url = try await current.recorder.stop()
                if Preferences.playSound { Sounds.shutter()?.play() }
                let thumbnail = await ScreenRecorder.thumbnail(of: url)
                if current.format == .gif { url = try await ScreenRecorder.makeGIF(from: url) }
                guard let thumbnail else {
                    // Can't preview it: keep the file and show it.
                    let saved = try Exporter.save(Shot(image: Self.blankImage, scale: 1, app: current.app, video: url))
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                    return
                }
                self.deliverRecording(Shot(image: thumbnail, scale: 1, app: current.app, video: url), on: current.screen)
            } catch {
                NSLog("Karuta: finishing the recording failed: \(error)")
                SaveErrorAlert.show(error, message: "収録を保存できませんでした")
            }
        }
    }

    /// Like a screenshot's After Capture settings, except that it's never left only in the temp folder.
    private func deliverRecording(_ shot: Shot, on screen: NSScreen) {
        if Preferences.copyToClipboard { Exporter.copy(shot) }
        var saved: URL?
        var saveError: Error?
        if Preferences.saveToFile || !Preferences.showOverlay {
            do {
                saved = try Exporter.save(shot)
            } catch {
                NSLog("Karuta: save failed: \(error)")
                saveError = error
            }
        }
        // A recording that couldn't be saved stays in Quick Access (it's still in the temp folder).
        if Preferences.showOverlay || saveError != nil {
            overlay.show(shot, on: screen)
        } else if let saved {
            NSWorkspace.shared.activateFileViewerSelecting([saved])
        }
        if let saveError { QuickOverlay.showSaveError(saveError) }
    }

    private static let blankImage: CGImage = {
        let context = AnnotationRenderer.bitmap(width: 2, height: 2, space: nil)!
        return context.makeImage()!
    }()

    /// The menu bar item becomes a red stop button with the elapsed time.
    private func showRecordingStatus(since started: Date) {
        guard let item = statusItem, let button = item.button else { return }
        let elapsed = Int(Date().timeIntervalSince(started))
        item.isVisible = true
        item.length = NSStatusItem.variableLength
        item.menu = nil
        button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "収録を停止")
        button.contentTintColor = .systemRed
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.title = String(format: " %d:%02d", elapsed / 60, elapsed % 60)
        button.toolTip = "クリックで収録を停止"
        button.target = self
        button.action = #selector(stopRecordingClicked)
    }
}
