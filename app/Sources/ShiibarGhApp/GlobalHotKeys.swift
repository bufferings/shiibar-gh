// The system side of the global shortcuts (DESIGN.md, "Global shortcut"):
// Carbon's `RegisterEventHotKey` on the application event target, one
// registration per account, told apart by `EventHotKeyID.id`. Not exclusive
// (`inOptions` 0): CarbonEvents.h, macOS 27.2 SDK. Tests use a spy
// registrar instead and never register a real hotkey.

import AppKit
import Carbon.HIToolbox
import os
import ShiibarGhCore

private let hotKeyLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "shiibar-gh", category: "hotkey")

@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistering {
    var onPressed: (UInt32) -> Void = { _ in }
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    /// "SHGH": this app's hotkey signature.
    static let signature: OSType = 0x5348_4748

    func register(_ shortcut: GlobalShortcut, id: UInt32) -> Bool {
        unregister(id: id)
        guard installHandler() else { return false }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            hotKeyLog.error("RegisterEventHotKey failed: \(status, privacy: .public) for \(shortcut.displayString, privacy: .public)")
            return false
        }
        refs[id] = ref
        return true
    }

    func unregister(id: UInt32) {
        guard let ref = refs.removeValue(forKey: id) else { return }
        let status = UnregisterEventHotKey(ref)
        if status != noErr { hotKeyLog.error("UnregisterEventHotKey failed: \(status, privacy: .public)") }
    }

    /// The pressed handler, installed once. The hotkey's id is the event's
    /// direct object (`kEventParamDirectObject`, `typeEventHotKeyID`).
    private func installHandler() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id
                )
                guard read == noErr, id.signature == CarbonHotKeyRegistrar.signature else { return OSStatus(eventNotHandledErr) }
                let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                // The application event target dispatches on the main thread.
                MainActor.assumeIsolated { registrar.onPressed(id.id) }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        if status != noErr {
            hotKeyLog.error("InstallEventHandler failed: \(status, privacy: .public)")
            return false
        }
        return true
    }

    /// Carbon's modifier bits (`cmdKey`, `shiftKey`, `optionKey`,
    /// `controlKey`; HIToolbox `Events.h`).
    static func carbonModifiers(_ modifiers: ShortcutModifiers) -> UInt32 {
        var out: UInt32 = 0
        if modifiers.contains(.command) { out |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { out |= UInt32(shiftKey) }
        if modifiers.contains(.option) { out |= UInt32(optionKey) }
        if modifiers.contains(.control) { out |= UInt32(controlKey) }
        return out
    }

    /// The modifiers of a key event.
    static func modifiers(of flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var out: ShortcutModifiers = []
        if flags.contains(.control) { out.insert(.control) }
        if flags.contains(.option) { out.insert(.option) }
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.command) { out.insert(.command) }
        return out
    }

    /// The name of a key event's key: what the keyboard layout types for it
    /// without modifiers.
    static func keyName(of event: NSEvent) -> String? {
        ShortcutKeys.keyName(keyCode: event.keyCode, characters: event.characters(byApplyingModifiers: []))
    }
}
