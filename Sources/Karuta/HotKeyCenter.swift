import AppKit
import Carbon.HIToolbox

/// Global hot keys via Carbon's RegisterEventHotKey: no extra dependency and no accessibility permission needed.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private static let signature: OSType = 0x4B52_5441 // "KRTA"

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            NSLog("Karuta: failed to register hot key \(keyCode) (\(status))")
            return
        }
        refs.append(ref)
        actions[id] = action
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), handleHotKeyEvent, 1, &spec, nil, &eventHandler)
    }
}

private func handleHotKeyEvent(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    // Carbon delivers application events on the main thread.
    MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
    return noErr
}
