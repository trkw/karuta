import Foundation

/// How sizes in points are written in the history, the scrolling capture's panel and the editor's crop label,
/// kept free of AppKit so karuta-check can test it (docs/refactoring.md K35). Each place turns pixels into
/// points itself.
public enum SizeText {
    /// "1280 × 720".
    public static func pair(_ width: Int, _ height: Int) -> String {
        "\(width) × \(height)"
    }

    /// "高さ 2400 pt", for the scrolling capture so far.
    public static func height(_ points: Int) -> String {
        "高さ \(points) pt"
    }
}
