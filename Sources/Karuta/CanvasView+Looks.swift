import AppKit
import KarutaCore

// Looks: the style, colour and width that new and selected marks get.
extension CanvasView {
    func style(for tool: Tool) -> Int {
        tool.styleKey.map(Preferences.editorStyle) ?? 0
    }

    /// Remembers the look for the tool, and restyles the selected mark if it was made with that tool.
    func setStyle(_ style: Int, for tool: Tool) {
        guard let key = tool.styleKey else { return }
        Preferences.setEditorStyle(style, for: key)
        if let index = selected, annotations.indices.contains(index), Self.tool(for: annotations[index]) == tool {
            restyleSelection { $0.style = style }
        } else {
            onStateChange?()
        }
    }

    /// The tool whose looks the toolbar offers: the current one, or with Select, the selected mark's.
    var styleTarget: Tool? {
        if tool != .select { return tool.styleKey == nil ? nil : tool }
        guard let index = selected, annotations.indices.contains(index) else { return nil }
        return Self.tool(for: annotations[index])
    }

    private static func tool(for annotation: Annotation) -> Tool? {
        switch annotation.kind {
        case .arrow: .arrow
        case .text: .text
        case .pixelate: .pixelate
        case .counter: .counter
        default: nil
        }
    }

    var nextCounter: Int {
        get {
            let numbers = annotations.compactMap { annotation -> Int? in
                if case let .counter(_, n) = annotation.kind { return n }
                return nil
            }
            return CounterNumbers.next(existing: numbers, override: counterOverride)
        }
        set { counterOverride = CounterNumbers.clamped(newValue) }
    }

    /// The look the toolbar shows: the selected mark's own, else the one new marks get.
    var shownStyle: Int {
        if tool == .select, let index = selected, annotations.indices.contains(index) { return annotations[index].style }
        return styleTarget.map(style(for:)) ?? 0
    }

    /// A new mark in the current color, width and look. `tool` is the tool that made it, when that may
    /// no longer be the current one (text is committed after switching tools).
    func mark(_ kind: Annotation.Kind, by tool: Tool? = nil) -> Annotation {
        Annotation(kind: kind, color: color, width: lineWidth, style: style(for: tool ?? self.tool))
    }
}
