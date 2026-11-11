import Foundation
import Testing
@testable import MM2TCore

@Suite struct MeetingRendererTests {
    @Test func rawViewInBothFormats() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        let markdown = await world.render(meeting, .raw, .markdown)
        let plain = await world.render(meeting, .raw, .plainText)

        #expect(markdown.hasPrefix("# Weekly sync: Transcript\n"))
        #expect(markdown.contains("[00:00:00] **Alice**: Hi team,小明你覺得呢"))
        #expect(markdown.contains("[00:00:50] **Me**: Thanks all"))
        #expect(plain.hasPrefix("WEEKLY SYNC: TRANSCRIPT\n"))
        #expect(plain.contains("[00:00:40] Alice: Ship it"))
        #expect(!plain.contains("**"))
    }

    @Test func summaryItemsPointBackToTheirSourceInTheRawTranscript() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        let decision = try #require(meeting.outputs.summary?.decisions.first)
        #expect(meeting.timeRange(of: decision.sources) == TimeRange(start: 40.5, end: 41.3))
        let summary = await world.render(meeting, .summary, .markdown)
        #expect(summary.contains("## Decisions\n\n- Ship it, proposed by Alice [00:00:40]"))
        #expect(summary.contains("- Follow up (owner: B) [00:00:40]"))
    }

    @Test func viewsNotYetGeneratedSaySo() async throws {
        let world = try await World()
        let meeting = try await world.record()
        for view in [TranscriptView.cleaned, .perPerson, .summary] {
            #expect(await world.render(meeting, view).contains("Not generated yet."))
        }
    }

    @Test func aDeletedPersonFallsBackToTheSpeakerLabel() async throws {
        let world = try await World()
        let meeting = try await world.processed()
        try await world.voiceprints.delete(world.aliceID)

        #expect(await world.render(meeting, .raw).contains("A: Hi team"))
    }
}
