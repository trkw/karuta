import Foundation
import UniformTypeIdentifiers

/// The image file formats a capture can be saved as, kept free of AppKit so karuta-check can test them
/// (docs/refactoring.md K5). The raw value is what Settings stores.
public enum ImageFormat: String, CaseIterable, Sendable {
    case png, jpeg, heic

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }

    public var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }

    public var title: String { rawValue.uppercased() }
}
