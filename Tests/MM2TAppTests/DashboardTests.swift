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

    @Test func aProcessedMeetingTeachesItsTermsAndACorrectionTeachesItsWord() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        #expect(world.app.settings.settings.learnedVocabulary == ["Kubernetes", "報價單"])

        let detail = world.detail(meeting.id)
        await detail.load()
        let row = try #require(detail.presentation?.raw.first)
        let corrected = "Grafana " + row.text.dropFirst(2)
        await detail.edit(row.id, to: corrected)
        #expect(detail.presentation?.raw.first?.text == corrected)
        #expect(world.app.settings.settings.learnedVocabulary.contains("Grafana"))

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
