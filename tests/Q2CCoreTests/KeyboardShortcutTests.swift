import Foundation
import Testing
@testable import Q2CCore

@Test func customShortcutsDoNotRequireCommand() throws {
    for modifiers: ShortcutModifiers in [.control, .option, .shift, [.control, .option], .all] {
        let shortcut = KeyboardShortcut(keyCode: 40, modifiers: modifiers, keyLabel: "K")
        try shortcut.validate()
        #expect(shortcut.displayName == modifiers.symbols + "K")
    }
}

@Test func shortcutsRequireAModifierAndRejectOrdinaryTyping() throws {
    #expect(throws: AssistantError.invalidShortcut) {
        try KeyboardShortcut(keyCode: 97, modifiers: [], keyLabel: "F6").validate()
    }
    #expect(throws: AssistantError.invalidShortcut) {
        try KeyboardShortcut(keyCode: 40, modifiers: [], keyLabel: "K").validate()
    }
    #expect(throws: AssistantError.invalidShortcut) {
        try KeyboardShortcut(keyCode: 55, modifiers: .command, keyLabel: "⌘").validate()
    }
}

@Test func legacyShortcutChoicesKeepTheirOriginalCombination() throws {
    for (key, code, label) in [("S", UInt32(1), "S"), ("D", UInt32(2), "D"), ("Space", UInt32(49), "空格")] {
        let shortcut = try KeyboardShortcut.legacy(key: key)
        #expect(shortcut.keyCode == code)
        #expect(shortcut.modifiers == [.command, .shift])
        #expect(shortcut.keyLabel == label)
    }
}
