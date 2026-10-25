import AppKit
@preconcurrency import ScreenCaptureKit

/// A captured image plus the backing scale it was taken at (used for DPI metadata).
struct Shot {
    let image: CGImage
    let scale: CGFloat
}

enum CaptureError: Error {
    case displayNotFound
}

enum Capturer {
    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Captures a whole display, or `rect` (AppKit global coordinates) within it.
    /// Karuta's own windows (selection overlay, quick overlay) are excluded.
    static func captureDisplay(of screen: NSScreen, rect: CGRect?, content: SCShareableContent) async throws -> Shot {
        guard let id = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == id })
        else { throw CaptureError.displayNotFound }

        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let scale = screen.backingScaleFactor

        let config = SCStreamConfiguration()
        var size = CGSize(width: display.width, height: display.height)
        if let rect {
            // sourceRect is in points, relative to the display, with a top-left origin.
            let local = CGRect(
                x: rect.minX - screen.frame.minX,
                y: screen.frame.maxY - rect.maxY,
                width: rect.width, height: rect.height
            )
            config.sourceRect = local
            size = local.size
        }
        config.width = Int((size.width * scale).rounded())
        config.height = Int((size.height * scale).rounded())
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Shot(image: image, scale: scale)
    }

    static func captureWindow(_ window: SCWindow) async throws -> Shot {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Shot(image: image, scale: scale)
    }

    /// Normal app windows on screen, front to back. SCShareableContent has no z-order, so it comes from CGWindowList.
    static func orderedWindows(in content: SCShareableContent) -> [SCWindow] {
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return [] }

        let pid = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let window = byID[CGWindowID(number)],
                  window.owningApplication?.processID != pid,
                  window.frame.width > 40, window.frame.height > 40
            else { return nil }
            return window
        }
    }
}

enum Geometry {
    /// Converts a CoreGraphics global rect (top-left origin) to AppKit global coordinates (bottom-left origin).
    static func appKitRect(fromCG rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static var underMouse: NSScreen {
        let point = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(point, $0.frame, false) } ?? main ?? screens[0]
    }
}
