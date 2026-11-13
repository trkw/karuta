import AppKit
import AVFoundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

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
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var finished = false

    init(url: URL) {
        self.url = url
    }

    /// `audio` adds the Mac's own sound (apps and videos, not Karuta) as an AAC track.
    func start(filter: SCContentFilter, configuration config: SCStreamConfiguration, frameRate: Int,
               audio: Bool) async throws {
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
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
                AVVideoAverageBitRateKey: max(2_000_000, config.width * config.height * 3 * frameRate / 30),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.add(input)
        if audio {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioInput = audioInput
            }
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        self.writer = writer
        self.input = input

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audioInput != nil { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            // Sound starts with the first picture, so the two tracks line up.
            guard !finished, sessionStarted, sampleBuffer.isValid, let audioInput, audioInput.isReadyForMoreMediaData
            else { return }
            audioInput.append(sampleBuffer)
            return
        }
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
                audioInput?.markAsFinished()
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

    /// Turns a recording into a looping GIF (15 fps, at most 960 pixels wide, two minutes at most) and
    /// removes the MP4.
    static func makeGIF(from movie: URL) async throws -> URL {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let fps = 15.0
        let count = max(1, min(Int(duration * fps), Int(120 * fps)))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 4000)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // Never replace an earlier GIF: a Quick Access card or the clipboard may still point at it.
        let base = movie.deletingPathExtension()
        var gif = base.appendingPathExtension("gif")
        var n = 2
        while FileManager.default.fileExists(atPath: gif.path) {
            gif = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent) (\(n)).gif")
            n += 1
        }
        guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: 1 / fps, kCGImagePropertyGIFUnclampedDelayTime: 1 / fps,
        ]]
        let times = (0 ..< count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }
        var added = 0
        for await result in generator.images(for: times) {
            // A frame that can't be read (e.g. past the end) is skipped; the rest keep their timing.
            guard let image = try? result.image else { continue }
            CGImageDestinationAddImage(destination, image, delay as CFDictionary)
            added += 1
        }
        guard added > 0, CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: gif)
            throw RecorderError.noFrames
        }
        try? FileManager.default.removeItem(at: movie)
        return gif
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
