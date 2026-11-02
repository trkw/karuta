import AppKit

/// `karuta://` commands, laid out like CleanShot's URL scheme API so Shortcuts, Raycast, Alfred or a
/// script can drive Karuta: `open "karuta://capture-area?action=copy"`.
///
/// Areas are `x`, `y`, `width`, `height` in points from the bottom-left corner of the display, and
/// `display` is 1 for the main display, 2 for the next (default: the one under the mouse).
/// `action` is copy, save, annotate or pin (default: the After Capture settings).
enum URLCommand {
    case capture(AppDelegate.CaptureMode, AppDelegate.Delivery)
    case captureRect(CGRect, NSScreen, AppDelegate.Delivery) // AppKit global coordinates
    case allInOne(initial: CGRect?)
    case pin(URL?)
    case annotate(URL?)
    case openClipboard
    case addOverlay(URL)
    case openHistory
    case restoreClosed
    case openSettings(SettingsPage)
    case shortcut(ShortcutAction)

    @MainActor
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "karuta" else { return nil }
        // karuta://capture-area puts the command in the host; karuta:capture-area or karuta:///capture-area in the path.
        let name = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name.lowercased()] = item.value ?? ""
        }
        let delivery = Self.delivery(query["action"])
        var file: URL?
        if let path = query["filepath"], !path.isEmpty {
            file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }

        switch name {
        case "capture-area":
            if let area = Self.area(query) {
                self = .captureRect(area.0, area.1, delivery)
            } else {
                self = .capture(.area, delivery)
            }
        case "capture-previous-area": self = .capture(.previousArea, delivery)
        case "capture-fullscreen": self = .capture(.fullscreen, delivery)
        case "capture-window": self = .capture(.window, delivery)
        case "self-timer": self = .capture(.selfTimer, delivery)
        case "all-in-one": self = .allInOne(initial: Self.area(query)?.0)
        case "pin": self = .pin(file)
        case "open-annotate": self = .annotate(file)
        case "open-from-clipboard": self = .openClipboard
        case "add-quick-access-overlay":
            guard let file else { return nil }
            self = .addOverlay(file)
        case "open-history": self = .openHistory
        case "restore-recently-closed": self = .restoreClosed
        case "open-settings": self = .openSettings(Self.page(query["tab"]))
        // Karuta's own, for the shortcuts that have no CleanShot command.
        case "toggle-overlays": self = .shortcut(.toggleOverlays)
        case "save-all-overlays": self = .shortcut(.saveAllOverlays)
        case "close-all-overlays": self = .shortcut(.closeAllOverlays)
        case "toggle-pins": self = .shortcut(.togglePins)
        case "unlock-pins": self = .shortcut(.unlockPins)
        case "close-all-pins": self = .shortcut(.closeAllPins)
        default: return nil
        }
    }

    private static func delivery(_ action: String?) -> AppDelegate.Delivery {
        switch action?.lowercased() {
        case "copy": .copy
        case "save": .save
        case "annotate": .annotate
        case "pin": .pin
        default: .settings
        }
    }

    /// The area given by x, y, width, height (all four needed) on `display`, in AppKit global coordinates.
    @MainActor
    private static func area(_ query: [String: String]) -> (CGRect, NSScreen)? {
        func number(_ key: String) -> CGFloat? { query[key].flatMap(Double.init).map { CGFloat($0) } }
        guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height"),
              width >= 1, height >= 1
        else { return nil }
        let screens = NSScreen.screens
        let screen: NSScreen
        if let display = query["display"].flatMap(Int.init) {
            guard screens.indices.contains(display - 1) else { return nil }
            screen = screens[display - 1]
        } else {
            screen = NSScreen.underMouse
        }
        let rect = CGRect(x: screen.frame.minX + x, y: screen.frame.minY + y, width: width, height: height)
            .intersection(screen.frame)
        return rect.width >= 1 && rect.height >= 1 ? (rect, screen) : nil
    }

    /// CleanShot's tab names, mapped to Karuta's pages (unknown ones open General).
    private static func page(_ tab: String?) -> SettingsPage {
        switch tab?.lowercased() {
        case "shortcuts": .shortcuts
        case "quickaccess", "quick-access": .quickAccess
        case "screenshots", "annotate", "wallpaper": .screenshots
        case "about": .about
        default: .general
        }
    }
}
