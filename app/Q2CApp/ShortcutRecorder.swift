import AppKit
import SwiftUI
import Q2CCore

/// Receives key events only while this local control is focused; no global monitor.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Q2CCore.KeyboardShortcut
    var isEnabled: Bool
    var isEnglish = false

    func makeNSView(context: Context) -> RecorderButton { RecorderButton(frame: .zero) }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.isEnglish = isEnglish
        button.setAccessibilityLabel(isEnglish ? "Change shortcut" : "自定义快捷键")
        button.shortcut = shortcut
        button.isEnabled = isEnabled
        button.onChange = { shortcut = $0 }
        button.refreshTitle()
    }
}

@MainActor
final class RecorderButton: NSButton {
    var shortcut: Q2CCore.KeyboardShortcut = .standard
    var onChange: ((Q2CCore.KeyboardShortcut) -> Void)?
    var isEnglish = false
    private var recording = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        setAccessibilityLabel("自定义快捷键")
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var acceptsFirstResponder: Bool { true }
    override var isEnabled: Bool {
        didSet { if !isEnabled { recording = false; refreshTitle() } }
    }

    func refreshTitle() {
        title = recording
            ? (isEnglish ? "Press keys… (Esc cancels)" : "请按快捷键…（Esc 取消）")
            : shortcut.displayName + (isEnglish ? " · Edit" : " · 点击修改")
    }

    @objc private func startRecording() {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        recording = true
        refreshTitle()
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        refreshTitle()
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, isEnabled, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording, isEnabled else { super.keyDown(with: event); return }
        guard !event.isARepeat else { return }
        var modifiers: ShortcutModifiers = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.keyCode == 53 && modifiers.isEmpty {
            recording = false
            refreshTitle()
            return
        }
        let code = UInt32(event.keyCode)
        if code == 53 {
            title = isEnglish ? "Escape is reserved for cancel" : "Esc 留给取消操作"
            return
        }
        let special: [UInt32: String] = [36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "Esc", 76: "⌤",
                                         114: "Help", 115: "Home", 116: "PageUp", 117: "⌦", 119: "End",
                                         121: "PageDown", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let label = Q2CCore.KeyboardShortcut.functionKeys[code] ?? special[code]
            ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let value = Q2CCore.KeyboardShortcut(keyCode: code, modifiers: modifiers, keyLabel: label)
        if value.isReservedSystemShortcut {
            title = isEnglish ? "System shortcut reserved" : "常用系统快捷键不可设置"
            return
        }
        do {
            try value.validate()
            shortcut = value
            recording = false
            refreshTitle()
            onChange?(value)
        } catch {
            title = isEnglish ? "Use a modifier plus a key" : "请使用修饰键 + 普通按键"
        }
    }
}
