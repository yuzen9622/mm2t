import MM2TCore
import Testing
@testable import MM2TApp

@MainActor @Suite struct MeetingDeepLinkTests {
    @Test func loadsAndJumpsFromAnotherTab() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let source = try #require(meeting.utterances.last)
        let playback = FakePlayback()
        let detail = world.detail(meeting.id, playback: playback)
        detail.selectedView = .summary
        await detail.load(at: source.id)
        #expect(detail.selectedView == .raw)
        #expect(detail.focusedUtterance == source.id)
        #expect(playback.currentTime == source.range.start)
        #expect(playback.isPlaying)
        #expect(!playback.loaded.isEmpty)
        detail.selectedView = .cleaned
        await detail.load()
        #expect(detail.selectedView == .cleaned)
    }

    @Test func missingUtteranceLeavesTheCurrentViewAlone() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let playback = FakePlayback()
        let detail = world.detail(meeting.id, playback: playback)
        detail.selectedView = .summary
        await detail.load(at: UtteranceID("deleted"))
        #expect(detail.meeting?.id == meeting.id)
        #expect(detail.selectedView == .summary)
        #expect(detail.focusedUtterance == nil)
        #expect(!playback.isPlaying)
    }

    @Test func laterLinkRepositionsAnAlreadyLoadedMeeting() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let first = try #require(meeting.utterances.first)
        let last = try #require(meeting.utterances.last)
        let detail = world.detail(meeting.id)
        await detail.load(at: first.id)
        #expect(detail.focusedUtterance == first.id)
        await detail.load(at: last.id)
        #expect(detail.focusedUtterance == last.id)
    }
}
