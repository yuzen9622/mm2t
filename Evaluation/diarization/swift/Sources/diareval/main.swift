import AVFoundation
import FluidAudio
import Foundation

struct DiarizationRecord: Codable {
    let wav: String
    let audioSeconds: Double
    let wallSeconds: Double
    let realTimeFactor: Double
    let speakerCount: Int
    let timings: PipelineTimings?
    let speakerDatabase: [String: [Float]]
}

struct SpanRequest: Codable {
    let wav: String
    let spans: [[Double]]
}

struct SpanResult: Codable {
    let wav: String
    let spans: [[Double]]
    let embeddings: [[Float]]
}

enum Usage: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

let usage = """
    diareval diarize --models DIR --out DIR [--engine offline|sortformer|lseend-ami|nemotron3-offline|nemotron3-fast32] [--step-ratio R] [--threshold T] WAV...
    diareval embed --models DIR --spans SPANS.json --out OUT.json
    WAVs must be 16 kHz mono; anything else is rejected rather than silently resampled.
    """

func option(_ name: String, in args: inout [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...index + 1)
    return value
}

func loadMono16k(_ path: String) throws -> [Float] {
    let url = URL(fileURLWithPath: path)
    let format = try AVAudioFile(forReading: url).fileFormat
    guard format.sampleRate == 16_000, format.channelCount == 1 else {
        throw Usage.message("\(path): expected 16 kHz mono, got \(format.sampleRate) Hz x \(format.channelCount)")
    }
    return try AudioConverter().resampleAudioFile(url)
}

struct Turn {
    let speaker: String
    let start: Double
    let end: Double
}

struct EngineOutput {
    let turns: [Turn]
    let timings: PipelineTimings?
    let speakerDatabase: [String: [Float]]
}

/// One diarization back end, prepared once and then run per file.
enum Engine {
    case offline(OfflineDiarizerManager)
    case sortformer(SortformerDiarizer)
    case lseend(LSEENDDiarizer)
    case nemotron3(Nemotron3Diarizer)

    static func make(_ name: String, models: URL, stepRatio: Double?, threshold: Double?) async throws -> Engine {
        switch name {
        case "offline":
            var config = OfflineDiarizerConfig.default
            if let stepRatio { config.segmentation.stepRatio = stepRatio }
            if let threshold { config.clustering.threshold = threshold }
            let manager = OfflineDiarizerManager(config: config)
            try await manager.prepareModels(directory: models)
            return .offline(manager)
        case "sortformer":
            let diarizer = SortformerDiarizer(config: .highContextV2)
            diarizer.initialize(
                models: try await SortformerModels.loadFromHuggingFace(
                    config: .highContextV2, cacheDirectory: models))
            return .sortformer(diarizer)
        case "lseend-ami":
            let model = try await LSEENDModel.loadFromHuggingFace(variant: .ami, cacheDirectory: models)
            return .lseend(try LSEENDDiarizer(model: model))
        case "nemotron3-offline", "nemotron3-fast32":
            let config: Nemotron3Config = name == "nemotron3-offline" ? .offline : .fast32
            let models = try await Nemotron3Models.loadFromHuggingFace(config: config, cacheDirectory: models)
            return .nemotron3(Nemotron3Diarizer(config: config, models: models))
        default:
            throw Usage.message("unknown engine \(name)")
        }
    }

    func run(_ samples: [Float]) async throws -> EngineOutput {
        switch self {
        case .offline(let manager):
            let result = try await manager.process(audio: samples)
            return EngineOutput(
                turns: result.segments.map {
                    Turn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
                },
                timings: result.timings,
                speakerDatabase: result.speakerDatabase ?? [:])
        case .sortformer(let diarizer):
            diarizer.reset()
            return EngineOutput(
                turns: Engine.turns(try diarizer.processComplete(samples, sourceSampleRate: 16_000)),
                timings: nil, speakerDatabase: [:])
        case .lseend(let diarizer):
            diarizer.reset()
            return EngineOutput(
                turns: Engine.turns(try diarizer.processComplete(samples, sourceSampleRate: 16_000)),
                timings: nil, speakerDatabase: [:])
        case .nemotron3(let diarizer):
            let (probabilities, frames) = try diarizer.processComplete(samples)
            return EngineOutput(
                turns: Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frames).map {
                    Turn(speaker: "S\($0.speakerIndex + 1)", start: Double($0.startSeconds), end: Double($0.endSeconds))
                },
                timings: nil, speakerDatabase: [:])
        }
    }

    static func turns(_ timeline: DiarizerTimeline) -> [Turn] {
        timeline.speakers.flatMap { index, speaker in
            speaker.finalizedSegments.map {
                Turn(speaker: "S\(index + 1)", start: Double($0.startTime), end: Double($0.endTime))
            }
        }
    }
}

func rttm(_ turns: [Turn], fileId: String) -> String {
    turns
        .sorted { $0.start < $1.start }
        .map {
            String(format: "SPEAKER %@ 1 %.3f %.3f <NA> <NA> %@ <NA> <NA>",
                   fileId, $0.start, $0.end - $0.start, $0.speaker)
        }
        .joined(separator: "\n") + "\n"
}

func diarize(_ arguments: [String]) async throws {
    var args = arguments
    guard let out = option("--out", in: &args), let models = option("--models", in: &args) else {
        throw Usage.message(usage)
    }
    let engineName = option("--engine", in: &args) ?? "offline"
    let engine = try await Engine.make(
        engineName,
        models: URL(fileURLWithPath: models),
        stepRatio: option("--step-ratio", in: &args).flatMap(Double.init),
        threshold: option("--threshold", in: &args).flatMap(Double.init))
    let wavs = args
    guard !wavs.isEmpty else { throw Usage.message(usage) }
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

    // The first Core ML call pays ANE specialization; keep it out of every file's timing.
    let warmup = try loadMono16k(wavs[0])
    _ = try await engine.run(Array(warmup.prefix(16_000 * 60)))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for wav in wavs {
        let samples = try loadMono16k(wav)
        let audioSeconds = Double(samples.count) / 16_000
        let clock = ContinuousClock()
        var output: EngineOutput?
        let elapsed = try await clock.measure {
            output = try await engine.run(samples)
        }
        guard let output else { continue }
        let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let fileId = URL(fileURLWithPath: wav).deletingPathExtension().lastPathComponent
        let speakers = Set(output.turns.map(\.speaker))
        let record = DiarizationRecord(
            wav: wav,
            audioSeconds: audioSeconds,
            wallSeconds: wall,
            realTimeFactor: wall / audioSeconds,
            speakerCount: speakers.count,
            timings: output.timings,
            speakerDatabase: output.speakerDatabase
        )
        try rttm(output.turns, fileId: fileId)
            .write(toFile: "\(out)/\(fileId).rttm", atomically: true, encoding: .utf8)
        try encoder.encode(record).write(to: URL(fileURLWithPath: "\(out)/\(fileId).json"))
        print(String(format: "%@  %.0fs audio  %.2fs wall  RTF %.4f  %d speakers",
                     fileId, audioSeconds, wall, wall / audioSeconds, speakers.count))
    }
}

func embed(_ arguments: [String]) async throws {
    var args = arguments
    guard let spansPath = option("--spans", in: &args), let out = option("--out", in: &args),
        let models = option("--models", in: &args)
    else {
        throw Usage.message(usage)
    }
    let requests = try JSONDecoder().decode(
        [SpanRequest].self, from: Data(contentsOf: URL(fileURLWithPath: spansPath)))
    let manager = OfflineDiarizerManager(config: .default)
    try await manager.prepareModels(directory: URL(fileURLWithPath: models))
    var results: [SpanResult] = []
    for request in requests {
        let samples = try loadMono16k(request.wav)
        let ranges = request.spans.map { $0[0]..<$0[1] }
        let embeddings = try await manager.embedSpans(
            audioSource: ArrayAudioSampleSource(samples: samples), spans: ranges)
        results.append(SpanResult(wav: request.wav, spans: request.spans, embeddings: embeddings))
        print("\(request.wav): \(embeddings.count) span embeddings")
    }
    try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: out))
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "diarize": try await diarize(Array(args.dropFirst()))
    case "embed": try await embed(Array(args.dropFirst()))
    default: throw Usage.message(usage)
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
