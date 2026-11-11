import AVFoundation
import Foundation
import MM2TCore
import Testing
@testable import MM2TDiarization

/// The real models on real Mandarin meeting audio. Evaluation/diarization/RESULTS.md measured this
/// session (`R8007_M8011`, `nearmix_opus`, 0.5 s gaps bridged) at 4/4 speakers, DER c0.25 4.94%,
/// confusion 0.37%, overlap recall 84.9%.
@Suite(.serialized, .enabled(if: EvaluationData.available, "needs Evaluation/diarization data and models"))
struct RealAudioTests {
    let data = EvaluationData()

    @Test func separatesTheFourSpeakersOfAnAliMeetingSessionAsTheEvaluationMeasured() async throws {
        let embedder = WeSpeakerEmbedder(models: data.models)
        let diarizer = NemotronDiarizer(models: data.models, embedder: embedder)
        let end = try data.scoredEnd()
        let reference = try readRTTM(data.reference)

        let clock = ContinuousClock()
        let footprintBefore = currentFootprintMB()
        let warmup = try clip(seconds: 60)
        let warmupStart = clock.now
        _ = try await diarizer.diarize(track: warmup)
        let warmupWall = clock.now - warmupStart
        let footprintLoaded = currentFootprintMB()

        let start = clock.now
        let (result, peak) = try await peakFootprintMB { try await diarizer.diarize(track: data.track) }
        let wall = clock.now - start

        let clusters = Set(result.segments.map(\.cluster))
        let score = Score(reference: reference, hypothesis: result.segments, to: end, collar: 0.25)
        let strict = Score(reference: reference, hypothesis: result.segments, to: end, collar: 0)
        let harness = SpeakerTurns.bridgingGaps(try readRTTM(data.harness), shorterThan: 0.5)
        let agreement = frameAgreement(result.segments, harness, to: end)

        let referenceOverlap = SpeakerTurns.overlaps(reference)
        let hit = referenceOverlap.flatMap { r in result.overlaps.map { r.overlap(with: $0) } }.reduce(0, +)
        let recall = hit / referenceOverlap.map(\.duration).reduce(0, +)

        print("""
            [real] \(EvaluationData.session) collar 0.25: \(score)
            [real] collar 0: \(strict)
            [real] frame agreement with the evaluation harness (both bridged): \(String(format: "%.4f%%", agreement * 100))
            [real] overlap recall \(String(format: "%.1f%%", recall * 100)), \(result.overlaps.count) regions
            [real] load models + 60 s warm-up \(warmupWall); footprint \(Int(footprintBefore)) -> \(Int(footprintLoaded)) MB with models loaded
            [real] diarize + embed \(wall) for \(String(format: "%.0f", end)) s of audio; peak footprint \(Int(peak)) MB (+\(Int(peak - footprintLoaded)) MB over loaded), peak RSS \(Int(peakResidentMB())) MB
            """)

        #expect(clusters.count == 4, "the evaluation counted 4 of 4 speakers")
        // Same model, preset and post-processing as the harness, so the only expected gap is this
        // scorer's 10 ms grid against pyannote.metrics' exact segments, a few hundredths of a
        // point. 1% leaves room for that and stays far under the 3% pass line RESULTS.md sets.
        #expect(score.confusion / score.total < 0.01, "evaluation: 0.37%")
        #expect(abs(score.der - 0.0494) < 0.005, "evaluation: DER c0.25 4.94%")
        #expect(agreement > 0.999, "streaming the file must reproduce the harness's whole-file run")
        #expect(recall > 0.8, "evaluation: 84.9%")

        for cluster in clusters {
            let vectors = try #require(result.embeddings[cluster], "\(cluster.rawValue) spoke minutes, so it has a voiceprint")
            #expect(vectors.count == 1 && vectors[0].values.count == 256)
        }
        let prints = clusters.sorted { $0.rawValue < $1.rawValue }.map { result.embeddings[$0]![0] }
        for (i, a) in prints.enumerated() {
            for b in prints[(i + 1)...] {
                print(String(format: "[real] voiceprint cosine between two clusters: %.3f", a.cosineSimilarity(to: b)))
                // RESULTS.md saw different people reach 0.607, above `suggest`; only `autoName` must hold.
                #expect(a.cosineSimilarity(to: b) < MatchThresholds.weSpeaker.autoName,
                        "different people in one meeting must never auto-name each other")
            }
        }

        let embedStart = clock.now
        _ = try await embedder.embeddings(track: data.track, segments: result.segments)
        print("[real] embedder alone (convert + embed) \(clock.now - embedStart)")
    }

    @Test func aPersonEnrolledFromTheFirstHalfIsAutoNamedInTheSecondHalf() async throws {
        let source = try TrackAudio(converting: data.track)
        defer { source.remove() }
        let end = try data.scoredEnd()
        let middle = (end / 2).rounded()
        let reference = try readRTTM(data.reference)
        let directory = try temporaryDirectory()

        // The first half arrives as 48 kHz stereo, the second as the 16 kHz mono original, so
        // a timeline shift in conversion would show up as a worse score for the first.
        let firstHalf = directory.appending(path: "first.wav")
        try writeAudio(
            Array(repeating: try upsample(source.samples(from: 0, count: Int(middle) * 16_000), to: 48_000), count: 2),
            sampleRate: 48_000, to: firstHalf, settings: wavSettings(sampleRate: 48_000, channels: 2, float: false))
        let secondHalf = directory.appending(path: "second.wav")
        try writeAudio([source.samples(from: Int(middle) * 16_000, count: Int(end - middle) * 16_000)],
                       sampleRate: 16_000, to: secondHalf, settings: wavSettings(sampleRate: 16_000, channels: 1, float: false))

        let library = MeetingLibrary(root: directory.appending(path: "library"))
        let voiceprints = try VoiceprintStore(fileURL: directory.appending(path: "voiceprints.json"))
        let embedder = WeSpeakerEmbedder(models: data.models)
        let pipeline = MeetingProcessingPipeline(
            library: library, voiceprints: voiceprints,
            diarizer: NemotronDiarizer(models: data.models, embedder: embedder), embedder: embedder,
            transcription: TranscriptionChain([.init(.cloud, EveryTwoSecondsSTT())]),
            llm: SilentLLM(), thresholds: .weSpeaker, vocabulary: [])

        func run(_ track: URL, duration: TimeInterval) async throws -> Meeting {
            let mic = directory.appending(path: "mic-\(UUID().uuidString).wav")
            try writeAudio([[Float](repeating: 0, count: 16_000)], sampleRate: 16_000, to: mic,
                           settings: wavSettings(sampleRate: 16_000, channels: 1, float: false))
            let created = try await library.create(Recording(
                micTrack: mic, remoteTrack: track, highlights: [],
                metadata: MeetingMetadata(title: track.lastPathComponent, startedAt: Date(), duration: duration)))
            let meeting = try await pipeline.process(created.id)
            #expect(meeting.status == .completed)
            guard case .local = meeting.attribution else {
                Issue.record("expected local separation, got \(String(describing: meeting.attribution))")
                return meeting
            }
            return meeting
        }
        func hypothesis(_ meeting: Meeting) -> [Diarization.Segment] {
            meeting.remoteSegments.map { .init(cluster: ClusterID($0.speaker.rawValue), range: $0.range) }
        }

        let first = try await run(firstHalf, duration: middle)
        let firstScore = Score(reference: reference, hypothesis: hypothesis(first), to: middle, collar: 0.25)
        var enrolled: [ClusterID: PersonID] = [:]
        for speaker in first.speakers where !speaker.embeddings.isEmpty {
            let person = try #require(firstScore.mapping[ClusterID(speaker.id.rawValue)])
            enrolled[person] = try await voiceprints.addPerson(name: person.rawValue, embeddings: speaker.embeddings)
        }

        let shifted = reference.compactMap { turn -> Diarization.Segment? in
            turn.range.end <= middle ? nil
                : segment(turn.cluster.rawValue, max(0, turn.range.start - middle), turn.range.end - middle)
        }
        let second = try await run(secondHalf, duration: end - middle)
        let secondScore = Score(reference: shifted, hypothesis: hypothesis(second), to: end - middle, collar: 0.25)

        print("[e2e] first half (48 kHz stereo): \(firstScore); enrolled \(enrolled.count)")
        print("[e2e] second half (16 kHz mono): \(secondScore)")
        var autoNamed = 0
        for speaker in second.speakers {
            let person = secondScore.mapping[ClusterID(speaker.id.rawValue)]
            let best = await voiceprints.match(speaker.embeddings, thresholds: .weSpeaker)
            let similarities = await voiceprints.allPersons().map { stored in
                "\(stored.name) " + String(format: "%.3f", speaker.embeddings.first.map { stored.embeddings[0].cosineSimilarity(to: $0) } ?? .nan)
            }
            print("[e2e] \(speaker.label) is \(person?.rawValue ?? "unmapped"), \(speaker.embeddings.count) voiceprint(s): \(best); \(similarities)")
            if let person, let expected = enrolled[person], !speaker.embeddings.isEmpty {
                #expect(speaker.person == expected, "\(speaker.label) should be auto-named \(person.rawValue)")
                if speaker.person == expected { autoNamed += 1 }
            } else {
                #expect(speaker.person == nil, "nobody may be named after a person they are not")
            }
        }

        #expect(firstScore.confusion / firstScore.total < 0.02 && firstScore.der < 0.08,
                "resampled 48 kHz stereo input separates as well as the original")
        #expect(enrolled.count == 4, "every speaker of the first half has enough clean speech to enroll")
        #expect(autoNamed == 4, "all four are recognized in the second half")
    }

    /// Memory and speed for a two-hour meeting: four sessions back to back (16 people, more than
    /// the model's 8 slots, so only the resource numbers mean anything). Opt in with
    /// MM2T_LONG_MEETING=1 and run it alone, since the footprint is process-wide.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_LONG_MEETING"] == "1"))
    func twoHourMeetingResources() async throws {
        let sessions = ["R8001_M8004", "R8003_M8001", "R8007_M8010", "R8007_M8011"]
        let long = try temporaryDirectory().appending(path: "two-hours.wav")
        var seconds = 0.0
        do {
            let file = try AVAudioFile(forWriting: long, settings: wavSettings(sampleRate: 16_000, channels: 1, float: false),
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            for session in sessions {
                let audio = try TrackAudio(converting: EvaluationData.root.appending(path: "data/wav/nearmix_opus/\(session)__nearmix_opus.wav"))
                defer { audio.remove() }
                for offset in stride(from: 0, to: audio.sampleCount, by: 480_000) {
                    let block = audio.samples(from: offset, count: 480_000)
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block.count))!
                    buffer.frameLength = AVAudioFrameCount(block.count)
                    block.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: block.count) }
                    try file.write(from: buffer)
                }
                seconds += audio.duration
            }
        }

        let embedder = WeSpeakerEmbedder(models: data.models)
        let diarizer = NemotronDiarizer(models: data.models, embedder: embedder)
        _ = try await diarizer.diarize(track: try clip(seconds: 60))
        let loaded = currentFootprintMB()
        let clock = ContinuousClock()
        let start = clock.now
        let (result, peak) = try await peakFootprintMB { try await diarizer.diarize(track: long) }
        print("""
            [long] \(String(format: "%.0f", seconds)) s: \(clock.now - start), \(Set(result.segments.map(\.cluster)).count) clusters, \(result.embeddings.count) voiceprints
            [long] footprint \(Int(loaded)) MB with models loaded, peak \(Int(peak)) MB (+\(Int(peak - loaded)) MB), peak RSS \(Int(peakResidentMB())) MB
            """)
    }

    private func clip(seconds: Int) throws -> URL {
        let source = try TrackAudio(converting: data.track)
        defer { source.remove() }
        let url = try temporaryDirectory().appending(path: "clip.wav")
        try writeAudio([source.samples(from: 0, count: seconds * 16_000)], sampleRate: 16_000, to: url,
                       settings: wavSettings(sampleRate: 16_000, channels: 1, float: false))
        return url
    }

    private func upsample(_ samples: [Float], to rate: Double) throws -> [Float] {
        let input = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let output = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let converter = try #require(AVAudioConverter(from: input, to: output))
        let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count))!
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(samples.count) * rate / 16_000) + 4096)!
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let pending = source
        var error: NSError?
        converter.convert(to: target, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return pending
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: target.floatChannelData![0], count: Int(target.frameLength)))
    }
}

/// One placeholder word every two seconds: the pipeline needs words to align, not their text.
struct EveryTwoSecondsSTT: TranscriptionProvider {
    func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        let duration = try AVAudioFile(forReading: audio).duration
        return .unlabeled(stride(from: 0.0, to: max(0, duration - 1), by: 2).map { TimedWord("字", $0, $0 + 0.5) })
    }
}

struct SilentLLM: LLMProvider {
    func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess] { [] }
    func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript { CleanedTranscript(paragraphs: []) }
    func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest] { [] }
    func summarize(_ request: SummaryRequest) async throws -> Summary {
        Summary(decisions: [], discussionPoints: [], actionItems: [])
    }
}

extension AVAudioFile {
    var duration: TimeInterval { Double(length) / fileFormat.sampleRate }
}
