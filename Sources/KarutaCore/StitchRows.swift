import Foundation

/// The pixel-row arithmetic of a scrolling capture, kept free of AppKit so karuta-check can test it with
/// made-up rows (docs/refactoring.md K15). Stitcher in the app does the image work and calls these.
public enum StitchRows {
    /// Pixels at the right edge never matched: the scroll bar fades in and moves while scrolling.
    public static let scrollBarWidth = 24

    /// The scroll distance in rows: the smallest shift `s` where the new frame's rows from `lo` match the
    /// previous frame's from `lo + s` best (at least 90% of the overlap, which must be a sixth of the span).
    public static func shift(_ old: [UInt64], _ new: [UInt64], lo: Int, hi: Int) -> Int? {
        let span = hi - lo
        let minOverlap = max(12, span / 6)
        guard span - minOverlap >= 1 else { return nil }
        var best: (shift: Int, score: Double)?
        for s in 1 ... (span - minOverlap) {
            let overlap = span - s
            var matches = 0
            for i in 0 ..< overlap where new[lo + i] == old[lo + s + i] { matches += 1 }
            let score = Double(matches) / Double(overlap)
            if score > (best?.score ?? 0.9) { best = (s, score) }
            if score == 1 { break } // can't do better; keep the smallest such shift
        }
        return best?.shift
    }

    /// The columns to match: from the first to the last column that changed between the two frames,
    /// leaving out unchanged ones at either side and the scroll bar at the right edge. Nil when nothing moved.
    public static func movingColumns(_ old: [UInt32], _ new: [UInt32], width: Int, height: Int) -> Range<Int>? {
        var changed = [Bool](repeating: false, count: width)
        old.withUnsafeBufferPointer { a in
            new.withUnsafeBufferPointer { b in
                for y in 0 ..< height {
                    let row = y * width
                    for x in 0 ..< width where !changed[x] && a[row + x] != b[row + x] { changed[x] = true }
                }
            }
        }
        guard let first = changed.firstIndex(of: true), let last = changed.lastIndex(of: true) else { return nil }
        // A narrow area is matched whole; otherwise a change in the scroll bar alone isn't a scroll.
        guard width >= scrollBarWidth * 4 else { return first ..< last + 1 }
        let end = min(last + 1, width - scrollBarWidth)
        return first < end ? first ..< end : nil
    }

    /// One hash per pixel row, over `columns` (every other pixel).
    public static func rowHashes(_ pixels: [UInt32], width: Int, columns: Range<Int>) -> [UInt64] {
        let height = pixels.count / max(width, 1)
        var hashes = [UInt64](repeating: 0, count: height)
        pixels.withUnsafeBufferPointer { p in
            for y in 0 ..< height {
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                var i = y * width + columns.lowerBound
                let end = y * width + columns.upperBound
                while i < end {
                    hash = (hash ^ UInt64(p[i] & 0x00ff_ffff)) &* 0x0000_0100_0000_01b3
                    i += 2
                }
                hashes[y] = hash
            }
        }
        return hashes
    }

    /// Rows `from ..< to` (top-origin) copied into their own bitmap, so the frame can be released.

    /// The rows at the top and at the bottom that are the same in both frames (sticky headers, toolbars,
    /// footers). The top band is counted first, so equal frames are all top band.
    public static func unmovedBands(_ old: [UInt64], _ new: [UInt64]) -> (top: Int, bottom: Int) {
        let rows = new, oldRows = old
        let h = rows.count
        var top = 0
        while top < h, rows[top] == oldRows[top] { top += 1 }
        var bottom = 0
        while bottom < h - top, rows[h - 1 - bottom] == oldRows[h - 1 - bottom] { bottom += 1 }
        return (top, bottom)
    }

    /// Where a continuing frame's rows go. Rows kept from earlier frames past `hi` turn out to be a fixed
    /// footer, and `trim` of them come off the end when anything is kept; the new frame's rows from `start`
    /// to `hi` are added (none when `start` is at or past `hi`).
    public static func continuation(keptEnd: Int, lo: Int, hi: Int, shift: Int, hasKept: Bool) -> (trim: Int, start: Int) {
        var kept = keptEnd, trim = 0
        if kept > hi, hasKept {
            trim = kept - hi
            kept = hi
        }
        // The previous frame's row r is this frame's row r - shift.
        return (trim, max(lo, kept - shift))
    }
}
