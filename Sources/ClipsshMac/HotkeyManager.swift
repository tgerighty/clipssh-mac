import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hotkey through the Carbon Event Manager.
///
/// RegisterEventHotKey needs no Accessibility permission, unlike
/// NSEvent.addGlobalMonitorForEvents. The user therefore sees no prompt.
final class HotkeyManager {
    var onFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handlerInstalled = false
    private static let signature = OSType(0x434C_5053) // 'CLPS'

    init() {
        installHandler()
    }

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// `spec` looks like "cmd+shift+key19" (see `parse`/`spec(keyCode:modifiers:)`
    /// for the grammar — the trailing token is always `key<code>`, a raw
    /// virtual key code, not the character it produces). Returns false if it
    /// cannot be parsed or another application already owns the combination.
    @discardableResult
    func register(_ spec: String?) -> Bool {
        unregister()
        guard let spec, let parsed = Self.parse(spec) else { return false }

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            parsed.keyCode,
            parsed.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr else { return false }
        guard handlerInstalled else {
            // RegisterEventHotKey succeeded, but with no handler installed
            // the keypress would never be delivered — an apparently
            // successful registration that silently never fires.
            UnregisterEventHotKey(reference!)
            return false
        }
        hotKeyRef = reference
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var identifier = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard identifier.signature == HotkeyManager.signature else { return noErr }
                DispatchQueue.main.async { manager.onFire?() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        // Without this, a failed installation leaves register(_:) returning
        // true (RegisterEventHotKey itself can still succeed) while the
        // handler that would have delivered the keypress was never wired up,
        // so the hotkey silently never fires and there is no signal why.
        if status != noErr {
            NSLog("clipssh-mac: hotkey event handler installation failed: \(status)")
            return
        }
        handlerInstalled = true
    }

    static func spec(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append("key\(keyCode)")
        return parts.joined(separator: "+")
    }

    private static func parse(_ spec: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        var keyCode: UInt32?

        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "ctrl": modifiers |= UInt32(controlKey)
            case "alt", "opt", "option": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            default:
                guard part.hasPrefix("key"), let code = UInt32(part.dropFirst(3)) else { return nil }
                keyCode = code
            }
        }
        guard let keyCode, modifiers != 0 else { return nil }
        return (keyCode, modifiers)
    }
}
