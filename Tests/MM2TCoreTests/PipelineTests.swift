import Foundation
import Testing
@testable import MM2TCore

@Suite struct PipelineTests {
    @Test func attributesSpeechToEachRemoteSpeakerAndTheMicToMe() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        #expect(meeting.status == .completed)
        #expect(meeting.speakers.map(\.label) == ["A", "B", "C"])
        #expect(meeting.utterances.map(\.text) == ["Hi team,小明你覺得呢", "我覺得可以", "我同意", "Ship it", "Thanks all"])
        #expect(meeting.utterances.map(\.speaker.rawValue) == ["r1", "r2", "r3", "r1", "me"])
        #expect(meeting.utterances.map(\.track) == [.remote, .remote, .remote, .remote, .me])
        #expect(meeting.utterances[0].words.first == TimedWord("Hi", 0.5, 1))
    }

    @Test func autoNamesKnownPersonButOnlySuggestsALowConfidenceMatch() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        #expect(meeting.speaker(SpeakerID("r1"))?.person == world.aliceID)
        #expect(meeting.speaker(SpeakerID("r2"))?.person == nil)
        #expect(meeting.speaker(SpeakerID("r3"))?.person == nil)
        #expect(meeting.suggestions.items.contains { $0.speaker == SpeakerID("r3") && $0.voiceprintPerson == world.bobID })
        #expect(!meeting.suggestions.items.contains { $0.speaker == SpeakerID("r2") && $0.voiceprintPerson != nil })
        let raw = await world.render(meeting, .raw)
        #expect(raw.contains("Alice: Hi team"))
        #expect(raw.contains("B: 我覺得可以"))
        #expect(raw.contains("C: 我同意"))
        #expect(!raw.contains("Bob"))
    }

    @Test func automaticMatchesNeverAddVoiceprints() async throws {
        let world = try await World()
        _ = try await world.processed()

        #expect(await world.voiceprints.person(world.aliceID)?.embeddings == [Embedding(alice)])
        #expect(await world.voiceprints.person(world.bobID)?.embeddings == [Embedding(bob)])
    }

    @Test func llmNameGuessesBecomeSuggestionsOnlyForUnnamedSpeakersInTheMeeting() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        let inferred = meeting.suggestions.items.filter { if case .inferred = $0.source { true } else { false } }
        #expect(inferred.map(\.speaker) == [SpeakerID("r2")])
        #expect(meeting.speaker(SpeakerID("r2"))?.person == nil)
    }

    @Test func flagsOverlappingSpeech() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        #expect(meeting.utterances.map(\.isOverlapping) == [false, true, true, false, false])
        #expect(await world.render(meeting, .raw).contains("我同意 (overlapping speech)"))
    }

    @Test func sendsKnownNamesAndCustomVocabularyAsSTTHints() async throws {
        let world = try await World()
        _ = try await world.processed()

        let calls = world.cloud.calls.get
        #expect(calls.map(\.file).sorted() == ["mic.caf", "remote.caf"])
        for call in calls {
            #expect(call.hints == ["Alice", "Bob", "mm2t"])
        }
    }

    @Test func recordsTheTranscriptionSourceActuallyUsed() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        #expect(meeting.transcription?.me.source == .cloud)
        #expect(meeting.transcription?.remote.source == .cloud)
        #expect(world.selfHosted.calls.get.count == 2)
        #expect(world.local.calls.get.isEmpty)
    }

    @Test func highlightedSpeechIsPrioritizedInTheSummaryInput() async throws {
        let world = try await World()
        _ = try await world.processed()

        let request = try #require(world.llm.summaryRequests.get.first)
        #expect(request.prioritized.map(\.text) == ["Ship it"])
        #expect(request.transcript.utterances.count == 5)
    }

    @Test func failedStepIsRecordedKeepsTheRecordingAndRetryResumesThere() async throws {
        let world = try await World()
        let recorded = try await world.record()
        world.llm.failNext.update { $0.insert("digestPerPerson") }

        let failed = try await world.pipeline.process(recorded.id)
        guard case .failed(.digestPerPerson, let reason) = failed.status else {
            Issue.record("expected failure at digestPerPerson, got \(failed.status)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(failed.outputs.cleaned != nil)
        #expect(try await world.library.meeting(recorded.id).status == failed.status)
        for track in Track.allCases {
            #expect(FileManager.default.fileExists(atPath: await world.library.audioURL(failed, track: track).path))
        }

        let steps = Box<[ProcessingStep]>([])
        let retried = try await world.pipeline.process(recorded.id) { step in steps.update { $0.append(step) } }

        #expect(retried.status == .completed)
        #expect(steps.get == [.digestPerPerson, .summarize])
        #expect(world.diarizer.calls.get == 1)
        #expect(world.cloud.calls.get.count == 2)
        #expect(world.llm.calls.get == ["inferNames", "cleanTranscript", "digestPerPerson", "digestPerPerson", "summarize"])
    }

    @Test func sttFailureThatIsNotAConnectionProblemStopsAtTranscribe() async throws {
        let world = try await World()
        world.cloud.behavior.update { $0 = .failed }
        let recorded = try await world.record()

        let failed = try await world.pipeline.process(recorded.id)
        #expect(failed.status == .failed(step: .transcribe, reason: String(describing: TranscriptionError.failed("invalid API key"))))
        #expect(world.local.calls.get.isEmpty)

        world.cloud.behavior.update { $0 = .words }
        let retried = try await world.pipeline.process(recorded.id)
        #expect(retried.status == .completed)
        #expect(world.diarizer.calls.get == 1)
    }

    @Test func reportsProgressThroughEveryStepInOrder() async throws {
        let world = try await World()
        let steps = Box<[ProcessingStep]>([])
        _ = try await world.pipeline.process(world.record().id) { step in steps.update { $0.append(step) } }
        #expect(steps.get == [.transcribe, .diarize, .matchVoiceprints, .align, .inferNames,
                              .cleanTranscript, .digestPerPerson, .summarize])
    }

    @Test func remoteSpeechTheDiarizerMissedStillGetsAnUnnamedSpeaker() async throws {
        let world = try await World(diarization: Diarization(segments: [], overlaps: [], embeddings: [:]))
        let meeting = try await world.processed()

        #expect(meeting.speakers.map(\.label) == ["A"])
        let remote = meeting.utterances.filter { $0.track == .remote }
        #expect(remote.map(\.text) == ["Hi team,小明你覺得呢我覺得可以我同意", "Ship it"])
        #expect(remote.allSatisfy { $0.speaker == SpeakerID("r1") })
    }
}

extension NameSuggestion {
    var voiceprintPerson: PersonID? {
        if case .voiceprint(let person, _) = source { person } else { nil }
    }
}
