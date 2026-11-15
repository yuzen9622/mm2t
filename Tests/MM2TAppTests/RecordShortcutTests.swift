import Foundation
import MM2TCore
import Testing
@testable import MM2TApp

@MainActor @Suite struct RecordShortcutTests {
    @Test func settingsSavedBeforeTheShortcutExistedLoadWithCommandFn() throws {
        let old = Data(#"{"transcriptionOrder":["cloud"],"hasCompletedOnboarding":true,"hidesFromScreenCapture":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(settings.recordShortcut == .commandFn)
        #expect(settings.hasCompletedOnboarding && !settings.hidesFromScreenCapture, "the other keys still load")
    }

    @Test func aChangedShortcutSurvivesARelaunch() throws {
        let defaults = UserDefaults(suiteName: "mm2t-tests-\(UUID().uuidString)")!
        let combo = Hotkey(modifiers: [.control, .option], keyCode: 15, keyLabel: "R")
        SettingsStore(defaults: defaults).settings.recordShortcut = combo
        #expect(SettingsStore(defaults: defaults).settings.recordShortcut == combo)
    }
}
