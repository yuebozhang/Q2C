import AppKit
import Carbon
import Q2CCore

/// Carbon hot keys do not monitor keystrokes and do not need Accessibility access.
/// Registration happens only after an explicit click, and is never persisted.
@MainActor
final class GlobalShortcut {
    private static var nextIdentifier: UInt32 = 0
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private var identifier = EventHotKeyID(signature: 0x51324331, id: 0)

    func enable(shortcut: KeyboardShortcut, action: @escaping () -> Void) throws {
        disable()
        try shortcut.validate()
        self.action = action
        Self.nextIdentifier &+= 1
        identifier = EventHotKeyID(signature: 0x51324331, id: Self.nextIdentifier)
        let registrationID = identifier
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            var handled = false
            MainActor.assumeIsolated {
                let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
                guard identifier.signature == owner.identifier.signature,
                      identifier.id == owner.identifier.id else { return }
                DiagnosticLog.shared.record("shortcut.received", fields: ["registration": String(identifier.id)])
                owner.action?()
                handled = true
            }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &type, context, &handler)
        DiagnosticLog.shared.record("shortcut.handler", fields: ["osStatus": String(status)])
        guard status == noErr else { disable(); throw ShortcutError.registrationFailed }
        var modifiers: UInt32 = 0
        if shortcut.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if shortcut.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        let registration = RegisterEventHotKey(shortcut.keyCode, modifiers, registrationID, GetApplicationEventTarget(), 0, &hotKey)
        DiagnosticLog.shared.record("shortcut.registration", fields: ["osStatus": String(registration), "keyCode": String(shortcut.keyCode), "modifiers": String(modifiers)])
        guard registration == noErr else { disable(); throw ShortcutError.registrationFailed }
    }

    func disable() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        action = nil
    }
}

private enum ShortcutError: LocalizedError {
    case registrationFailed
    var errorDescription: String? { "快捷键注册失败，可能已被其他应用占用。请选择其他按键。" }
}
