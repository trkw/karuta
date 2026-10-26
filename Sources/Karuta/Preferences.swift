import AppKit
import Carbon.HIToolbox

/// User settings, stored in UserDefaults. Defaults follow CleanShot: preview on, freeze on, sound on, PNG to Desktop.
enum Preferences {
    static let didChange = Notification.Name("KarutaPreferencesDidChange")

    enum ImageFormat: String, CaseIterable {
        case png, jpeg
        var fileExtension: String { self == .png ? "png" : "jpg" }
    }

    private static let defaults = UserDefaults.standard

    static var showOverlay: Bool {
        get { bool("showOverlay", default: true) }
        set { set(newValue, for: "showOverlay") }
    }

    static var copyToClipboard: Bool {
        get { bool("copyToClipboard", default: false) }
        set { set(newValue, for: "copyToClipboard") }
    }

    static var saveToFile: Bool {
        get { bool("saveToFile", default: false) }
        set { set(newValue, for: "saveToFile") }
    }

    static var freezeScreen: Bool {
        get { bool("freezeScreen", default: true) }
        set { set(newValue, for: "freezeScreen") }
    }

    static var playSound: Bool {
        get { bool("playSound", default: true) }
        set { set(newValue, for: "playSound") }
    }

    static var openEditor: Bool {
        get { bool("openEditor", default: false) }
        set { set(newValue, for: "openEditor") }
    }

    static var showMenuBarIcon: Bool {
        get { bool("showMenuBarIcon", default: true) }
        set { set(newValue, for: "showMenuBarIcon") }
    }

    /// Leaves Finder's desktop icons out of captures (the wallpaper stays).
    static var hideDesktopIcons: Bool {
        get { bool("hideDesktopIcons", default: false) }
        set { set(newValue, for: "hideDesktopIcons") }
    }

    static var showLoupe: Bool {
        get { bool("showLoupe", default: true) }
        set { set(newValue, for: "showLoupe") }
    }

    /// Empty means the system screenshot sound; otherwise the name of a system sound such as "Pop".
    static var shutterSound: String {
        get { defaults.string(forKey: "shutterSound") ?? "" }
        set { set(newValue, for: "shutterSound") }
    }

    /// Seconds before a Quick Access card closes by itself; 0 keeps it.
    static var autoCloseSeconds: Int {
        get { defaults.integer(forKey: "autoCloseSeconds") }
        set { set(newValue, for: "autoCloseSeconds") }
    }

    // MARK: Editor backdrop

    enum BackdropStyle: String, CaseIterable {
        case gradient, solid, wallpaper, image

        var title: String {
            switch self {
            case .gradient: "グラデーション"
            case .solid: "単色"
            case .wallpaper: "壁紙"
            case .image: "画像"
            }
        }
    }

    static var backdropStyle: BackdropStyle {
        get { defaults.string(forKey: "backdropStyle").flatMap(BackdropStyle.init(rawValue:)) ?? .gradient }
        set { set(newValue.rawValue, for: "backdropStyle") }
    }

    /// Index into `Backdrop.gradients`.
    static var backdropGradient: Int {
        get { defaults.integer(forKey: "backdropGradient") }
        set { set(newValue, for: "backdropGradient") }
    }

    static var backdropColor: NSColor {
        get {
            guard let hex = defaults.string(forKey: "backdropColor"), let value = UInt32(hex, radix: 16) else {
                return NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1)
            }
            return NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        set {
            let rgb = newValue.usingColorSpace(.sRGB) ?? .white
            func byte(_ c: CGFloat) -> UInt32 { UInt32((min(max(c, 0), 1) * 255).rounded()) }
            let value = byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent)
            set(String(value, radix: 16), for: "backdropColor")
        }
    }

    /// A picture chosen for the `.image` style.
    static var backdropImagePath: String? {
        get { defaults.string(forKey: "backdropImagePath") }
        set { set(newValue ?? "", for: "backdropImagePath") }
    }

    /// Space around the shot, as a percentage of its shorter side.
    static var backdropPadding: Int {
        get { defaults.object(forKey: "backdropPadding") == nil ? 8 : defaults.integer(forKey: "backdropPadding") }
        set { set(newValue, for: "backdropPadding") }
    }

    static var format: ImageFormat {
        get { defaults.string(forKey: "format").flatMap(ImageFormat.init(rawValue:)) ?? .png }
        set { set(newValue.rawValue, for: "format") }
    }

    static var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: "saveDirectory"),
               FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        set { set(newValue.path, for: "saveDirectory") }
    }

    static func shortcut(for action: ShortcutAction) -> Shortcut? {
        let key = "shortcut.\(action.rawValue)"
        guard let value = defaults.dictionary(forKey: key) else { return action.defaultShortcut }
        guard let code = value["keyCode"] as? Int, let modifiers = value["modifiers"] as? Int else { return nil }
        return Shortcut(keyCode: UInt32(code), modifiers: UInt32(modifiers))
    }

    /// `nil` turns the shortcut off (stored explicitly, so the default doesn't come back).
    static func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        let value: [String: Int] = shortcut.map { ["keyCode": Int($0.keyCode), "modifiers": Int($0.modifiers)] } ?? [:]
        set(value, for: "shortcut.\(action.rawValue)")
    }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    private static func set(_ value: Any, for key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

enum ShortcutAction: String, CaseIterable {
    case area, window, fullscreen, previousArea

    var title: String {
        switch self {
        case .area: "範囲を撮影"
        case .window: "ウィンドウを撮影"
        case .fullscreen: "全画面を撮影"
        case .previousArea: "前回の範囲を撮影"
        }
    }

    /// ⌘⇧4 / ⌘⇧5 / ⌘⇧3 like CleanShot (the macOS screenshot shortcuts must be turned off).
    var defaultShortcut: Shortcut? {
        let commandShift = UInt32(cmdKey | shiftKey)
        switch self {
        case .area: return Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: commandShift)
        case .window: return Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: commandShift)
        case .fullscreen: return Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: commandShift)
        case .previousArea: return nil
        }
    }
}

/// A key code plus Carbon modifier flags, as RegisterEventHotKey takes them.
struct Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From a key press; requires ⌘, ⌃ or ⌥ (function keys may go bare).
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        let isFunctionKey = Self.functionKeys.keys.contains(Int(event.keyCode))
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 || isFunctionKey else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }

    /// For NSMenuItem: the key equivalent and its modifier mask, when the key has a plain character.
    var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags)? {
        guard let key = Self.characters[Int(keyCode)] else { return nil }
        var mask: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        return (key.lowercased(), mask)
    }

    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        let code = Int(keyCode)
        return text + (Self.characters[code] ?? Self.functionKeys[code] ?? Self.specialKeys[code] ?? "#\(code)")
    }

    private static let characters: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]
}
