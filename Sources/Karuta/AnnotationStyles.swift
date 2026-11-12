import AppKit

/// Looks for the editor's tools, stored in `Annotation.style`. Titles are shown in the toolbar.
enum ArrowStyle: Int, CaseIterable {
    case standard, open, double, curved

    var title: String {
        switch self {
        case .standard: "標準"
        case .open: "線の矢じり"
        case .double: "両端"
        case .curved: "曲線"
        }
    }

    var symbol: String {
        switch self {
        case .standard: "arrow.up.right"
        case .open: "chevron.right"
        case .double: "arrow.left.and.right"
        case .curved: "arrow.turn.up.right"
        }
    }
}

enum TextStyle: Int, CaseIterable {
    case outline, box, plain, shadow

    var title: String {
        switch self {
        case .outline: "縁取り"
        case .box: "背景付き"
        case .plain: "文字だけ"
        case .shadow: "影付き"
        }
    }
}

enum PixelateStyle: Int, CaseIterable {
    case mosaic, blackOut

    var title: String { self == .mosaic ? "モザイク" : "黒塗り" }
}

enum CounterStyle: Int, CaseIterable {
    case numbers, upper, lower

    var title: String {
        switch self {
        case .numbers: "1 2 3"
        case .upper: "A B C"
        case .lower: "a b c"
        }
    }

    /// 1 → "1" / "A" / "a"; past Z it goes on AA, AB, … like spreadsheet columns.
    func label(_ n: Int) -> String {
        guard self != .numbers, n > 0 else { return "\(n)" }
        var n = n, result = ""
        let base = self == .upper ? 65 : 97
        while n > 0 {
            n -= 1
            result = String(Character(UnicodeScalar(UInt8(base + n % 26)))) + result
            n /= 26
        }
        return result
    }
}
