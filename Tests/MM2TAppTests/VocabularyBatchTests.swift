import Foundation
import Testing
@testable import MM2TApp

@MainActor @Suite struct VocabularyBatchTests {
    @Test func removesOnlySelectedTermsAndRemembersDismissedLearning() {
        var settings = AppSettings()
        settings.addVocabulary("Manual, Keep", source: .manual)
        settings.addVocabulary("Learned, Retained", source: .learned)
        settings.removeVocabulary(["Manual", "Learned", "Learned", "Missing"])
        #expect(settings.vocabulary == ["Keep", "Retained"])
        #expect(settings.learnedVocabulary == ["Retained"])
        #expect(settings.dismissedVocabulary == ["Learned"])
        settings.addVocabulary("learned", source: .learned)
        #expect(settings.vocabulary == ["Keep", "Retained"])
        settings.addVocabulary("Learned", source: .manual)
        #expect(settings.vocabulary == ["Keep", "Retained", "Learned"])
        #expect(settings.dismissedVocabulary.isEmpty)
    }

    @Test func batchDeletionPersistsAcrossStoreRecreation() throws {
        let name = "VocabularyBatchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        store.settings.addVocabulary("One, Two", source: .manual)
        store.settings.addVocabulary("Three", source: .learned)
        store.settings.removeVocabulary(["One", "Three"])
        let restored = SettingsStore(defaults: defaults)
        #expect(restored.settings.vocabulary == ["Two"])
        #expect(restored.settings.learnedVocabulary.isEmpty)
        #expect(restored.settings.dismissedVocabulary == ["Three"])
        let before = restored.settings
        restored.settings.removeVocabulary([])
        #expect(restored.settings == before)
    }
}
