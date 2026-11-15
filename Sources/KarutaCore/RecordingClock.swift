import Foundation

/// The recording's elapsed time as the menu bar shows it, kept free of AppKit so karuta-check can test it
/// (docs/refactoring.md K34).
public enum RecordingClock {
    /// " m:ss" with a leading space (it follows the stop icon). Minutes are not rolled over into hours.
    public static func text(elapsed: Int) -> String {
        String(format: " %d:%02d", elapsed / 60, elapsed % 60)
    }
}
