import AppKit
import KarutaCore

// The mouse: drawing, selecting, moving and cropping with drags.
extension CanvasView {
    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let p = imagePoint(for: event)
        dragStart = p
        lastDrag = p
        switch tool {
        case .select:
            let tolerance = 6 / zoom
            selected = annotations.indices.reversed().first { annotations[$0].hitTest(p, tolerance: tolerance) }
            if let index = selected {
                var list = annotations
                if event.modifierFlags.contains(.option) {
                    // Option-drag duplicates, like CleanShot.
                    list.append(list[index])
                    selected = list.count - 1
                }
                commit(list)
            }
        case .text:
            beginText(at: p)
            dragStart = nil
        case .counter:
            let next = nextCounter
            counterOverride = nil
            commit(annotations + [mark(.counter(p, next))])
            dragStart = nil
        case .pen, .highlighter:
            preview = mark(tool == .pen ? .pen([p]) : .highlighter([p]))
        default:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = imagePoint(for: event)
        let shift = event.modifierFlags.contains(.shift)
        defer { lastDrag = p }

        switch tool {
        case .select:
            guard let index = selected, let last = lastDrag else { return }
            var list = annotations
            list[index] = list[index].offsetBy(dx: p.x - last.x, dy: p.y - last.y)
            annotations = list // one undo step for the whole move (recorded on mouseDown)
        case .crop:
            crop = Self.rect(from: start, to: p, square: shift).intersection(fullRect)
        case .rect, .filledRect, .ellipse, .pixelate, .blur, .spotlight:
            let r = Self.rect(from: start, to: p, square: shift)
            let kind: Annotation.Kind = switch tool {
            case .rect: .rect(r)
            case .filledRect: .filledRect(r)
            case .ellipse: .ellipse(r)
            case .pixelate: .pixelate(r)
            case .blur: .blur(r)
            default: .spotlight(r)
            }
            preview = mark(kind)
        case .line, .arrow:
            let end = shift ? Self.snap(p, from: start) : p
            preview = mark(tool == .line ? .line(start, end) : .arrow(start, end))
        case .pen, .highlighter:
            guard var current = preview else { return }
            switch current.kind {
            case let .pen(points): current.kind = .pen(points + [p])
            case let .highlighter(points): current.kind = .highlighter(points + [p])
            default: break
            }
            preview = current
        case .text, .counter:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            lastDrag = nil
            preview = nil
        }
        if tool == .crop, let crop, crop.width < 4 || crop.height < 4 {
            self.crop = nil
            return
        }
        guard let preview else { return }
        let box = preview.bounds
        switch preview.kind {
        case let .line(a, b), let .arrow(a, b):
            guard hypot(b.x - a.x, b.y - a.y) >= 4 else { return }
        case .pen, .highlighter:
            break
        default:
            guard box.width >= 4, box.height >= 4 else { return }
        }
        commit(annotations + [preview])
    }

    static let widthSteps: [CGFloat] = [1, 2, 4, 6, 8, 12]

    private static func rect(from a: NSPoint, to b: NSPoint, square: Bool) -> NSRect {
        DrawGeometry.rect(from: a, to: b, square: square)
    }

    /// Shift: lock lines to 45° steps.
    private static func snap(_ p: NSPoint, from start: NSPoint) -> NSPoint {
        DrawGeometry.snap(p, from: start)
    }
}
