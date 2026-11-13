import Foundation

/// What a capture was taken of. The raw values are stored in the history index.
public enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case area, window, fullscreen
}

/// One capture in the history index (Application Support/Karuta/History/index.json). This JSON is already
/// on users' Macs: the field names and the default `JSONEncoder` date (seconds since 2001) must not change,
/// so karuta-check pins them (docs/refactoring.md K13).
public struct HistoryItem: Codable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let kind: CaptureKind
    public let width: Int
    public let height: Int
    public let scale: Double
    public let app: String?

    public init(id: String, date: Date, kind: CaptureKind, width: Int, height: Int, scale: Double, app: String?) {
        self.id = id
        self.date = date
        self.kind = kind
        self.width = width
        self.height = height
        self.scale = scale
        self.app = app
    }
}
