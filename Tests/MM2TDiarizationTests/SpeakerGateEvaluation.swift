import Accelerate
import AVFoundation
import FluidAudio
import Foundation
@testable import MM2TCore
@testable import MM2TDiarization
import Testing

/// Opt-in AliMeeting calibration; use the production diarizer and gate, not a second implementation.
struct SpeakerGateEvaluation {
    struct Case: Decodable {
        var id: String
        var mode: String
        var path: String
    }

    struct Turn: Codable {
        var speaker: String
        var start: Double
        var end: Double
    }

    struct Partition: Codable {
        var foreground: [Turn]
        var background: [Turn]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_GATE_EVAL"] != nil))
    func aliMeeting() async throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: try #require(env["MM2T_GATE_EVAL"]), isDirectory: true)
        let scratch = URL(fileURLWithPath: try #require(env["TMPDIR"]), isDirectory: true)
        let models = DiarizationModels(directory: URL(fileURLWithPath: try #require(env["MM2T_GATE_MODELS"])))
        try #require(models.isDownloaded)
        let model = Nemotron3Diarizer(config: .offline, models: try await models.loadNemotron())
        let embedder = VoiceprintEmbedder(models: models)
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: out.appending(path: "cases.json")))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let output = out.appending(path: "turns", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let selection = env["MM2T_GATE_SELECTION"]
        let verifyProductGain = env["MM2T_GATE_PRODUCT_GAIN"] == "1"
        for item in cases where selection.map(item.mode.hasPrefix) ?? true {
            try Task.checkCancellation()
            let result = output.appending(path: "\(item.id).json")
            let url = URL(fileURLWithPath: item.path)
            if FileManager.default.fileExists(atPath: result.path) {
                if verifyProductGain, item.mode == "callGlobal" || item.mode == "callPerson" {
                    var rows = try JSONDecoder().decode([String: Partition].self, from: Data(contentsOf: result))
                    let product = try productGain(url, scratch: scratch, model: model, baseline: try #require(rows["baseline"]))
                    rows["product"] = product
                    try encoder.encode(rows).write(to: result, options: .atomic)
                    print("\(item.id) product gain \(product.foreground.count) turns")
                }
                continue
            }
            let mode: SpeakerGate.Mode = item.mode == "callMic" ? .callMic : item.mode.hasPrefix("room") ? .room : .call
            let energy = mode == .call ? nil : try SpeechEnergy(reading: url)
            let heard = try await detect(url, scratch: scratch, model: model, embedder: embedder, mode: mode, energy: energy)
            let evidence = SpeakerGate.Evidence(for: heard, energy: energy)
            var rows: [String: Partition] = ["baseline": baseline(heard)]
            switch item.mode {
            case "callMic":
                for drop in [6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 28, 32] {
                    for minimum in [0.5, 1, 2] {
                        rows["drop\(drop)min\(minimum)"] = partition(heard, evidence: evidence, gate: SpeakerGate(callMicDrop: Double(drop), minForegroundSpeech: minimum), mode: .callMic)
                    }
                }
                rows["production"] = partition(heard, evidence: evidence, gate: SpeakerGate(), mode: .callMic)
            case "room", "roomTV":
                for drop in [10, 12, 15, 20, 25, 30] {
                    for min in [0.5, 1, 2, 3, 5, 8] {
                        rows["drop\(drop)min\(min)"] = partition(heard, evidence: evidence, gate: SpeakerGate(roomDrop: Double(drop), minForegroundSpeech: min), mode: .room)
                    }
                }
                rows["production"] = partition(heard, evidence: evidence, gate: SpeakerGate(), mode: .room)
            default:
                for (name, adaptive) in [("adaptive", true), ("fixed", false)] {
                    let normalized = out.appending(path: "\(item.id)-norm.wav")
                    try normalize(url, to: normalized, adaptive: adaptive)
                    defer { try? FileManager.default.removeItem(at: normalized) }
                    let normalizedHeard = try await detect(normalized, scratch: scratch, model: model, embedder: embedder, mode: .call)
                    rows[name] = baseline(normalizedHeard)
                }
                rows["product"] = try productGain(url, scratch: scratch, model: model, baseline: baseline(heard))
            }
            try encoder.encode(rows).write(to: result, options: .atomic)
            print("\(item.id) \(heard.segments.count) turns")
        }
    }

    private struct PhaseTwoCase: Decodable {
        let id: String
        let mode: String
        let path: String
        let enrollmentPath: String?
        let enrollmentTurns: [Turn]?
    }

    struct MicEvidenceCapture: Codable {
        struct Level: Codable {
            let db: Double?
            let seconds: Double
        }
        let turns: [Turn]
        let kept: [String: [Embedding]]
        let brief: [String: [Embedding]]
        let enrollment: [Embedding]
        let levels: [String: Level]
        let before: [String: Partition]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_PHASE2_EVAL"] != nil))
    func dualThresholdSweep() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["MM2T_PHASE2_EVAL"]), isDirectory: true)
        let scratch = URL(fileURLWithPath: try #require(env["TMPDIR"]), isDirectory: true)
        let models = DiarizationModels(directory: URL(fileURLWithPath: try #require(env["MM2T_GATE_MODELS"])))
        try #require(models.isDownloaded)
        let model = Nemotron3Diarizer(config: .offline, models: try await models.loadNemotron())
        let embedder = VoiceprintEmbedder(models: models)
        let cases = try JSONDecoder().decode([PhaseTwoCase].self, from: Data(contentsOf: root.appending(path: "cases.json")))
        let output = root.appending(path: "turns", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var enrolled: [String: [Embedding]] = [:]
        let encoder = JSONEncoder()
        let capturesEvidence = env["MM2T_PHASE3_CAPTURE"] == "1"
        let captureOutput = root.appending(path: "evidence", directoryHint: .isDirectory)
        if capturesEvidence { try FileManager.default.createDirectory(at: captureOutput, withIntermediateDirectories: true) }
        let ordered = capturesEvidence ? cases.filter { $0.id.contains("__mic_None_") }
            + cases.filter { !$0.id.contains("__mic_None_") } : cases
        for item in ordered where env["MM2T_PHASE2_SELECT"].map(item.mode.hasPrefix) ?? true {
            try Task.checkCancellation()
            let result = output.appending(path: "\(item.id).json")
            let capture = captureOutput.appending(path: "\(item.id).json")
            if FileManager.default.fileExists(atPath: result.path),
               !capturesEvidence || item.mode != "callMic" || FileManager.default.fileExists(atPath: capture.path) { continue }
            let url = URL(fileURLWithPath: item.path)
            let energy = try SpeechEnergy(reading: url)
            let mode: SpeakerGate.Mode = item.mode == "callMic" ? .callMic : .room
            let heard = try await detect(url, scratch: scratch, model: model, embedder: embedder, mode: mode,
                                         energy: energy, embeddingMic: mode == .callMic)
            let gate = SpeakerGate()
            let evidence = SpeakerGate.Evidence(for: heard, energy: energy, measuringMicGroups: mode == .callMic)
            var rows = ["raw": baseline(heard)]
            if mode == .room {
                rows["current"] = partition(heard, evidence: evidence, gate: gate, mode: .room)
            } else {
                let file = try #require(item.enrollmentPath)
                if enrolled[file] == nil {
                    let audio = try TrackAudio(converting: URL(fileURLWithPath: file), temporaryDirectory: scratch)
                    defer { audio.remove() }
                    let turns = try #require(item.enrollmentTurns).map {
                        Diarization.Segment(cluster: ClusterID($0.speaker), range: TimeRange(start: $0.start, end: $0.end))
                    }
                    let vectors = try await embedder.voiceprints(audio: audio, segments: turns, includingBrief: true)
                    let enrollment = vectors.kept.values.flatMap { $0 }
                    try #require(!enrollment.isEmpty)
                    enrolled[file] = enrollment
                }
                rows["current"] = partition(heard, evidence: evidence, gate: SpeakerGate(callMicDrop: 18), mode: .callMic)
                for create in [6, 8, 10, 12, 14] {
                    for keep in [14, 18, 22, 0] {
                        let thresholds = SpeakerGate.CallMicThresholds(createDrop: Double(create), keepDrop: keep == 0 ? .infinity : Double(keep))
                        for (name, vectors) in [("fallback", []), ("enrolled", try #require(enrolled[file]))] {
                            let decisions = gate.callMicDestinations(for: evidence, thresholds: thresholds,
                                                                     userEmbeddings: vectors, matchThresholds: .campPlus, allowUnanchoredDual: true)
                            rows["\(name)-\(create)-\(keep)"] = partition(heard, decisions: decisions)
                        }
                    }
                }
            }
            if capturesEvidence, mode == .callMic {
                let levels = Dictionary(grouping: heard.segments, by: \.cluster).compactMapValues { group in
                    energy.voicedMedian(in: group.map(\.range)).map {
                        MicEvidenceCapture.Level(db: $0.db.isFinite ? $0.db : nil, seconds: $0.seconds)
                    }
                }
                let enrollmentFile = try #require(item.enrollmentPath)
                let data = MicEvidenceCapture(turns: baseline(heard).foreground,
                    kept: Dictionary(uniqueKeysWithValues: heard.embeddings.map { ($0.key.rawValue, $0.value) }),
                    brief: Dictionary(uniqueKeysWithValues: heard.briefEmbeddings.map { ($0.key.rawValue, $0.value) }),
                    enrollment: try #require(enrolled[enrollmentFile]),
                    levels: Dictionary(uniqueKeysWithValues: levels.map { ($0.key.rawValue, $0.value) }),
                    before: rows)
                try encoder.encode(data).write(to: capture, options: .atomic)
            }
            try encoder.encode(rows).write(to: result, options: .atomic)
            print("phase2 \(item.id) \(heard.segments.count) turns")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_PHASE4_RESCORE"] != nil))
    func correctedMicRoutesFromCache() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MM2T_PHASE4_RESCORE"]))
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MM2T_PHASE4_RESCORE_OUT"]))
        let cases = try JSONDecoder().decode([PhaseTwoCase].self, from: Data(contentsOf: root.appending(path: "cases.json")))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var count = 0
        for item in cases where item.mode == "callMic" {
            let capture = root.appending(path: "evidence/\(item.id).json")
            let cached = try JSONDecoder().decode(MicEvidenceCapture.self, from: Data(contentsOf: capture))
            let heard = Diarization(segments: cached.turns.map {
                .init(cluster: ClusterID($0.speaker), range: .init(start: $0.start, end: $0.end))
            }, overlaps: [], embeddings: Dictionary(uniqueKeysWithValues: cached.kept.map { (ClusterID($0.key), $0.value) }),
               briefEmbeddings: Dictionary(uniqueKeysWithValues: cached.brief.map { (ClusterID($0.key), $0.value) }))
            let energy = try SpeechEnergy(reading: URL(fileURLWithPath: item.path))
            let evidence = SpeakerGate.Evidence(for: heard, energy: energy, measuringMicGroups: true)
            let gate = SpeakerGate()
            let result = partition(heard, decisions: gate.callMicDestinations(for: evidence, thresholds: SpeakerGate.enrolledCallMic,
                                                  userEmbeddings: cached.enrollment, matchThresholds: .campPlus))
            try JSONEncoder().encode(result).write(to: out.appending(path: "\(item.id).json"), options: .atomic)
            count += 1
        }
        #expect(count == 96)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_GATE_VERIFY_STREAMING"] == "1"))
    func quietFinalSnapshotMatchesOfflineCall() async throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: try #require(env["MM2T_GATE_EVAL"]), isDirectory: true)
        let scratch = URL(fileURLWithPath: try #require(env["TMPDIR"]), isDirectory: true)
        let modelDirectory = URL(fileURLWithPath: try #require(env["MM2T_GATE_MODELS"]))
        let input = out.appending(path: "wav/R8001_M8004__call_global.wav")
        let clip = scratch.appending(path: "quiet-snapshot-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: clip) }
        let source = try TrackAudio(converting: input, temporaryDirectory: scratch)
        defer { source.remove() }
        let samples = source.samples(from: 0, count: 120 * 16_000)
        try writeAudio([samples], sampleRate: 16_000, to: clip,
                       settings: wavSettings(sampleRate: 16_000, channels: 1, float: true))
        let metrics = try SpanAudioSource(url: clip)
        #expect(try RemoteDiarizationGain.measure(in: metrics) > 1)
        let models = DiarizationModels(directory: modelDirectory)
        let factory = NemotronDiarizer(models: models, embedder: VoiceprintEmbedder(models: models))
        let live = try await factory.makeStreamingSession()
        for start in stride(from: 0, to: samples.count, by: 160_000) {
            try await live.append(samples: Array(samples[start..<min(start + 160_000, samples.count)]), track: .remote)
        }
        _ = try await live.snapshot(tracks: [.remote: clip], final: false)
        let final = try await live.snapshot(tracks: [.remote: clip], final: true)
        let actual = try #require(final.diarizations[.remote])
        let offline = try await factory.diarize(track: clip, on: .call)
        #expect(!actual.segments.isEmpty)
        #expect(frameAgreement(actual.segments, offline.segments, to: Double(samples.count) / 16_000) > 0.9999)
        #expect(actual.overlaps == offline.overlaps)
    }

    private func productGain(_ url: URL, scratch: URL, model: Nemotron3Diarizer,
                             baseline original: Partition) throws -> Partition {
        let audio = try TrackAudio(converting: url, temporaryDirectory: scratch)
        defer { audio.remove() }
        let gain = try RemoteDiarizationGain.measure(in: audio)
        guard gain > 1 else { return original }
        let raw = try NemotronDiarizer.turns(of: audio, with: model, gain: gain)
        let turns = SpeakerTurns.bridgingGaps(raw, shorterThan: NemotronDiarizer.gapBridging)
        return Partition(foreground: turns.map { turn($0.cluster, $0.range) }, background: [])
    }

    private func detect(_ url: URL, scratch: URL, model: Nemotron3Diarizer, embedder: VoiceprintEmbedder,
                        mode: SpeakerGate.Mode, energy: SpeechEnergy? = nil, embeddingMic: Bool = false) async throws -> Diarization {
        let audio = try TrackAudio(converting: url, temporaryDirectory: scratch)
        defer { audio.remove() }
        let turns = try NemotronDiarizer.turns(of: audio, with: model)
        let segments = SpeakerTurns.bridgingGaps(turns, shorterThan: NemotronDiarizer.gapBridging)
        let overlaps = SpeakerTurns.overlaps(segments)
        let empty = Diarization(segments: segments, overlaps: overlaps, embeddings: [:])
        // Call mic never merges by cosine. For the other modes CAM++ cannot change a result
        // unless both a foreground target and a possible fragment with a clean >=1 s span exist.
        if embeddingMic {
            let voice = try await embedder.voiceprints(audio: audio, segments: turns, includingBrief: true)
            return Diarization(segments: segments, overlaps: overlaps, embeddings: voice.kept, briefEmbeddings: voice.brief)
        }
        guard mode == .room else { return empty }
        let decisions = SpeakerGate(roomDrop: .infinity, minForegroundSpeech: 8)
            .destinations(for: empty, mode: mode, energy: energy)
        let rejected = Set(decisions.compactMap { if case .background(let cluster) = $0 { cluster } else { nil } })
        if rejected.isEmpty { return empty }
        let pieces = SpeakerTurns.cleanPieces(turns, within: Double(audio.sampleCount) / 16_000,
                                             minPiece: VoiceprintEmbedder.briefMinimumPiece)
        if !rejected.contains(where: { !(pieces[$0] ?? []).isEmpty }) { return empty }
        let voice = try await embedder.voiceprints(audio: audio, segments: turns, includingBrief: true)
        return Diarization(segments: segments, overlaps: overlaps, embeddings: voice.kept, briefEmbeddings: voice.brief)
    }

    private func baseline(_ heard: Diarization) -> Partition {
        Partition(foreground: heard.segments.map { turn($0.cluster, $0.range) }, background: [])
    }

    private func turn(_ label: ClusterID, _ range: TimeRange) -> Turn {
        Turn(speaker: label.rawValue, start: range.start, end: range.end)
    }

    private func partition(_ heard: Diarization, evidence: SpeakerGate.Evidence, gate: SpeakerGate, mode: SpeakerGate.Mode) -> Partition {
        partition(heard, decisions: gate.destinations(for: evidence, mode: mode))
    }

    private func partition(_ heard: Diarization, decisions: [SpeakerGate.Destination]) -> Partition {
        var result = Partition(foreground: [], background: [])
        for (segment, destination) in zip(heard.segments, decisions) {
            switch destination {
            case .foreground(let label): result.foreground.append(turn(label, segment.range))
            case .background(let label): result.background.append(turn(label, segment.range))
            }
        }
        return result
    }

    /// Experimental bounded, slowly varying speech-level gain. Not a product preprocessing path.
    private func normalize(_ input: URL, to output: URL, adaptive: Bool) throws {
        let audio = try AVAudioFile(forReading: input)
        let format = audio.processingFormat
        try #require(format.sampleRate == 16_000 && format.channelCount == 1)
        let writer = try AVAudioFile(forWriting: output, settings: format.settings)
        let frameCount = 320
        let block = frameCount * 50
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)))
        var currentGain: Float = 1
        if !adaptive {
            var voiced: [Float] = [], peak: Float = 0
            while audio.framePosition < audio.length {
                try audio.read(into: buffer)
                guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { break }
                for first in stride(from: 0, to: Int(buffer.frameLength), by: 320) {
                    let end = min(first + 320, Int(buffer.frameLength))
                    var power: Float = 0
                    var high: Float = 0
                    vDSP_maxmgv(samples.advanced(by: first), 1, &high, vDSP_Length(end - first))
                    peak = max(peak, high)
                    vDSP_svesq(samples.advanced(by: first), 1, &power, vDSP_Length(end - first))
                    let level = sqrt(power / Float(end - first))
                    if level >= 0.0005 { voiced.append(level) }
                }
            }
            if !voiced.isEmpty {
                voiced.sort()
                currentGain = min(16, max(1, 0.10 / voiced[9 * (voiced.count - 1) / 10]), max(1, 0.999 / peak))
            }
            audio.framePosition = 0
        }
        while audio.framePosition < audio.length {
            try audio.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard let samples = buffer.floatChannelData?[0], count > 0 else { break }
            if !adaptive {
                for i in 0..<count { samples[i] *= currentGain }
                try writer.write(from: buffer)
                continue
            }
            let rms = stride(from: 0, to: count, by: frameCount).map { first in
                let end = min(first + frameCount, count)
                var power: Float = 0
                vDSP_svesq(samples.advanced(by: first), 1, &power, vDSP_Length(end - first))
                return sqrt(power / Float(end - first))
            }.sorted()
            let level = rms[9 * (rms.count - 1) / 10]
            let target = level >= 0.0005 ? min(16, max(1, 0.10 / level)) : currentGain
            for i in 0..<count {
                currentGain += (target - currentGain) * 0.00025
                samples[i] = max(-0.999, min(0.999, samples[i] * currentGain))
            }
            try writer.write(from: buffer)
        }
    }
}
