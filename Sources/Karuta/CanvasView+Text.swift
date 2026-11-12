import AppKit

// The text tool: the field that edits a text annotation in place.
extension CanvasView {
    func beginText(at point: NSPoint) {
        textOrigin = point
        let sample = mark(.text(point, ""))
        let font = NSFont.systemFont(ofSize: sample.textFont.pointSize * zoom, weight: .bold)
        let field = NSTextField(frame: NSRect(origin: viewPoint(point),
                                              size: NSSize(width: 260, height: font.boundingRectForFont.height)))
        field.font = font
        field.textColor = color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "テキスト"
        field.delegate = self
        field.target = self
        field.action = #selector(textCommitted)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    @objc private func textCommitted() {
        commitText()
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }

    func commitText() {
        guard let field = textField else { return }
        textField = nil
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if !string.isEmpty {
            commit(annotations + [mark(.text(textOrigin, string), by: .text)])
        }
    }
}
