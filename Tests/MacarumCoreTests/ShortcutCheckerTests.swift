import Carbon.HIToolbox
import Testing
@testable import MacarumCore

@Suite struct ShortcutCheckerTests {
    let checker = ShortcutChecker(extraReserved: [KeyCombo(kVK_ANSI_K, [.command, .option, .control]): "a macOS shortcut"])

    private func isBlocked(_ v: ShortcutVerdict) -> Bool { if case .blocked = v { true } else { false } }
    private func isWarning(_ v: ShortcutVerdict) -> Bool { if case .warning = v { true } else { false } }

    @Test func systemAndAppShortcutsAreBlocked() {
        #expect(isBlocked(checker.check(KeyCombo(kVK_Space, .command))))
        #expect(isBlocked(checker.check(KeyCombo(kVK_ANSI_4, [.command, .shift]))))
        #expect(isBlocked(checker.check(KeyCombo(kVK_Space, .option))))
        #expect(isBlocked(checker.check(KeyCombo(kVK_ANSI_K, [.command, .option, .control]))))
    }

    @Test func plainKeysAndCommandLetterAreBlocked() {
        #expect(isBlocked(checker.check(KeyCombo(kVK_ANSI_V, []))))
        #expect(isBlocked(checker.check(KeyCombo(kVK_ANSI_V, .shift))))
        #expect(isBlocked(checker.check(KeyCombo(kVK_ANSI_V, .command))))
    }

    @Test func riskyButUsableCombosWarn() {
        #expect(isWarning(checker.check(KeyCombo(kVK_ANSI_V, .option))))
        #expect(isWarning(checker.check(KeyCombo(kVK_ANSI_V, .control))))
        #expect(isWarning(checker.check(KeyCombo(kVK_ANSI_V, [.command, .shift]))))
    }

    @Test func uncommonCombosPass() {
        #expect(checker.check(KeyCombo(kVK_ANSI_V, [.control, .command])) == .ok)
        #expect(checker.check(KeyCombo(kVK_ANSI_V, [.option, .command])) == .ok)
    }

    @Test func readsSymbolicHotKeyParameters() {
        // Spotlight as stored by macOS: space, key 49, ⌘ (1 << 20).
        #expect(ShortcutChecker.comboFromSymbolicHotKey(parameters: [32, 49, 1_048_576]) == KeyCombo(49, .command))
        #expect(ShortcutChecker.comboFromSymbolicHotKey(parameters: [65535, 65535, 0]) == nil)
        #expect(ShortcutChecker.comboFromSymbolicHotKey(parameters: [1]) == nil)
    }
}
