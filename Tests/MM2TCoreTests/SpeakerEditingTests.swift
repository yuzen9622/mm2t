import Foundation
import Testing
@testable import MM2TCore

@Suite struct SpeakerEditingTests {
    @Test func renameUpdatesEveryViewWithoutCallingAnyProvider() async throws {
        let world = try await World()
        let meeting = try await world.processed()
        let callsBefore = world.providerCallCount

        let renamed = try await world.editing.rename(SpeakerID("r2"), in: meeting.id, to: .newPerson(name: "Carol"))

        #expect(world.providerCallCount == callsBefore)
        for format in [ExportFormat.markdown, .plainText] {
            let raw = await world.render(renamed, .raw, format)
            let cleaned = await world.render(renamed, .cleaned, format)
            let perPerson = await world.render(renamed, .perPerson, format)
            let summary = await world.render(renamed, .summary, format)
            #expect(raw.contains("Carol") && raw.contains("我覺得可以"))
            #expect(cleaned.contains("Carol") && cleaned.contains("clean: 我覺得可以"))
            #expect(perPerson.contains("Carol spoke 1 times"))
            #expect(summary.contains("Follow up (owner: Carol)"))
            #expect(!(raw + cleaned + perPerson + summary).contains("{{speaker:"))
        }
        let reloaded = try await world.library.meeting(meeting.id)
        #expect(await world.render(reloaded, .summary).contains("owner: Carol"))
    }

    @Test func renamingToAnExistingPersonReusesThem() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        let renamed = try await world.editing.rename(SpeakerID("r3"), in: meeting.id, to: .existing(world.bobID))

        #expect(renamed.speaker(SpeakerID("r3"))?.person == world.bobID)
        #expect(await world.voiceprints.allPersons().map(\.name) == ["Alice", "Bob"])
        #expect(!renamed.suggestions.items.contains { $0.speaker == SpeakerID("r3") })
    }

    @Test func acceptingSuggestionsNamesTheSpeaker() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        _ = try await world.editing.acceptSuggestion(for: SpeakerID("r3"), in: meeting.id)
        let accepted = try await world.editing.acceptSuggestion(for: SpeakerID("r2"), in: meeting.id)

        let names = await world.voiceprints.names()
        #expect(accepted.speaker(SpeakerID("r3"))?.person == world.bobID)
        #expect(accepted.speaker(SpeakerID("r2"))?.person.flatMap { names[$0] } == "小明")
        #expect(accepted.suggestions.items.isEmpty)
        await #expect(throws: SpeakerEditError.noSuggestion(SpeakerID("r1"))) {
            try await world.editing.acceptSuggestion(for: SpeakerID("r1"), in: meeting.id)
        }
    }

    @Test func mergeMovesSpeechAndMarksGeneratedOutputsStale() async throws {
        let world = try await World()
        let meeting = try await world.processed()
        let callsBefore = world.providerCallCount
        _ = try await world.editing.rename(SpeakerID("r2"), in: meeting.id, to: .newPerson(name: "Carol"))

        let merged = try await world.editing.merge(SpeakerID("r3"), into: SpeakerID("r2"), in: meeting.id)

        #expect(world.providerCallCount == callsBefore)
        #expect(merged.speakers.map(\.id.rawValue) == ["r1", "r2"])
        #expect(merged.utterances.filter { $0.speaker == SpeakerID("r2") }.map(\.text) == ["我覺得可以", "我同意"])
        #expect(merged.outputs.isStale)
        #expect(merged.suggestions.isStale)
        let summary = await world.render(merged, .summary)
        #expect(summary.contains("Regenerate"))
        #expect(summary.contains("Whether Carol agrees"))
        #expect(try await world.library.meeting(meeting.id).outputs.isStale)
    }

    @Test func regeneratingAfterMergeClearsStaleness() async throws {
        let world = try await World()
        let meeting = try await world.processed()
        _ = try await world.editing.merge(SpeakerID("r3"), into: SpeakerID("r2"), in: meeting.id)

        let regenerated = try await world.pipeline.regenerateLLMOutputs(meeting.id)

        #expect(regenerated.status == .completed)
        #expect(!regenerated.outputs.isStale)
        #expect(regenerated.outputs.digests?.map(\.speaker.rawValue) == ["r1", "r2", "me"])
        #expect(world.diarizer.calls.get == 1)
    }

    @Test func renameWritesBackSoTheNextMeetingAutoRecognizesThePerson() async throws {
        let world = try await World()
        let first = try await world.processed()
        #expect(first.speaker(SpeakerID("r2"))?.person == nil)

        _ = try await world.editing.rename(SpeakerID("r2"), in: first.id, to: .newPerson(name: "Carol"))
        let second = try await world.processed()

        let carol = try #require(await world.voiceprints.person(named: "Carol"))
        #expect(second.speaker(SpeakerID("r2"))?.person == carol.id)
        #expect(await world.render(second, .raw).contains("Carol: 我覺得可以"))
    }

    @Test func acceptingAVoiceprintSuggestionWritesBackSoTheNextMeetingAutoNames() async throws {
        let world = try await World()
        let first = try await world.processed()
        #expect(first.speaker(SpeakerID("r3"))?.person == nil)

        _ = try await world.editing.acceptSuggestion(for: SpeakerID("r3"), in: first.id)
        let second = try await world.processed()

        #expect(second.speaker(SpeakerID("r3"))?.person == world.bobID)
    }

    @Test func mergeLeavesVoiceprintsAloneUntilTheVoiceIsLearned() async throws {
        let world = try await World()
        let first = try await world.processed()

        _ = try await world.editing.merge(SpeakerID("r2"), into: SpeakerID("r1"), in: first.id)
        #expect(await world.voiceprints.person(world.aliceID)?.embeddings.count == 1)
        #expect(try await world.processed().speaker(SpeakerID("r2"))?.person == nil)

        try await world.editing.learnVoice(of: SpeakerID("r1"), in: first.id)
        #expect(try await world.processed().speaker(SpeakerID("r2"))?.person == world.aliceID)
    }

    @Test func aSpeakerCanBeNamedWithoutTeachingTheVoiceprint() async throws {
        let world = try await World()
        let first = try await world.processed()

        let named = try await world.editing.rename(SpeakerID("r2"), in: first.id, to: .newPerson(name: "Carol"), learn: false)
        _ = try await world.editing.rename(SpeakerID("r3"), in: first.id, to: .existing(world.bobID), learn: false)

        let carol = try #require(await world.voiceprints.person(named: "Carol"))
        #expect(named.speaker(SpeakerID("r2"))?.person == carol.id)
        #expect(carol.embeddings.isEmpty)
        #expect(await world.voiceprints.person(world.bobID)?.embeddings.count == 1)
        #expect(try await world.processed().speaker(SpeakerID("r2"))?.person == nil)
    }

    @Test func aSpeakerRenamedToSomeoneElseTakesTheirVoiceBack() async throws {
        let world = try await World()
        let meeting = try await world.processed()
        _ = try await world.editing.rename(SpeakerID("r2"), in: meeting.id, to: .existing(world.aliceID))
        #expect(await world.voiceprints.person(world.aliceID)?.embeddings.count == 3)

        _ = try await world.editing.rename(SpeakerID("r2"), in: meeting.id, to: .newPerson(name: "Carol"))

        #expect(await world.voiceprints.person(world.aliceID)?.embeddings.count == 1)
        #expect(await world.voiceprints.person(named: "Carol")?.embeddings.count == 2)
    }

    @Test func aLearnedVoiceCanBeForgottenWhileTheNameStays() async throws {
        let world = try await World()
        let first = try await world.processed()
        _ = try await world.editing.rename(SpeakerID("r2"), in: first.id, to: .newPerson(name: "Carol"))

        try await world.editing.forgetVoice(of: SpeakerID("r2"), in: first.id)

        let carol = try #require(await world.voiceprints.person(named: "Carol"))
        #expect(carol.embeddings.isEmpty)
        #expect(try await world.library.meeting(first.id).speaker(SpeakerID("r2"))?.person == carol.id)
        #expect(try await world.processed().speaker(SpeakerID("r2"))?.person == nil)
    }

    @Test func onlyANamedSpeakerHasAVoiceprintToTeach() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        await #expect(throws: SpeakerEditError.unnamed(SpeakerID("r3"))) {
            try await world.editing.learnVoice(of: SpeakerID("r3"), in: meeting.id)
        }
    }

    @Test func theMicSpeakerCannotBeEdited() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        await #expect(throws: SpeakerEditError.cannotEditMe) {
            try await world.editing.rename(.me, in: meeting.id, to: .newPerson(name: "X"))
        }
        await #expect(throws: SpeakerEditError.cannotEditMe) {
            try await world.editing.merge(SpeakerID("r1"), into: .me, in: meeting.id)
        }
        await #expect(throws: SpeakerEditError.mergeIntoSelf) {
            try await world.editing.merge(SpeakerID("r1"), into: SpeakerID("r1"), in: meeting.id)
        }
    }
}
