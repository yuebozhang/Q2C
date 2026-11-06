import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let control = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let shift = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
    public static let all: Self = [.control, .option, .shift, .command]

    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
        + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers
    public var keyLabel: String

    public init(keyCode: UInt32, modifiers: ShortcutModifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public static let standard = Self(keyCode: 8, modifiers: [.command, .option], keyLabel: "C")
    public static let previousStandard = Self(keyCode: 1, modifiers: [.command, .shift], keyLabel: "S")
    public var displayName: String { modifiers.symbols + keyLabel }
    public var isReservedSystemShortcut: Bool {
        // Keep common macOS commands available while allowing ordinary app-level chords such as ⌘D.
        if keyCode == 53 { return true } // Escape always cancels target selection.
        if modifiers == [.command] && [0, 4, 7, 8, 9, 12, 13, 46, 48, 49, 50].contains(keyCode) {
            return true // A, H, X, C, V, Q, W, M, Tab, Space, grave.
        }
        if modifiers == [.command, .shift] && [12, 13, 20, 21, 23, 48, 50].contains(keyCode) {
            return true // Log out, close all windows, screenshots, reverse app/window switching.
        }
        if modifiers == [.command, .option] && [2, 46, 49, 53].contains(keyCode) {
            return true // Toggle Dock, minimize all windows, alternate Spotlight, Force Quit.
        }
        if modifiers == [.command, .option, .shift] && keyCode == 12 { return true } // Immediate log out.
        if modifiers == [.command, .control] && [12, 49].contains(keyCode) {
            return true // Lock screen, emoji picker.
        }
        if modifiers == [.control] && [96, 97, 98, 99, 118, 120, 123, 124, 125, 126].contains(keyCode) {
            return true // Keyboard focus navigation, Mission Control and Space navigation.
        }
        return false
    }
    public static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]

    public func validate() throws {
        let modifierKeys: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        guard keyCode <= 127, !modifierKeys.contains(keyCode),
              modifiers.rawValue & ~ShortcutModifiers.all.rawValue == 0,
              !modifiers.isEmpty,
              !keyLabel.isEmpty, keyLabel.count <= 16,
              keyLabel.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw AssistantError.invalidShortcut
        }
    }

    public static func legacy(key: String) throws -> Self {
        let codes: [String: UInt32] = ["S": 1, "D": 2, "Space": 49]
        guard let code = codes[key] else { throw AssistantError.invalidShortcut }
        return Self(keyCode: code, modifiers: [.command, .shift], keyLabel: key == "Space" ? "空格" : key)
    }
}
