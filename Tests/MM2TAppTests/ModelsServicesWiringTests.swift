import Foundation
import Testing

@Suite struct ModelsServicesWiringTests {
    @Test func servicePickersLeaveRecheckingToTheSettingsObserver() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let views = repository.appending(path: "App/MM2T/Views")
        let picker = try String(contentsOf: views.appending(path: "ModelsServicesView.swift"), encoding: .utf8)
        let settings = try String(contentsOf: views.appending(path: "SettingsView.swift"), encoding: .utf8)
        #expect(!picker.contains("app.setup.recheck()"))
        #expect(settings.contains(".onChange(of: app.settings.settings) { app.setup.recheck() }"))
    }
}
