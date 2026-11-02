import AppKit
import AVFoundation
import ScreenCaptureKit

/// Screen recording to an MP4 (H.264): ScreenCaptureKit frames go straight into an AVAssetWriter.
/// Frames arrive on a private queue; start and stop are called from the main actor.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case noFrames

        var errorDescription: String? { "収録できた映像がありませんでした" }
    }

    let url: URL
    /// The stream stopped by itself (e.g. the display went away, or permission was revoked).
    var onStop: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "com.trkw.karuta.recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var finished = false

    init(url: URL) {
        self.url = url
    }

    /// The pixel size to record at: H.264 tops out around 4096 × 2304, so bigger areas are scaled down,
    /// and both sides must be even.
    static func outputSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        var width = points.width * scale, height = points.height * scale
        let fit = min(1, 4096 / max(width, 1), 2304 / max(height, 1))
        width *= fit
        height *= fit
        return (max(2, Int(width) / 2 * 2), max(2, Int(height) / 2 * 2))
    }

    func start(filter: SCContentFilter, configuration config: SCStreamConfiguration) async throws {
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                // About 0.1 bit per pixel at 30 fps: sharp text, reasonable files.
                AVVideoAverageBitRateKey: max(2_000_000, config.width * config.height * 3),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        self.writer = writer
        self.input = input

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only complete frames carry an image; idle ones just say nothing changed.
        guard type == .screen, !finished, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
              as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let writer, let input
        else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onStop?(error) }
    }

    /// Stops and finishes the file. A still screen sends no frames, so the video is ended at the
    /// moment of stopping rather than at the last change.
    func stop() async throws -> URL {
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        if let stream { try? await stream.stopCapture() }
        stream = nil
        let ok: Bool = await withCheckedContinuation { continuation in
            queue.async { [self] in
                finished = true
                guard let writer, let input, sessionStarted else {
                    writer?.cancelWriting()
                    continuation.resume(returning: false)
                    return
                }
                input.markAsFinished()
                writer.endSession(atSourceTime: end)
                writer.finishWriting { continuation.resume(returning: writer.status == .completed) }
            }
        }
        guard ok else {
            try? FileManager.default.removeItem(at: url)
            throw writer?.error ?? RecorderError.noFrames
        }
        return url
    }

    /// The first frame, for the Quick Access card.
    static func thumbnail(of url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        return try? await generator.image(at: .zero).image
    }
}

/// A thin outline around the area being recorded. Karuta's own windows are left out of the recording.
final class RecordingFrame: NSPanel {
    init(around rect: NSRect) {
        let outset: CGFloat = 3
        super.init(contentRect: rect.insetBy(dx: -outset, dy: -outset), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = OutlineView()
    }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 2
            NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.stroke()
        }
    }
}
