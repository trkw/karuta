import Foundation

/// The capture history's rules, kept free of AppKit so `karuta-check` can test them (docs/refactoring.md K13).
public enum HistoryRules {
    /// Whether a capture taken at `date` is past the retention period of `days` (Settings). With history
    /// off (0 or less days) everything has expired.
    public static func isExpired(_ date: Date, days: Int, now: Date) -> Bool {
        days <= 0 || date < now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// Where a capture taken at `date` goes in `dates`, which are newest first: before the first older one.
    /// Encodes can finish out of order (a big fullscreen after a small area), so this keeps the order.
    public static func insertionIndex(for date: Date, in dates: [Date]) -> Int {
        dates.firstIndex { $0 < date } ?? dates.count
    }

    /// The captures the history window shows for a kind (nil: all of them), in the given order.
    public static func items(_ items: [HistoryItem], ofKind kind: CaptureKind?) -> [HistoryItem] {
        items.filter { kind == nil || $0.kind == kind }
    }

    /// The kind for the history window's filter segment: 0 is every kind, then the kinds in order.
    public static func kind(forSegment index: Int) -> CaptureKind? {
        index == 0 ? nil : CaptureKind.allCases[index - 1]
    }

    /// The shown items a right click at `index` acts on: the whole selection (in order) when the clicked item
    /// is selected, otherwise that item alone. Indices past the `count` shown items are dropped.
    public static func targets(around index: Int, selected: [Int], count: Int) -> [Int] {
        let selected = selected.sorted()
        let indices = selected.contains(index) ? selected : [index]
        return indices.filter { $0 < count }
    }
}
