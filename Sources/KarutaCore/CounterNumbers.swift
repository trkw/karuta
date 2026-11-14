import Foundation

/// The numbers of the editor's counter marks, kept free of AppKit so karuta-check can test them
/// (docs/refactoring.md K22).
public enum CounterNumbers {
    /// The next counter's number: the one set by hand if any, otherwise one past the highest number on
    /// the image (1 when there are none).
    public static func next(existing: [Int], override: Int?) -> Int {
        if let override { return override }
        var highest = 0
        for n in existing { highest = max(highest, n) }
        return highest + 1
    }

    /// A number set by hand never goes below 0.
    public static func clamped(_ value: Int) -> Int { max(0, value) }
}
