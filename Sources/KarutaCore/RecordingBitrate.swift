import Foundation

/// The recording's average bit rate, kept free of AVFoundation so karuta-check can test it
/// (docs/refactoring.md K36).
public enum RecordingBitrate {
    /// About 0.1 bit per pixel at 30 fps: sharp text, reasonable files. Never below 2,000,000.
    public static func bitsPerSecond(width: Int, height: Int, frameRate: Int) -> Int {
        max(2_000_000, width * height * 3 * frameRate / 30)
    }
}
