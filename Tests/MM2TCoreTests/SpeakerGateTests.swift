import AVFoundation
import Foundation
import Testing
@testable import MM2TCore

@Suite struct SpeakerGateTests {
    private let a = ClusterID("near"), b = ClusterID("neighbour"), tv = ClusterID("tv")

    @Test func callMicKeepsClosePeopleAndCutsDistantTurnsEvenInsideTheirCluster() throws {
        let heard = Diarization(segments: [turn(a, 0, 4), turn(b, 4, 8), turn(tv, 8, 12), turn(a, 12, 16)],
                                overlaps: [], embeddings: [:])
        let energy = try #require(syntheticEnergy([0.2, 0.1, 0.001, 0.001]))
        #expect(SpeakerGate().destinations(for: heard, mode: .callMic, energy: energy) ==
                [.foreground(a), .foreground(b), .background(tv), .background(a)])
    }

    @Test func callMicRejectsAClusterWithTooLittleSpeechAfterQuietTurnsAreRemoved() throws {
        let heard = Diarization(segments: [turn(a, 0, 4), turn(b, 4, 4.2), turn(b, 8, 12)],
                                overlaps: [], embeddings: [:])
        let energy = try #require(syntheticEnergy([0.2, 0.2, 0.001]))
        #expect(SpeakerGate().destinations(for: heard, mode: .callMic, energy: energy) ==
                [.foreground(a), .background(b), .background(b)])
    }

    @Test func callMergesOnlyASimilarShortVoiceAndDoesNotUseLoudness() throws {
        let fragment = ClusterID("fragment")
        let heard = Diarization(segments: [turn(a, 0, 4), turn(b, 4, 8), turn(tv, 8, 8.2), turn(fragment, 9, 9.2)],
                                overlaps: [], embeddings: [a: [Embedding([1, 0])], b: [Embedding([0, 1])]],
                                briefEmbeddings: [fragment: [Embedding([0.8, 0.1])], tv: [Embedding([-1, -1])]])
        let energy = try #require(syntheticEnergy([0.2, 0.001, 0.001]))
        #expect(SpeakerGate().destinations(for: heard, mode: .call, energy: energy) ==
                [.foreground(a), .foreground(b), .background(tv), .foreground(a)])
    }

    @Test func roomKeepsALongQuietSpeakerAndProtectsTheEnrolledUser() throws {
        let distant = ClusterID("distant")
        let heard = Diarization(segments: [turn(a, 0, 8), turn(b, 8, 8.2), turn(tv, 12, 16), turn(distant, 16, 32)],
                                overlaps: [], embeddings: [:])
        let energy = try #require(syntheticEnergy([0.2, 0.2, 0.001, 0.001] + Array(repeating: 0.001, count: 4)))
        #expect(SpeakerGate().destinations(for: heard, mode: .room, energy: energy, protecting: b) ==
                [.foreground(a), .foreground(b), .background(tv), .foreground(distant)])
    }

    @Test func dualThresholdKeepsSoftTurnsOnlyForEstablishedVoices() throws {
        let heard = Diarization(segments: [turn(a, 0, 4), turn(a, 4, 8), turn(tv, 8, 12), turn(a, 12, 16)],
                                overlaps: [], embeddings: [:])
        let energy = try #require(syntheticEnergy([0.2, 0.05, 0.05, 0.006]))
        let evidence = SpeakerGate.Evidence(for: heard, energy: energy, measuringMicGroups: true)
        let limits = SpeakerGate.CallMicThresholds(createDrop: 8, keepDrop: 18)
        let route = SpeakerGate().callMicDestinations(for: evidence, thresholds: limits, userEmbeddings: [], matchThresholds: thresholds, allowUnanchoredDual: true)
        // Give the established voice a majority of near-level frames, not just one loud spike.
        let established = Diarization(segments: [turn(a, 0, 4), turn(a, 4, 5), turn(tv, 8, 12), turn(a, 12, 13)],
                                      overlaps: [], embeddings: [:])
        let establishedEvidence = SpeakerGate.Evidence(for: established, energy: energy, measuringMicGroups: true)
        #expect(route == [.background(a), .background(a), .background(tv), .background(a)])
        #expect(SpeakerGate().callMicDestinations(for: establishedEvidence, thresholds: limits,
            userEmbeddings: [], matchThresholds: thresholds, allowUnanchoredDual: true) == [.foreground(a), .foreground(a), .background(tv), .background(a)])
    }

    @Test func unlimitedKeepPreservesSoftTurnsButDoesNotCreateSubsecondVoices() throws {
        let heard = Diarization(segments: [turn(a, 0, 4), turn(a, 4, 8), turn(tv, 8, 8.5)], overlaps: [], embeddings: [:])
        let energy = try #require(syntheticEnergy([0.2, 0.003, 0.2]))
        let evidence = SpeakerGate.Evidence(for: heard, energy: energy, measuringMicGroups: true)
        let limits = SpeakerGate.CallMicThresholds(createDrop: 14, keepDrop: .infinity)
        #expect(SpeakerGate().callMicDestinations(for: evidence, thresholds: limits,
            userEmbeddings: [], matchThresholds: thresholds, allowUnanchoredDual: true) == [.foreground(a), .foreground(a), .background(tv)])
        let noEnergy = SpeakerGate.Evidence(for: heard, energy: nil, measuringMicGroups: true)
        #expect(SpeakerGate().callMicDestinations(for: noEnergy, thresholds: limits,
            userEmbeddings: [], matchThresholds: thresholds, allowUnanchoredDual: true) == [.foreground(a), .foreground(a), .background(tv)])
    }

    @Test func dualThresholdAnchorsAtBestEnrolledVoiceAndProtectsConfirmedMe() throws {
        let match = MatchThresholds(autoName: 0.7, suggest: 0.60, user: 0.62)
        let person = Embedding([1, 0, 0])
        let near = Embedding([0.61, 0.7924, 0])
        let worse = Embedding([0.60, 0, 0.80])
        let turns = [turn(a, 0, 4), turn(b, 4, 8), turn(tv, 8, 12)]
        let energy = try #require(syntheticEnergy([0.05, 0.2, 0.035]))
        let gate = SpeakerGate()
        let limits = SpeakerGate.CallMicThresholds(createDrop: 6, keepDrop: 14)
        func decisions(_ embeddings: [ClusterID: [Embedding]], enrolled: [Embedding], experimental: Bool = false) -> [SpeakerGate.Destination] {
            let heard = Diarization(segments: turns, overlaps: [], embeddings: embeddings)
            let evidence = SpeakerGate.Evidence(for: heard, energy: energy, measuringMicGroups: true)
            return gate.callMicDestinations(for: evidence, thresholds: limits, userEmbeddings: enrolled, matchThresholds: match, allowUnanchoredDual: experimental)
        }
        #expect(decisions([a: [near], b: [worse]], enrolled: [person]) == [.foreground(a), .foreground(b), .foreground(tv)])
        let fallback: [SpeakerGate.Destination] = [.background(a), .foreground(b), .background(tv)]
        #expect(decisions([a: [near], b: [worse]], enrolled: [], experimental: true) == fallback)
        #expect(decisions([a: [Embedding([0, 1, 0])]], enrolled: [person]) == [.foreground(a), .foreground(b), .foreground(tv)])
        let short = Diarization(segments: [turn(a, 0, 0.5), turn(a, 4, 4.5), turn(b, 4.5, 8)],
                                overlaps: [], embeddings: [a: [person]])
        let quiet = try #require(syntheticEnergy([0.0001, 0.2]))
        let evidence = SpeakerGate.Evidence(for: short, energy: quiet, measuringMicGroups: true)
        #expect(gate.callMicDestinations(for: evidence, thresholds: limits,
            userEmbeddings: [person], matchThresholds: match) == [.foreground(a), .foreground(a), .foreground(b)])
    }

    @Test func offlineBackgroundNeverMatchesNamesOrEntersTheGeneratedTranscript() async throws {
        let heard = Diarization(segments: [turn(tv, 0.1, 0.3), turn(a, 4, 8), turn(b, 8, 12)], overlaps: [],
                                embeddings: [a: [Embedding([1, 0, 0])], b: [Embedding([0, 1, 0])], tv: [Embedding(bob)]])
        let world = try await World(diarization: heard)
        let record = try await world.record()
        _ = try await world.library.attach(transcript(remote: [TimedWord("TV", 0.11, 0.23), TimedWord("First", 6, 7),
                                                                TimedWord("Second", 9, 10)]), to: record.id)
        let meeting = try await world.pipeline.process(record.id)
        #expect(meeting.utterances.map(\.text) == ["First", "Second"])
        #expect(meeting.backgroundUtterances.map(\.text) == ["TV"])
        #expect(meeting.backgroundSpeakers.map(\.id) == [.remote(1)])
        #expect(meeting.backgroundSpeakers.map(\.label) == ["C"])
        #expect(meeting.backgroundSpeakers.first?.person == nil)
        #expect(!meeting.suggestions.items.contains { $0.speaker == .remote(1) })
        #expect(meeting.speakers.map(\.label) == ["A", "B"])
        #expect(world.llm.summaryRequests.get.first?.transcript.utterances.map(\.text) == ["First", "Second"])
        #expect(try await world.library.meeting(meeting.id).backgroundUtterances == meeting.backgroundUtterances)
    }

    @Test(arguments: [Track.me, .remote])
    func aRecordingWithOnlyAShortUnidentifiedVoiceStaysRestorable(_ track: Track) async throws {
        let heard = Diarization(segments: [turn(a, 0, 0.6)], overlaps: [], embeddings: [:])
        let world = try await World(diarization: heard)
        let record = try await world.record()
        let line = TimedWord("Checking", 0.1, 0.5)
        let words = transcript(mic: track == .me ? [line] : [], remote: track == .remote ? [line] : [])
        _ = try await world.library.attach(words, to: record.id)
        let meeting = try await world.pipeline.process(record.id)
        #expect(meeting.utterances.isEmpty)
        #expect(meeting.backgroundUtterances.map(\.text) == ["Checking"])
        #expect(world.llm.summaryRequests.get.isEmpty)
        let speaker = try #require(meeting.backgroundSpeakers.first)
        let restored = try await world.editing.restoreBackground(speaker.id, in: record.id)
        #expect(restored.utterances.map(\.text) == ["Checking"])
        #expect(restored.backgroundSpeakers.isEmpty)
    }

    @Test(arguments: [true, false])
    func calibratedMicPolicyUsesDualGateOnlyWithEnrollment(_ enrolled: Bool) async throws {
        let world = try await World()
        if enrolled { try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding([1, 0, 0])]) }
        let mic = Diarization(segments: [turn(tv, 0, 4), turn(a, 4, 8), turn(b, 8, 12), turn(a, 12.25, 13.25),
                                         turn(b, 16.4, 17.4), turn(b, 20.4, 21.4)],
                              overlaps: [], embeddings: [a: [Embedding([1, 0, 0])], b: [Embedding([0, 1, 0])]])
        world.diarizer.micOnCall.update { $0 = mic }
        let words = transcript(mic: [TimedWord("TV", 1, 2), TimedWord("Near", 5, 6), TimedWord("Beside", 9, 10),
                                     TimedWord("Soft", 12.4, 13), TimedWord("Aside", 16.5, 17.2),
                                     TimedWord("Faint", 20.5, 21.2)], remote: [TimedWord("Call", 25, 26)])
        let record = try await world.record()
        let micURL = await world.library.audioURL(record, track: .me)
        let amplitudes: [Float] = [0.05, 0.2, 0.1, 0.01, 0.05, 0.03]
        try writeMic(amplitudes, to: micURL)
        let disk = try SpeechEnergy(reading: micURL, through: 21.4)
        let soft = try #require(disk.level(in: TimeRange(start: 12.25, end: 13.25)))
        #expect(soft.db < -35)
        _ = try await world.library.attach(words, to: record.id)
        let processed = try await world.pipeline.process(record.id)
        let live = try await world.record()
        let energy = try #require(syntheticEnergy(amplitudes))
        let remote = Diarization(segments: [turn(b, 24, 28)], overlaps: [], embeddings: [:])
        let tracks: [Track: Diarization] = [.me: mic, .remote: remote]
        let draft = await world.pipeline.recordingDraft(transcription: words, diarizations: tracks, echo: nil,
            metadata: live.metadata, highlights: [], micEnergy: energy)
        try await world.pipeline.attachRecording(words, diarizations: tracks, echo: nil, to: live.id, micEnergy: energy)
        for (path, meeting) in [("offline", processed), ("draft", draft), ("final", try await world.library.meeting(live.id))] {
            #expect(meeting.utterances.map(\.text) == (enrolled ? ["Near", "Beside", "Soft", "Aside", "Call"] : ["TV", "Near", "Beside", "Aside", "Faint", "Call"]), "\(path)")
            #expect(meeting.backgroundUtterances.map(\.text) == (enrolled ? ["TV", "Faint"] : ["Soft"]), "\(path)")
            #expect((meeting.utterances.first { $0.text == "Near" }?.speaker == .me) == enrolled)
            if enrolled { #expect(meeting.utterances.first { $0.text == "Soft" }?.speaker == .me) }
        }
    }

    @Test func offlineCallMicReadsTheTrackAndKeepsALoudNeighbour() async throws {
        let world = try await World()
        try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding([1, 0, 0])])
        world.diarizer.micOnCall.update {
            $0 = Diarization(segments: [turn(tv, 0, 4), turn(a, 4, 8), turn(b, 8, 12)], overlaps: [],
                             embeddings: [a: [Embedding([1, 0, 0])], b: [Embedding([0, 1, 0])]])
        }
        let record = try await world.record()
        let url = await world.library.audioURL(record, track: .me)
        try writeMic([0.001, 0.2, 0.1], to: url)
        _ = try await world.library.attach(transcript(mic: [TimedWord("TV", 1, 2), TimedWord("Near", 5, 6),
                                                            TimedWord("Beside", 9, 10)],
                                                      remote: [TimedWord("Call", 13, 14)]), to: record.id)
        let meeting = try await world.pipeline.process(record.id)
        #expect(meeting.backgroundUtterances.map(\.text) == ["TV"])
        #expect(meeting.utterances.first?.speaker == .me)
        #expect(meeting.utterances.first(where: { $0.text == "Beside" })?.speaker != .me)
    }

    @Test func recordedDraftAndFinalAttachmentGateTheMicBeforeVoiceprintAssignment() async throws {
        let world = try await World()
        try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding([1, 0, 0])])
        let mic = Diarization(segments: [turn(tv, 0, 4), turn(a, 4, 8), turn(b, 8, 12)], overlaps: [],
                             embeddings: [a: [Embedding([1, 0, 0])], b: [Embedding([0, 1, 0])], tv: [Embedding(bob)]])
        let remote = Diarization(segments: [turn(a, 12, 16)], overlaps: [], embeddings: [:])
        let recorded: [Track: Diarization] = [.me: mic, .remote: remote]
        let words = transcript(mic: [TimedWord("TV", 1, 2), TimedWord("Near", 5, 6), TimedWord("Beside", 9, 10)],
                               remote: [TimedWord("Call", 13, 14)])
        let energy = try #require(syntheticEnergy([0.001, 0.2, 0.1]))
        let record = try await world.record()
        let draft = await world.pipeline.recordingDraft(transcription: words, diarizations: recorded, echo: nil,
                                                        metadata: record.metadata, highlights: [], micEnergy: energy)
        try await world.pipeline.attachRecording(words, diarizations: recorded, echo: nil, to: record.id, micEnergy: energy)
        let final = try await world.library.meeting(record.id)
        for meeting in [draft, final] {
            #expect(meeting.utterances.map(\.text) == ["Near", "Beside", "Call"])
            #expect(meeting.utterances.first?.speaker == .me)
            let neighbour = try #require(meeting.utterances.first { $0.text == "Beside" })
            #expect(neighbour.speaker != .me)
            #expect(meeting.backgroundUtterances.map(\.text) == ["TV"])
            #expect(meeting.backgroundSpeakers.count == 1)
        }
    }

    @Test func restoreAndDeletePersistAndDeletionForgetsOnlyThisMeetingsVectors() async throws {
        let world = try await World()
        var meeting = try await world.processed()
        let first = try #require(meeting.speakers.first)
        let lines = meeting.utterances.filter { $0.speaker == first.id }
        meeting.backgroundSpeakers = [first]
        meeting.backgroundUtterances = lines
        meeting.speakers.removeAll { $0.id == first.id }
        meeting.utterances.removeAll { $0.speaker == first.id }
        try await world.library.save(meeting)
        let restored = try await world.editing.restoreBackground(first.id, in: meeting.id)
        #expect(restored.backgroundSpeakers.isEmpty && restored.backgroundUtterances.isEmpty)
        #expect(restored.utterances.filter { $0.speaker == first.id } == lines)
        #expect(restored.utterances.map(\.range.start) == restored.utterances.map(\.range.start).sorted())
        #expect(restored.speakers.map(\.label) == ["A", "B", "C"])
        #expect(restored.outputs.isStale && restored.suggestions.isStale)
        try await world.editing.learnVoice(of: first.id, in: meeting.id)
        #expect(await world.voiceprints.person(world.aliceID)?.embeddings.count == 2)
        let deleted = try await world.editing.delete(first.id, in: meeting.id)
        #expect(deleted.utterances.allSatisfy { $0.speaker != first.id })
        #expect(deleted.remoteSegments.allSatisfy { $0.speaker != first.id })
        #expect(deleted.suggestions.items.allSatisfy { $0.speaker != first.id })
        #expect(deleted.outputs.isStale)
        #expect(deleted.speakers.map(\.label) == ["A", "B"])
        #expect(await world.voiceprints.person(world.aliceID)?.embeddings == [Embedding(alice)])
        #expect(try await world.library.meeting(meeting.id) == deleted)
        let rebuilt = try await world.pipeline.reseparateSpeakers(meeting.id)
        #expect(rebuilt.speakers.count == 2)
        #expect(rebuilt.utterances.allSatisfy { !$0.text.contains("Ship") && !$0.text.contains("Hi") })
        await #expect(throws: SpeakerEditError.cannotEditMe) {
            try await world.editing.delete(.me, in: meeting.id)
        }
        let pending = try await world.record()
        await #expect(throws: SpeakerEditError.meetingIsProcessing) {
            try await world.editing.delete(first.id, in: pending.id)
        }
        await #expect(throws: SpeakerEditError.meetingIsProcessing) {
            try await world.editing.restoreBackground(first.id, in: pending.id)
        }
    }

    @Test func meetingsWithoutBackgroundKeysStillDecode() async throws {
        let world = try await World()
        let meeting = try await world.processed()
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
        legacy.removeValue(forKey: "backgroundSpeakers")
        legacy.removeValue(forKey: "backgroundUtterances")
        let reopened = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(reopened == meeting)
        #expect(reopened.backgroundSpeakers.isEmpty && reopened.backgroundUtterances.isEmpty)
    }

    @Test func regeneratingAfterDeletingTheLastSpeakerClearsSavedOutputs() async throws {
        let world = try await World(diarization: Diarization(segments: [turn(a, 0, 4)], overlaps: [], embeddings: [:]))
        let record = try await world.record()
        _ = try await world.library.attach(transcript(remote: [TimedWord("Only speaker", 1, 2)]), to: record.id)
        var meeting = try await world.pipeline.process(record.id)
        #expect(meeting.outputs.cleaned != nil && meeting.outputs.summary != nil && meeting.outputs.digests != nil)
        meeting.summaryMarkdown = "Old custom summary"
        meeting.perPersonMarkdown = "Old custom notes"
        try await world.library.save(meeting)
        let speaker = try #require(meeting.speakers.first)
        let deleted = try await world.editing.delete(speaker.id, in: record.id)
        #expect(deleted.utterances.isEmpty && deleted.outputs.isStale)
        let calls = world.llm.calls.get
        _ = try await world.pipeline.regenerateLLMOutputs(record.id)
        let saved = try await world.library.meeting(record.id)
        #expect(saved.status == .completed)
        #expect(saved.outputs == LLMOutputs())
        #expect(saved.suggestions == NameSuggestions())
        #expect(saved.summaryMarkdown == nil && saved.perPersonMarkdown == nil)
        #expect(world.llm.calls.get == calls)
    }

    @Test(arguments: ["enrolled-match", "enrolled-other", "enrolled-no-vector", "unenrolled-single", "unenrolled-filtered"])
    func aSingleForegroundMicVoiceUsesEnrollmentOrTheOriginalSingleClusterShortcut(_ scenario: String) async throws {
        let world = try await World()
        let enrolled = scenario.hasPrefix("enrolled")
        if enrolled { try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding([1, 0, 0])]) }
        let filtered = scenario == "unenrolled-filtered"
        let vectors: [ClusterID: [Embedding]] = scenario == "enrolled-no-vector" ? [:]
            : [a: [Embedding(scenario == "enrolled-match" ? [1, 0, 0] : [0, 1, 0])]]
        let mic = Diarization(segments: [turn(a, 0, 4)] + (filtered ? [turn(tv, 4, 8)] : []), overlaps: [], embeddings: vectors)
        let words = transcript(mic: [TimedWord("Near", 1, 2)] + (filtered ? [TimedWord("TV", 5, 6)] : []),
                               remote: [TimedWord("Call", 9, 10)])
        let record = try await world.record()
        let draft = await world.pipeline.recordingDraft(transcription: words, diarizations: [.me: mic], echo: nil,
            metadata: record.metadata, highlights: [], micEnergy: try #require(syntheticEnergy([0.2, 0.001])))
        let near = try #require(draft.utterances.first { $0.text == "Near" })
        #expect((near.speaker == .me) == (scenario == "enrolled-match" || scenario == "unenrolled-single"))
        if near.speaker != .me { #expect(draft.speaker(near.speaker) != nil) }
        #expect(draft.backgroundUtterances.map(\.text) == (filtered ? ["TV"] : []))
    }

    @Test func unreadableMicEnergyStillGatesShortSpeechOfflineAndAtFinalAttachment() async throws {
        let mic = Diarization(segments: [turn(a, 0, 4), turn(tv, 4, 4.5)], overlaps: [], embeddings: [:])
        let words = transcript(mic: [TimedWord("Near", 1, 2), TimedWord("Short", 4.1, 4.4)],
                               remote: [TimedWord("Call", 9, 10)])
        let world = try await World()
        world.diarizer.micOnCall.update { $0 = mic }
        let offline = try await world.record()
        let attached = try await world.record()
        _ = try await world.library.attach(words, to: offline.id)
        let processed = try await world.pipeline.process(offline.id)
        try await world.pipeline.attachRecording(words, diarizations: [.me: mic, .remote: Script.diarization], echo: nil, to: attached.id)
        for meeting in [processed, try await world.library.meeting(attached.id)] {
            #expect(meeting.utterances.map(\.text) == ["Near", "Call"])
            #expect(meeting.backgroundUtterances.map(\.text) == ["Short"])
        }
    }

    @Test func anOverlappedDeletedSpeakerDoesNotReappearAfterReseparation() async throws {
        let heard = Diarization(segments: [turn(b, 2, 5), turn(a, 0, 8)], overlaps: [TimeRange(start: 2, end: 5)],
                                embeddings: [a: [Embedding([1, 0, 0])], b: [Embedding([0, 1, 0])]])
        let world = try await World(diarization: heard)
        let record = try await world.record()
        _ = try await world.library.attach(transcript(remote: [TimedWord("Keep", 0.5, 1), TimedWord("Remove", 3, 4), TimedWord("Stays", 4.5, 5.5)]), to: record.id)
        let meeting = try await world.pipeline.process(record.id)
        let removed = try #require(meeting.utterances.first { $0.text == "Remove" })
        _ = try await world.editing.delete(removed.speaker, in: record.id)
        // Boundaries shifted on rerun. Without the overlapping tombstone, the deleted turn
        // would steal the retained "Stays" word, so pruning empty speakers alone cannot pass.
        let shifted = Diarization(segments: [turn(b, 2.01, 5.01), turn(a, 0, 1.5), turn(a, 5.25, 8), turn(tv, 20, 24)],
                                  overlaps: [], embeddings: heard.embeddings)
        let rerun = MeetingProcessingPipeline(library: world.library, voiceprints: world.voiceprints,
            diarizer: ScriptedDiarizer(shifted), embedder: nil, transcription: TranscriptionChain([]),
            llm: nil, thresholds: thresholds, vocabulary: [])
        let again = try await rerun.reseparateSpeakers(record.id)
        #expect(again.utterances.flatMap(\.words).map(\.text) == ["Keep", "Stays"])
        #expect(again.speakers.count == 1 && again.backgroundSpeakers.isEmpty)
        #expect(again.remoteSegments.map(\.range) == [TimeRange(start: 0, end: 1.5), TimeRange(start: 5.25, end: 8)])
    }

    @Test(arguments: [Track.remote, .me])
    func sttLabelWithLongPausesIsStillAShortBackgroundVoice(_ track: Track) async throws {
        let world = try await World(localModel: .none, diarizationOrder: [.transcription])
        let record = try await world.record()
        let labeled = [LabeledWord(TimedWord("First", 0, 0.4), speaker: a),
                       LabeledWord(TimedWord("Second", 5, 5.4), speaker: a),
                       LabeledWord(TimedWord("Main speaker", 6, 9), speaker: b)]
        let empty = transcript(remote: []).me
        let speech = TrackTranscript(source: .cloud, content: .labeled(labeled))
        let words = Transcription(me: track == .me ? speech : empty, remote: track == .remote ? speech : empty)
        _ = try await world.library.attach(words, to: record.id)
        let meeting = try await world.pipeline.process(record.id)
        #expect(meeting.utterances.map(\.text) == ["Main speaker"])
        #expect(meeting.backgroundUtterances.flatMap(\.words).map(\.text) == ["First", "Second"])
    }

    @Test func quietMicWordsWithoutATurnStayRestorableAndDoNotBorrowTheNextVoice() async throws {
        let world = try await World()
        try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding([1, 0, 0])])
        let mic = Diarization(segments: [turn(a, 0, 4), turn(a, 8, 12), turn(a, 12, 16)],
                              overlaps: [], embeddings: [a: [Embedding([1, 0, 0])]])
        let words = transcript(mic: [TimedWord("Near", 2, 3), TimedWord("Quiet", 4.5, 5.5),
                                     TimedWord("aside", 6, 7), TimedWord("Soft reply", 8.2, 9),
                                     TimedWord("Next", 13, 15)], remote: [TimedWord("Call", 1, 2)])
        let record = try await world.record()
        try await world.pipeline.attachRecording(words, diarizations: [.me: mic], echo: nil, to: record.id,
            micEnergy: try #require(syntheticEnergy([0.2, 0.001, 0.001, 0.2])))
        let saved = try await world.library.meeting(record.id)
        #expect(saved.backgroundUtterances.flatMap(\.words).map(\.text) == ["Quiet", "aside"])
        #expect(saved.utterances.filter { $0.speaker == .me }.flatMap(\.words).map(\.text) == ["Near", "Soft reply", "Next"])
    }

    private func writeMic(_ amplitudes: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames: AVAudioFrameCount = 64_000
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        let channel = try #require(buffer.floatChannelData?[0])
        let audio = try AVAudioFile(forWriting: url, settings: format.settings)
        buffer.frameLength = frames
        for amplitude in amplitudes {
            channel.update(repeating: amplitude, count: Int(frames))
            try audio.write(from: buffer)
        }
    }

    private func syntheticEnergy(_ amplitudes: [Float]) -> SpeechEnergy? {
        var builder = SpeechEnergy.Builder()
        // An intentionally non-frame-aligned append verifies the pending-frame carry.
        for amplitude in amplitudes {
            builder.append(Array(repeating: amplitude, count: 15_999))
            builder.append(Array(repeating: amplitude, count: 48_001))
        }
        return builder.energy
    }

    private func turn(_ id: ClusterID, _ start: Double, _ end: Double) -> Diarization.Segment {
        .init(cluster: id, range: TimeRange(start: start, end: end))
    }

    private func transcript(mic: [TimedWord] = [], remote: [TimedWord]) -> Transcription {
        Transcription(me: TrackTranscript(source: .local, content: .unlabeled(mic)),
                      remote: TrackTranscript(source: .local, content: .unlabeled(remote)))
    }
}
