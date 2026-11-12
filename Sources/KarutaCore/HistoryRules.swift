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
}
