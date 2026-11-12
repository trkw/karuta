import AppKit

// The keyboard: tool keys, Delete, Esc, background and zoom.
extension CanvasView {
    /// Tool keys, Delete, Esc, B (background) and zoom keys (- = 0).
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers.isEmpty, let tool = Tool.allCases.first(where: { $0.key == key }) {
            self.tool = tool
            return
        }
        // 1–6: stroke width, thin to thick.
        if modifiers.isEmpty, let digit = Int(key), (1 ... 6).contains(digit) {
            lineWidth = Self.widthSteps[digit - 1]
            onStateChange?()
            return
        }
        switch (event.keyCode, key) {
        case (51, _), (117, _): // Delete
            if let index = selected {
                var list = annotations
                list.remove(at: index)
                selected = nil
                commit(list)
            } else {
                undo()
            }
        case (53, _): // Esc
            if editingCrop, crop != nil { crop = nil } else { selected = nil }
        case (36, _), (76, _): // Return applies the crop
            if editingCrop { tool = .select } else { super.keyDown(with: event) }
        case (_, "b") where modifiers.isEmpty:
            background.toggle()
        case (_, "="), (_, "+"):
            zoomLevel = min(4, zoom * 1.25)
        case (_, "-"):
            zoomLevel = max(0.1, zoom / 1.25)
        case (_, "0"):
            zoomLevel = nil
        default:
            super.keyDown(with: event)
        }
    }
}
