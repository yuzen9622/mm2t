import Foundation
import MM2TCore
import Testing
@testable import MM2TApp

@MainActor @Suite struct VocabularyTests {
    @Test func termsKeepWhoAddedThemAndADeletedLearnedTermStaysGone() {
        var settings = AppSettings()
        settings.addVocabulary("mm2t, Typeless\nmm2t\n", source: .manual)
        settings.addVocabulary("Kubernetes", source: .learned)
        settings.addVocabulary("typeless", source: .learned)
        #expect(settings.vocabulary == ["mm2t", "Typeless", "Kubernetes"])
        #expect(settings.learnedVocabulary == ["Kubernetes"])

        settings.removeVocabulary("Kubernetes")
        settings.addVocabulary("kubernetes", source: .learned)
        #expect(settings.vocabulary == ["mm2t", "Typeless"], "a learned term the user deleted is not learned again")

        settings.addVocabulary("Kubernetes", source: .manual)
        #expect(settings.source(of: "Kubernetes") == .manual)
        #expect(settings.dismissedVocabulary.isEmpty)
    }

    @Test func editingATermKeepsItsPlaceAndMakesItTheUsers() {
        var settings = AppSettings()
        settings.addVocabulary("mm2t, Typeless", source: .manual)
        settings.addVocabulary("Kubernetis", source: .learned)
        settings.addVocabulary("Zoom", source: .manual)

        let renamed = settings.renameVocabulary("Kubernetis", to: " Kubernetes ")
        #expect(renamed)
        #expect(settings.vocabulary == ["mm2t", "Typeless", "Kubernetes", "Zoom"])
        #expect(settings.source(of: "Kubernetes") == .manual)
        settings.addVocabulary("Kubernetis", source: .learned)
        #expect(!settings.vocabulary.contains("Kubernetis"), "the misspelling the user fixed is not learned again")

        let duplicate = settings.renameVocabulary("Zoom", to: "typeless")
        let empty = settings.renameVocabulary("Zoom", to: "  ")
        #expect(!duplicate, "a term that already exists is refused")
        #expect(!empty)
        #expect(settings.vocabulary == ["mm2t", "Typeless", "Kubernetes", "Zoom"])
    }

    @Test func aLearnedTermTheUserTypesBecomesTheirs() {
        var settings = AppSettings()
        settings.addVocabulary("Sparkle", source: .learned)
        settings.addVocabulary("sparkle", source: .manual)
        #expect(settings.vocabulary == ["Sparkle"])
        #expect(settings.source(of: "Sparkle") == .manual)
    }

    @Test func settingsSavedBeforeLearnedTermsExistedStillLoad() throws {
        let old = Data(#"{"vocabulary":["mm2t"],"transcriptionOrder":["cloud"]}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(settings.vocabulary == ["mm2t"])
        #expect(settings.source(of: "mm2t") == .manual)
    }

    @Test func vocabularyPersistsOnlyTermsAndIgnoresRemovedDetails() throws {
        let old = Data(#"{"vocabulary":["Kubernetes"],"learnedVocabulary":["Kubernetes"],"vocabularyDetails":[{"term":"Kubernetes","incorrectSpellings":["酷柏內提斯"],"definition":"容器編排平台","pronunciation":"koo-ber-NET-eez"}]}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(settings.vocabulary == ["Kubernetes"])
        #expect(settings.learnedVocabulary == ["Kubernetes"])
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(restored == settings)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["vocabulary"] as? [String] == ["Kubernetes"])
        #expect(json["vocabularyDetails"] == nil)
    }

    @Test func savingDoesNotWaitForLearningAndStaleResultsAreIgnored() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let detail = world.detail(meeting.id)
        await detail.load()
        let row = try #require(detail.presentation?.raw.first)
        let corrected = "Grafana " + row.text.dropFirst(2)
        let gate = Gate<Bool>()
        world.catalog.llm.holds.set(["vocabularyCorrections": gate])
        world.catalog.llm.corrections.set([.init(incorrect: String(row.text.prefix(2)), correct: "Grafana")])
        let first = Task { await detail.edit(row.id, to: corrected) }
        #expect(await eventually { !world.catalog.llm.correctionRequests.get.isEmpty })
        #expect(try await world.library.meeting(meeting.id).utterance(row.id)?.text == corrected)
        world.catalog.llm.corrections.set([])
        let second = Task { await detail.edit(row.id, to: row.text) }
        #expect(await eventually { world.catalog.llm.correctionRequests.get.count == 2 })
        await gate.open(true)
        await first.value
        await second.value
        #expect(world.app.settings.settings.vocabulary.isEmpty)
        #expect(try await world.library.meeting(meeting.id).utterance(row.id)?.text == row.text)
    }

    @Test(arguments: [false, true])
    func reopeningADetailAndUndoingRejectsTheOldModelsReply(cleaned: Bool) async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let detail = world.detail(meeting.id)
        await detail.load()
        let raw = try #require(detail.presentation?.raw.first)
        let paragraph = try #require(detail.presentation?.cleaned?.first)
        let original = cleaned ? paragraph.text : raw.text
        let corrected = "Grafana " + original.dropFirst(2)
        func edit(_ detail: MeetingDetailModel, to text: String) async {
            if cleaned, let row = detail.presentation?.cleaned?.first {
                await detail.editCleaned(row, to: text)
            } else {
                await detail.edit(raw.id, to: text)
            }
        }
        let gate = Gate<Bool>()
        world.catalog.llm.holds.set(["vocabularyCorrections": gate])
        world.catalog.llm.corrections.set([.init(incorrect: String(original.prefix(2)), correct: "Grafana")])
        let first = Task { await edit(detail, to: corrected) }
        #expect(await eventually { world.catalog.llm.correctionRequests.get.count == 1 })

        let reopened = world.detail(meeting.id)
        await reopened.load()
        world.catalog.llm.corrections.set([])
        let undo = Task { await edit(reopened, to: original) }
        #expect(await eventually { world.catalog.llm.correctionRequests.get.count == 2 })
        await gate.open(true)
        await first.value
        await undo.value
        #expect(world.app.settings.settings.vocabulary.isEmpty)
        let saved = try await world.library.meeting(meeting.id)
        #expect((cleaned ? saved.outputs.cleaned?.paragraphs.first?.text : saved.utterance(raw.id)?.text) == original)
    }

    @Test(arguments: LLMLocation.allCases)
    func learningOnlyRequiresTheSelectedLanguageModel(location: LLMLocation) async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let detail = world.detail(meeting.id)
        await detail.load()
        let row = try #require(detail.presentation?.raw.first)
        world.credentials.values.update { $0[.elevenLabsAPIKey] = nil }
        world.catalog.modelsDownloaded.set(false)
        world.app.settings.settings.llmLocation = location
        world.catalog.offlineDownloaded[.llm]!.set(true)
        let llm = location == .local ? world.catalog.onDeviceLLM : world.catalog.llm
        llm.corrections.set([.init(incorrect: String(row.text.prefix(2)), correct: "Grafana")])
        await detail.edit(row.id, to: "Grafana " + row.text.dropFirst(2))
        #expect(world.app.settings.settings.learnedVocabulary == ["Grafana"])
        #expect(llm.correctionRequests.get.count == 1)
    }

    @Test func knownNamesAndLearnedTermsArePlainWordsWithoutDuplicates() async throws {
        let world = try World()
        _ = try await world.app.voiceprints.addPerson(name: "舒立")
        world.app.settings.settings.addVocabulary("舒立", source: .learned)
        world.app.settings.settings.addVocabulary("Grafana", source: .learned)
        _ = try await world.recordedMeeting()
        let glossary = try #require(world.catalog.llm.cleanGlossaries.get.first)
        #expect(glossary.filter { $0.contains("舒立") } == ["舒立"])
        #expect(glossary.contains("Grafana"))
    }

    @Test func modelFailureDoesNotUndoASavedCorrection() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let detail = world.detail(meeting.id)
        await detail.load()
        let row = try #require(detail.presentation?.raw.first)
        world.catalog.llm.failNext.set(["vocabularyCorrections"])
        await detail.edit(row.id, to: "修正後的逐字稿")
        #expect(try await world.library.meeting(meeting.id).utterance(row.id)?.text == "修正後的逐字稿")
        #expect(detail.errorMessage == nil)
        #expect(world.app.settings.settings.vocabulary.isEmpty)
    }

    @Test(arguments: [false, true])
    func onlyASavedCorrectionTeachesVocabulary(cleaned: Bool) async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        #expect(world.app.settings.settings.learnedVocabulary.isEmpty)

        let detail = world.detail(meeting.id)
        await detail.load()
        let row = try #require(detail.presentation?.raw.first)
        let paragraph = try #require(detail.presentation?.cleaned?.first)
        let original = cleaned ? paragraph.text : row.text
        let corrected = "Grafana " + original.dropFirst(2)
        world.catalog.llm.corrections.set([.init(incorrect: String(original.prefix(2)), correct: "Grafana")])
        if cleaned {
            await detail.editCleaned(paragraph, to: corrected)
        } else {
            await detail.edit(row.id, to: corrected)
        }
        #expect((cleaned ? detail.presentation?.cleaned?.first?.text : detail.presentation?.raw.first?.text) == corrected)
        #expect(world.app.settings.settings.vocabulary == ["Grafana"])
        #expect(world.app.settings.settings.learnedVocabulary == ["Grafana"])
        #expect(world.catalog.llm.correctionRequests.get.first?.0 == original)
        #expect(world.catalog.llm.correctionRequests.get.first?.1 == corrected)

        await detail.rename(to: "Q3 預算")
        #expect(detail.meeting?.metadata.title == "Q3 預算")
        #expect(detail.subtitles(.raw)?.hasPrefix("1\n00:00:") == true)
        #expect(detail.subtitles(.summary) == nil)
    }
}

@MainActor @Suite struct DashboardTests {
    @Test func collectsTodosTalkTimeAndActivityFromFinishedMeetings() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        world.app.settings.settings.addVocabulary("預算", source: .manual)
        let dashboard = world.app.dashboard

        await dashboard.reload()
        #expect(dashboard.stats.meetings == 1)
        #expect(dashboard.todos.map(\.text) == ["整理報價"])
        #expect(dashboard.todos.first?.meeting == meeting.id)
        #expect(dashboard.activity.count == DashboardModel.activityDays)
        #expect(dashboard.voices.first { $0.id == "me" } != nil)
        #expect((dashboard.stats.myShare ?? 0) > 0 && (dashboard.stats.myShare ?? 1) < 1)
        #expect(dashboard.calendarSources.isEmpty && !dashboard.hasConnectedCalendar)

        let todo = try #require(dashboard.todos.first)
        dashboard.toggle(todo)
        #expect(dashboard.todos.first?.isDone == true)
        await dashboard.reload()
        #expect(dashboard.todos.first?.isDone == true, "done survives a reload")
    }
}
