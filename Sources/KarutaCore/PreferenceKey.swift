import Foundation

/// The UserDefaults keys Karuta's settings are stored under, in one place (docs/refactoring.md K7).
/// A key is the case name. These strings are already stored on users' Macs: renaming a case loses that
/// setting, so karuta-check pins every one.
public enum PreferenceKey: String, CaseIterable, Sendable {
    case showOverlay, copyToClipboard, copyAreaCaptureToClipboard, saveToFile, freezeScreen, playSound
    case openEditor, showMenuBarIcon, hideDesktopIcons, showLoupe, shutterSound, overlayOnRight
    case overlaySize, autoCloseSeconds, showCursor, scaleRetina, copyAsFile, fileNameTemplate
    case historyDays, selfTimerSeconds, selectionAspect, fixedSelectionSize, backdropStyle, backdropGradient
    case backdropColor, recordingFormat, recordingCountdown, recordingFrameRate, recordSystemAudio, showClicks
    case savedColors, backdropImagePath, autoBackdrop, backdropPadding, format, saveDirectory

    /// The editor's last look for a tool, e.g. "editorStyle.arrow".
    public static func editorStyle(_ tool: String) -> String {
        "editorStyle.\(tool)"
    }

    /// A shortcut, by the `ShortcutAction` raw value, e.g. "shortcut.area".
    public static func shortcut(_ action: String) -> String {
        "shortcut.\(action)"
    }
}
