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

        let filter = filter(for: display, content: content)
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
        config.showsCursor = Preferences.showCursor

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Shot(image: image, scale: scale)
    }

    /// Captures every display in full, so area selection can happen on a frozen screen (CleanShot's "Freeze screen").
    static func freezeDisplays(content: SCShareableContent) async -> [CGDirectDisplayID: Shot] {
        var shots: [CGDirectDisplayID: Shot] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            shots[id] = try? await captureDisplay(of: screen, rect: nil, content: content)
        }
        return shots
    }

    /// Cuts `rect` (AppKit global coordinates) out of a full-display `shot` of `screen`.
    /// The result is copied into its own bitmap so the full frozen image can be released.
    static func crop(_ shot: Shot, to rect: CGRect, on screen: NSScreen) -> Shot? {
        let scale = shot.scale
        let pixels = CGRect(
            x: (rect.minX - screen.frame.minX) * scale,
            y: (screen.frame.maxY - rect.maxY) * scale,
            width: rect.width * scale, height: rect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
        guard !pixels.isEmpty, let cropped = shot.image.cropping(to: pixels) else { return nil }

        let colorSpace = cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return Shot(image: cropped, scale: scale) }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage().map { Shot(image: $0, scale: scale) }
    }

    /// Everything on the display except Karuta itself, and (if chosen in Settings) Finder's desktop icons.
    private static func filter(for display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        guard Preferences.hideDesktopIcons else {
            return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        }
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let iconWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer == iconLevel
        }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        return SCContentFilter(display: display, excludingWindows: ownWindows + iconWindows)
    }

    static func captureWindow(_ window: SCWindow) async throws -> Shot {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        // The default background is opaque black, which fills in the window's rounded corners.
        config.backgroundColor = .clear
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
