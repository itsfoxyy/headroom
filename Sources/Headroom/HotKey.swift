import AppKit
import Carbon.HIToolbox

/// One system-wide keyboard shortcut, with separate press and release callbacks.
final class HotKey {
    enum RegistrationError: Error { case inUse, failed(OSStatus) }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var ref: EventHotKeyRef?
    private static var handlerInstalled = false
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init() {
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.instances[id] = self
        HotKey.installHandlerIfNeeded()
    }

    deinit {
        unregister()
        HotKey.instances[id] = nil
    }

    func register(_ shortcut: Shortcut) throws {
        unregister()
        let hotKeyID = EventHotKeyID(signature: OSType(0x48_44_52_4D), id: id) // "HDRM"
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let registered = newRef else {
            throw status == OSStatus(eventHotKeyExistsErr) ? RegistrationError.inUse : RegistrationError.failed(status)
        }
        ref = registered
    }

    func unregister() {
        if let ref = ref {
            UnregisterEventHotKey(ref)
        }
        ref = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event = event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, let hotKey = HotKey.instances[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            let kind = GetEventKind(event)
            DispatchQueue.main.async {
                if kind == UInt32(kEventHotKeyPressed) {
                    hotKey.onPress?()
                } else if kind == UInt32(kEventHotKeyReleased) {
                    hotKey.onRelease?()
                }
            }
            return noErr
        }, types.count, &types, nil, nil)
    }
}

/// Converts AppKit modifier flags to the Carbon flags RegisterEventHotKey wants.
enum CarbonModifiers {
    static func from(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
