import AppKit
import KarutaCore

// MARK: - Stitching

/// Joins frames of the same size, top to bottom. Each frame's rows are hashed; the scroll distance is the
/// shift that lines the most rows up with the previous frame. Only new rows are kept (copied out), so
/// memory grows with the result, not with the number of frames.
///
/// Columns that didn't change between two frames (a fixed sidebar beside the page) are left out of the
/// hashes, and so is the right edge, where an overlay scroll bar appears while scrolling: only the part
/// that moves is matched.
struct Stitcher {
    private struct Frame {
        let image: CGImage
        let pixels: [UInt32] // top row first
    }

    /// A tall page is cut off here (pixels), to keep the image manageable.
    static let maxHeight = 32000

    private var previous: Frame?
    /// Kept rows, top to bottom; the last frame's bottom band (a sticky footer) goes after them.
    private var segments: [CGImage] = []
    private var footer: CGImage?
    /// The previous frame's row (top-origin) where the kept page content ends; below it is its footer.
    private var keptEnd = 0

    var height: Int { segments.reduce(0) { $0 + $1.height } + (footer?.height ?? 0) }
    var isFull: Bool { height >= Self.maxHeight }

    /// Returns whether the frame added anything.
    mutating func add(_ image: CGImage) -> Bool {
        guard let pixels = Self.pixels(image) else { return false }
        let frame = Frame(image: image, pixels: pixels)
        guard let previous else {
            self.previous = frame
            segments = [Self.copyRows(image, 0, image.height)].compactMap { $0 }
            keptEnd = image.height
            return true
        }
        guard image.width == previous.image.width, image.height == previous.image.height,
              let columns = StitchRows.movingColumns(previous.pixels, pixels, width: image.width, height: image.height)
        else { return false }
        let oldRows = StitchRows.rowHashes(previous.pixels, width: image.width, columns: columns)
        let rows = StitchRows.rowHashes(pixels, width: image.width, columns: columns)

        // Bands that didn't move at all: sticky headers at the top, toolbars or footers at the bottom.
        let h = rows.count
        let (top, bottom) = StitchRows.unmovedBands(oldRows, rows)
        let lo = top, hi = h - bottom
        let span = hi - lo
        guard span >= 24, let shift = StitchRows.shift(oldRows, rows, lo: lo, hi: hi) else {
            // Scrolled back up, or the content changed: wait for a frame that continues the page.
            return false
        }

        let next = StitchRows.continuation(keptEnd: keptEnd, lo: lo, hi: hi, shift: shift, hasKept: !segments.isEmpty)
        // Rows kept as page content that turn out to be a fixed footer come off the end.
        if next.trim > 0, let last = segments.last {
            let extra = min(next.trim, last.height)
            if extra == last.height {
                segments.removeLast()
            } else if let trimmed = Self.copyRows(last, 0, last.height - extra) {
                segments[segments.count - 1] = trimmed
            }
            keptEnd = hi
        }
        let start = next.start
        if hi > start, let added = Self.copyRows(image, start, hi) { segments.append(added) }
        footer = bottom > 0 ? Self.copyRows(image, hi, h) : nil
        keptEnd = hi
        self.previous = frame
        return hi > start
    }

    /// The image as 32-bit pixels, top row first.
    private static func pixels(_ image: CGImage) -> [UInt32]? {
        let width = image.width, height = image.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    private static func copyRows(_ image: CGImage, _ from: Int, _ to: Int) -> CGImage? {
        guard to > from, let cropped = image.cropping(to: CGRect(x: 0, y: from, width: image.width, height: to - from)),
              let context = AnnotationRenderer.bitmap(width: cropped.width, height: cropped.height, space: image.colorSpace)
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage()
    }

    /// Everything kept so far, as one image.
    func image() -> CGImage? {
        let parts = segments + (footer.map { [$0] } ?? [])
        guard let width = parts.first?.width else { return nil }
        let total = parts.reduce(0) { $0 + $1.height }
        guard let context = AnnotationRenderer.bitmap(width: width, height: total, space: parts.first?.colorSpace)
        else { return nil }
        var y = total // drawing from the top down, in a bottom-left-origin context
        for part in parts {
            y -= part.height
            context.draw(part, in: CGRect(x: 0, y: y, width: part.width, height: part.height))
        }
        return context.makeImage()
    }
}
