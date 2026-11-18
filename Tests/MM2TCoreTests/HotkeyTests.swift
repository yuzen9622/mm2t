import MM2TCore
import Testing

@Suite struct HotkeyTests {
    /// kVK_LeftArrow, kVK_ANSI_R, kVK_ANSI_C.
    let leftArrow: UInt16 = 123, r: UInt16 = 15, c: UInt16 = 8

    /// The detector behind a reference, so its mutating calls can sit inside `#expect`.
    final class Keyboard {
        var detector: HotkeyDetector
        init(_ hotkey: Hotkey, held: HotkeyModifiers = []) { detector = HotkeyDetector(hotkey: hotkey, held: held) }

        /// Feeds modifier changes and returns how many times the shortcut fired.
        func flags(_ steps: [HotkeyModifiers]) -> Int { steps.filter { detector.modifiersChanged($0) }.count }
        func key(_ code: UInt16, _ modifiers: HotkeyModifiers, isRepeat: Bool = false) -> Bool {
            detector.keyDown(code, modifiers: modifiers, isRepeat: isRepeat)
        }
    }

    final class Field {
        var recorder = HotkeyRecorder()
        func flags(_ now: HotkeyModifiers) -> Hotkey? { recorder.modifiersChanged(now) }
        func key(_ code: UInt16, _ modifiers: HotkeyModifiers, _ label: String) -> Hotkey? {
            recorder.keyDown(code, modifiers: modifiers, label: label)
        }
    }

    @Test func aCleanCommandFnPressAndReleaseFiresOnce() {
        let keys = Keyboard(.commandFn)
        #expect(keys.flags([[.command], [.command, .function], [.command]]) == 0, "nothing fires while held")
        #expect(keys.flags([[]]) == 1)
        // Either order of pressing and letting go works.
        #expect(keys.flags([[.function], [.command, .function], [.function], []]) == 1)
    }

    @Test func commandFnWithAnotherKeyDoesNotFire() {
        let keys = Keyboard(.commandFn)
        _ = keys.flags([[.command], [.command, .function]])
        // An arrow key carries the Fn flag by itself; ⌘Fn← is still a different shortcut.
        #expect(!keys.key(leftArrow, [.command, .function]))
        #expect(keys.flags([[.command], []]) == 0)
    }

    @Test func aKeyPressedAfterLettingGoOfFnButBeforeCommandStillSpoilsThePress() {
        let keys = Keyboard(.commandFn)
        _ = keys.flags([[.command], [.command, .function], [.command]])
        _ = keys.key(c, [.command])
        #expect(keys.flags([[]]) == 0, "that was ⌘C")
    }

    @Test func anExtraModifierDoesNotFireEvenIfLetGoFirst() {
        let keys = Keyboard(.commandFn)
        #expect(keys.flags([[.command], [.command, .function], [.command, .function, .shift], [.command, .function], []]) == 0)
        #expect(keys.flags([[.shift], [.shift, .command], [.shift, .command, .function], [.command, .function], []]) == 0)
    }

    @Test func fnAloneOrCommandAloneDoesNotFire() {
        let keys = Keyboard(.commandFn)
        #expect(keys.flags([[.function], []]) == 0)
        #expect(keys.flags([[.command], []]) == 0)
    }

    @Test func aSpoiledPressDoesNotCarryOverToTheNext() {
        let keys = Keyboard(.commandFn)
        _ = keys.flags([[.command], [.command, .function]])
        _ = keys.key(leftArrow, [.command, .function])
        _ = keys.flags([[]])
        #expect(keys.flags([[.command], [.command, .function], []]) == 1)
    }

    @Test func holdingTheChordFiresOncePerPress() {
        let keys = Keyboard(.commandFn)
        // Some keyboards repeat the same flags while held.
        let held: [HotkeyModifiers] = [[.command], [.command, .function], [.command, .function], [.command, .function]]
        #expect(keys.flags(held + [[]]) == 1)
        #expect(keys.flags(held + [[]]) == 1)
    }

    @Test func aKeyComboFiresOnKeyDownOnceAndNotOnRepeat() {
        let keys = Keyboard(Hotkey(modifiers: [.control, .option], keyCode: r, keyLabel: "R"))
        #expect(keys.flags([[.control], [.control, .option]]) == 0)
        #expect(keys.key(r, [.control, .option]))
        #expect(!keys.key(r, [.control, .option], isRepeat: true))
        #expect(keys.flags([[]]) == 0, "letting go of a combo's modifiers fires nothing")
        #expect(!keys.key(r, [.control, .option, .shift]))
        #expect(!keys.key(r, [.control]))
        #expect(!keys.key(c, [.control, .option]))
    }

    // MARK: Resuming after the shortcut field

    @Test func resumingMidPressIgnoresThatPressAndFiresOnTheNextCleanOne() {
        // The field took ⌘Fn (or was cancelled with Esc) while both were still down.
        let keys = Keyboard(.commandFn, held: [.command, .function])
        #expect(keys.flags([[.command, .function], [.command], []]) == 0, "the press typed into the field")
        #expect(keys.flags([[.command], [.command, .function], []]) == 1)
    }

    @Test func theReleaseTheFieldRecordedDoesNotFireWhenItReachesTheMonitorAfterResuming() {
        // The field recorded ⌘Fn on its release and resumed first; that same release arrives next.
        let keys = Keyboard(.commandFn, held: [])
        #expect(keys.flags([[]]) == 0)
        #expect(keys.flags([[.function], [.command, .function], []]) == 1)
    }

    @Test func aComboRecordedInTheFieldDoesNotFireOnResume() {
        let combo = Hotkey(modifiers: [.control, .option], keyCode: r, keyLabel: "R")
        // The field recorded ⌃⌥R on key-down; the same key-down may reach the monitor after it resumes.
        let keys = Keyboard(combo, held: [.control, .option])
        #expect(!keys.key(r, [.control, .option]))
        #expect(!keys.key(r, [.control, .option], isRepeat: true))
        #expect(keys.flags([[.control], []]) == 0)
        _ = keys.flags([[.control], [.control, .option]])
        #expect(keys.key(r, [.control, .option]), "the next press works")
    }

    @Test func recordingTakesAChordOfTwoOrMoreModifiersOrAKeyWithACommandModifier() {
        let field = Field()
        #expect(field.flags([.command]) == nil)
        #expect(field.flags([.command, .function]) == nil)
        #expect(field.flags([.function]) == nil)
        #expect(field.flags([]) == .commandFn)

        #expect(field.flags([.command]) == nil)
        #expect(field.flags([]) == nil, "one modifier alone is not a shortcut")

        #expect(field.flags([.shift]) == nil)
        #expect(field.key(r, [.shift], "R") == nil, "⇧R types")
        #expect(field.flags([]) == nil)

        _ = field.flags([.control, .option])
        #expect(field.key(r, [.control, .option], "R")
            == Hotkey(modifiers: [.control, .option], keyCode: r, keyLabel: "R"))
        #expect(field.flags([]) == nil, "the combo was recorded, not the chord")
    }

    @Test func symbolsFollowTheSystemOrder() {
        #expect(Hotkey.commandFn.symbols == "⌘Fn")
        #expect(Hotkey(modifiers: [.command, .shift, .option, .control], keyCode: r, keyLabel: "R").symbols == "⌃⌥⇧⌘R")
    }
}
