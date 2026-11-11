import Foundation
import Testing
@testable import MM2TCore

/// Where the remote track's speaker turns come from: the local diarizer or the STT's labels.
@Suite struct SpeakerSourceTests {
    @Test func localFirstUsesTheDiarizerEvenWhenTheTranscriptCarriesLabels() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        #expect(meeting.transcription?.remote.content.labeledWords?.count == Script.remoteWords.count)
        #expect(meeting.attribution?.source == .local)
        #expect(meeting.attribution?.overlaps == Script.diarization.overlaps)
        #expect(meeting.speakers.map(\.label) == ["A", "B", "C"])
        #expect(world.diarizer.calls.get == 1)
        #expect(world.embedder.calls.get.isEmpty)
    }

    @Test func onlyTheRemoteTrackAsksForSpeakerLabelsAndTheMicStaysMe() async throws {
        let world = try await World(localModel: .embedderOnly)
        let meeting = try await world.processed()

        let calls = world.cloud.calls.get.map { "\($0.file):\($0.labelSpeakers)" }.sorted()
        #expect(calls == ["mic.caf:false", "remote.caf:true"])
        #expect(meeting.utterances.filter { $0.track == .me }.map(\.text) == ["Thanks all"])
    }

    @Test func fallsBackToTranscriptLabelsWhenNoLocalDiarizerIsConfigured() async throws {
        let world = try await World(localModel: .embedderOnly)
        let meeting = try await world.processed()

        #expect(meeting.status == .completed)
        #expect(meeting.attribution?.source == .transcription)
        #expect(meeting.speakers.map(\.label) == ["A", "B"])
        #expect(meeting.utterances.map(\.text) == ["Hi team,小明你覺得呢", "我覺得可以我同意", "Ship it", "Thanks all"])
        #expect(meeting.utterances.map(\.speaker.rawValue) == ["r1", "r2", "r1", "me"])
    }

    @Test func fallsBackToTranscriptLabelsWhenTheDiarizerFails() async throws {
        let world = try await World()
        world.diarizer.fails.update { $0 = true }
        let meeting = try await world.processed()

        #expect(meeting.status == .completed)
        #expect(world.diarizer.calls.get == 1)
        #expect(meeting.attribution?.source == .transcription)
        #expect(meeting.speakers.map(\.label) == ["A", "B"])
    }

    @Test func labelsFirstSkipsTheDiarizerAndFallsBackToItWhenTheTranscriptHasNoLabels() async throws {
        let labelsFirst = try await World(diarizationOrder: [.transcription, .local])
        let labeled = try await labelsFirst.processed()
        #expect(labeled.attribution?.source == .transcription)
        #expect(labelsFirst.diarizer.calls.get == 0)

        let unlabeled = try await World(diarizationOrder: [.transcription, .local])
        unlabeled.cloud.behavior.update { $0 = .unreachable }
        let meeting = try await unlabeled.processed()
        #expect(meeting.transcription?.remote.source == .local)
        #expect(meeting.attribution?.source == .local)
        #expect(meeting.speakers.map(\.label) == ["A", "B", "C"])
    }

    @Test func voiceprintsStillNameSpeakersSegmentedByTranscriptLabels() async throws {
        let world = try await World(localModel: .embedderOnly)
        let meeting = try await world.processed()

        #expect(world.embedder.calls.get == [["speaker_0@0.5-3.0", "speaker_1@4.5-9.0", "speaker_0@40.5-41.3"]])
        #expect(meeting.attribution?.hasVoiceprints == true)
        #expect(meeting.speaker(SpeakerID("r1"))?.person == world.aliceID)
        #expect(meeting.speaker(SpeakerID("r2"))?.person == nil)
        #expect(await world.render(meeting, .raw).contains("Alice: Hi team"))

        _ = try await world.editing.rename(SpeakerID("r2"), in: meeting.id, to: .newPerson(name: "Carol"))
        let carol = try #require(await world.voiceprints.person(named: "Carol"))
        #expect(!carol.embeddings.isEmpty)
    }

    @Test func withoutAnEmbedderLabelSpeakersStayUnnamedAndEditsWriteNoVectors() async throws {
        let world = try await World(localModel: .none)
        let meeting = try await world.processed()

        #expect(meeting.attribution?.source == .transcription)
        #expect(meeting.attribution?.hasVoiceprints == false)
        #expect(meeting.speakers.allSatisfy { $0.person == nil && $0.embeddings.isEmpty })
        #expect(!meeting.suggestions.items.contains { $0.voiceprintPerson != nil })
        #expect(await world.render(meeting, .raw).contains("A: Hi team"))

        _ = try await world.editing.rename(SpeakerID("r1"), in: meeting.id, to: .existing(world.aliceID))
        _ = try await world.editing.rename(SpeakerID("r2"), in: meeting.id, to: .newPerson(name: "Carol"))
        #expect(await world.voiceprints.person(world.aliceID)?.embeddings == [Embedding(alice)])
        #expect(await world.voiceprints.person(named: "Carol")?.embeddings == [])
    }

    @Test func labelDerivedSpeechReportsOverlapAsUnavailableNotAbsent() async throws {
        let world = try await World(localModel: .embedderOnly)
        let meeting = try await world.processed()

        #expect(meeting.attribution?.overlaps == nil)
        #expect(meeting.utterances.allSatisfy { !$0.isOverlapping })
        #expect(!(await world.render(meeting, .raw)).contains("overlapping speech"))

        let quiet = Diarization(segments: Script.diarization.segments, overlaps: [], embeddings: Script.diarization.embeddings)
        let local = try await World(diarization: quiet).processed()
        #expect(local.attribution?.overlaps == [])
    }

    @Test func withNoSourceAllRemoteSpeechStaysUnderOneUnnamedSpeaker() async throws {
        let world = try await World(localModel: .none)
        world.cloud.behavior.update { $0 = .unreachable }
        let meeting = try await world.processed()

        #expect(meeting.status == .completed)
        #expect(meeting.attribution == .unseparated(.noSource))
        #expect(meeting.attribution?.hasVoiceprints == false)
        #expect(meeting.speakers.map(\.label) == ["A"])
        #expect(meeting.speakers[0].person == nil)
        #expect(meeting.utterances.filter { $0.track == .remote }.allSatisfy { $0.speaker == SpeakerID("r1") })
    }

    @Test func aDiarizerFailureWithNoLabelsStillDeliversTheTranscriptUnderOneSpeaker() async throws {
        let world = try await World()
        world.cloud.behavior.update { $0 = .unreachable }
        world.diarizer.fails.update { $0 = true }
        let meeting = try await world.processed()

        #expect(meeting.status == .completed)
        #expect(meeting.attribution == .unseparated(.failed(reason: String(describing: LocalModelError()))))
        #expect(meeting.attribution != .unseparated(.noSource))
        #expect(meeting.speakers.map(\.label) == ["A"])
        #expect(meeting.speakers[0].person == nil)
        #expect(meeting.utterances.filter { $0.track == .remote }.allSatisfy { $0.speaker == SpeakerID("r1") })
        #expect(meeting.outputs.cleaned != nil && meeting.outputs.summary != nil)
        #expect(await world.render(meeting, .raw).contains("A: Hi team"))
    }

    @Test func anEmbedderFailureKeepsLabelSpeakersWithVoiceprintsUnavailable() async throws {
        let world = try await World(localModel: .embedderOnly)
        world.embedder.fails.update { $0 = true }
        let meeting = try await world.processed()

        #expect(meeting.status == .completed)
        #expect(meeting.attribution == .transcription(voiceprintsUnavailable: .failed(reason: String(describing: LocalModelError()))))
        #expect(meeting.attribution?.hasVoiceprints == false)
        #expect(meeting.speakers.map(\.label) == ["A", "B"])
        #expect(meeting.speakers.allSatisfy { $0.person == nil && $0.embeddings.isEmpty })
        #expect(meeting.outputs.summary != nil)
        #expect(world.cloud.calls.get.count == 2)
    }

    @Test func reseparatingAfterTheModelIsFixedSplitsSpeakersWithoutTranscribingAgain() async throws {
        let world = try await World()
        world.cloud.behavior.update { $0 = .unreachable }
        world.diarizer.fails.update { $0 = true }
        let unseparated = try await world.processed()
        let llmCalls = world.llm.calls.get.count

        world.diarizer.fails.update { $0 = false }
        let separated = try await world.pipeline.reseparateSpeakers(unseparated.id)

        #expect(separated.status == .completed)
        #expect(separated.attribution == .local(overlaps: Script.diarization.overlaps))
        #expect(separated.speakers.map(\.label) == ["A", "B", "C"])
        #expect(separated.speaker(SpeakerID("r1"))?.person == world.aliceID)
        #expect(Set(separated.utterances.filter { $0.track == .remote }.map(\.speaker)).count == 3)
        #expect(separated.outputs.isStale)
        #expect(separated.suggestions.isStale)
        #expect(world.local.calls.get.count == 2)
        #expect(world.cloud.calls.get.count == 2)
        #expect(world.llm.calls.get.count == llmCalls)
        #expect(try await world.library.meeting(unseparated.id) == separated)

        let regenerated = try await world.pipeline.regenerateLLMOutputs(unseparated.id)
        #expect(!regenerated.outputs.isStale)
        #expect(!regenerated.suggestions.isStale)
    }

    @Test func reseparatingThatFailsAgainLeavesTheMeetingUsableAndKeepsEdits() async throws {
        let world = try await World()
        world.cloud.behavior.update { $0 = .unreachable }
        world.diarizer.fails.update { $0 = true }
        let unseparated = try await world.processed()
        let renamed = try await world.editing.rename(SpeakerID("r1"), in: unseparated.id, to: .newPerson(name: "Team"))

        let again = try await world.pipeline.reseparateSpeakers(unseparated.id)

        #expect(world.diarizer.calls.get == 2)
        #expect(again.status == .completed)
        #expect(again.attribution == .unseparated(.failed(reason: String(describing: LocalModelError()))))
        #expect(again.speakers == renamed.speakers)
        #expect(again.utterances == renamed.utterances)
        #expect(!again.outputs.isStale)
        _ = try await world.editing.rename(SpeakerID("r1"), in: unseparated.id, to: .existing(world.aliceID))
    }

    @Test func reseparatingThatCannotSeparateNeverDiscardsAnExistingSeparation() async throws {
        let world = try await World()
        world.cloud.behavior.update { $0 = .unreachable }
        let separated = try await world.processed()

        world.diarizer.fails.update { $0 = true }
        let rerun = try await world.pipeline.reseparateSpeakers(separated.id)

        #expect(rerun == separated)
    }

    @Test func reseparatingAMeetingThatIsNotCompletedIsRefused() async throws {
        let world = try await World()
        let recorded = try await world.record()
        world.llm.failNext.update { $0.insert("summarize") }
        let failed = try await world.pipeline.process(recorded.id)

        await #expect(throws: SpeakerSeparationError.meetingNotCompleted(failed.status)) {
            try await world.pipeline.reseparateSpeakers(recorded.id)
        }
        #expect(world.diarizer.calls.get == 1)
    }
}

@Suite struct EditingDuringProcessingTests {
    @Test func editsAreRefusedWhileProcessingRunsAndAllowedOnceItEnds() async throws {
        let world = try await World()
        let recorded = try await world.record()
        let editing = world.editing
        let refusal = Box<(any Error)?>(nil)
        world.llm.during.update {
            $0["cleanTranscript"] = {
                do { _ = try await editing.rename(SpeakerID("r2"), in: recorded.id, to: .newPerson(name: "Carol")) }
                catch { refusal.update { $0 = error } }
            }
        }

        let processed = try await world.pipeline.process(recorded.id)

        #expect(processed.status == .completed)
        #expect(refusal.get as? SpeakerEditError == .meetingIsProcessing)
        #expect(await world.voiceprints.person(named: "Carol") == nil)
        let renamed = try await world.editing.rename(SpeakerID("r2"), in: recorded.id, to: .newPerson(name: "Carol"))
        #expect(renamed.speaker(SpeakerID("r2"))?.person != nil)
    }

    @Test func anEditOnAFailedMeetingSurvivesTheRetry() async throws {
        let world = try await World()
        let recorded = try await world.record()
        world.llm.failNext.update { $0.insert("digestPerPerson") }
        _ = try await world.pipeline.process(recorded.id)

        let renamed = try await world.editing.rename(SpeakerID("r2"), in: recorded.id, to: .newPerson(name: "Carol"))
        let person = try #require(renamed.speaker(SpeakerID("r2"))?.person)

        let editing = world.editing
        let refusal = Box<(any Error)?>(nil)
        world.llm.during.update {
            $0["digestPerPerson"] = {
                do { _ = try await editing.rename(SpeakerID("r3"), in: recorded.id, to: .existing(PersonID())) }
                catch { refusal.update { $0 = error } }
            }
        }
        let retried = try await world.pipeline.process(recorded.id)

        #expect(retried.status == .completed)
        #expect(retried.speaker(SpeakerID("r2"))?.person == person)
        #expect(refusal.get as? SpeakerEditError == .meetingIsProcessing)
    }
}
