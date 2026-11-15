import Foundation

/// How a recording becomes a GIF, kept free of AppKit so karuta-check can test it (docs/refactoring.md K18).
public enum GIFFrames {
    /// Frames per second in the GIF.
    public static let fps = 15.0

    /// How many frames to take from a movie of `duration` seconds: at least 1, at most 120 seconds' worth.
    public static func count(duration: Double) -> Int {
        max(1, min(Int(duration * fps), Int(120 * fps)))
    }
}
