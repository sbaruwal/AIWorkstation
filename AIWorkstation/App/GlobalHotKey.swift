import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey via Carbon `RegisterEventHotKey` — the standard way to get a
/// global shortcut that fires even when the app is in the background, and (unlike a
/// CGEventTap) needs no Accessibility permission. Degrades silently if registration
/// fails (e.g. the combo is already claimed by another app).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    private static var handlerInstalled = false
    private static var callbacks: [UInt32: () -> Void] = [:]

    /// ⌃⌥Space → summon. Returns nil if the combo couldn't be registered.
    static func summon(_ onPress: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), id: 1, onPress: onPress)
    }

    private init?(keyCode: UInt32, modifiers: UInt32, id: UInt32, onPress: @escaping () -> Void) {
        self.id = id
        GlobalHotKey.installHandlerIfNeeded()
        GlobalHotKey.callbacks[id] = onPress
        var ref: EventHotKeyRef?
        let hotID = EventHotKeyID(signature: OSType(0x41495753), id: id)   // 'AIWS'
        let status = RegisterEventHotKey(keyCode, modifiers, hotID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else {
            GlobalHotKey.callbacks[id] = nil
            return nil
        }
        hotKeyRef = ref
    }

    /// One app-level handler dispatches every hotkey press to its registered callback.
    /// Carbon delivers these on the main run loop, so callbacks run on the main thread.
    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            GlobalHotKey.callbacks[hkID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = (status == noErr)   // only latch on success, so a failed install can retry
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        GlobalHotKey.callbacks[id] = nil
    }
}
