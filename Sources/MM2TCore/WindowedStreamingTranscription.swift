import Foundation

/// Tries streaming sources in the transcription order, falling through only when one is unreachable,
/// the same rule as `TranscriptionChain`. A session that later drops is reopened from the top.
public struct StreamingTranscriptionChain: StreamingTranscriptionProvider {
    public struct Route: Sendable {
        public let source: TranscriptionSource
        public let provider: any StreamingTranscriptionProvider
        public init(_ source: TranscriptionSource, _ provider: any StreamingTranscriptionProvider) {
            self.source = source
            self.provider = provider
        }
    }

    public let routes: [Route]

    public init(_ routes: [Route]) {
        self.routes = routes
    }

    public func open(_ request: StreamingTranscriptionRequest) async throws -> any StreamingTranscriptionSession {
        var lastError = TranscriptionError.unreachable("no transcription source configured")
        for route in routes {
            do {
                return try await route.provider.open(request)
            } catch let error as TranscriptionError {
                guard case .unreachable = error else { throw error }
                lastError = error
            }
        }
        throw lastError
    }
}

/// A model that transcribes one short clip per call. `WindowedStreamingTranscription` turns it
/// into a stream, so Whisper models without a streaming API still give live captions.
public protocol ClipTranscriber: Sendable {
    /// Readies the model; throws `TranscriptionError.unreachable` when the source cannot be used now.
    func prepare() async throws
    /// `samples` are mono in -1...1 at `request.sampleRate`. Throws `TranscriptionError`.
    func transcribe(clip samples: [Float], request: StreamingTranscriptionRequest) async throws -> String
}

public protocol ProgressiveClipTranscriber: ClipTranscriber {
    func transcribe(clip samples: [Float], request: StreamingTranscriptionRequest,
                    onPartial: @escaping @Sendable (String) -> Void) async throws -> String
}

extension ProgressiveClipTranscriber {
    public func transcribe(clip samples: [Float], request: StreamingTranscriptionRequest) async throws -> String {
        try await transcribe(clip: samples, request: request, onPartial: { _ in })
    }
}

/// Streams by re-decoding the segment being spoken as it grows, then settling it at a pause.
public struct WindowedStreamingTranscription: StreamingTranscriptionProvider {
    let transcriber: any ClipTranscriber

    public init(_ transcriber: any ClipTranscriber) {
        self.transcriber = transcriber
    }

    public func open(_ request: StreamingTranscriptionRequest) async throws -> any StreamingTranscriptionSession {
        try await transcriber.prepare()
        return WindowedSession(transcriber: transcriber, request: request)
    }
}

/// Decodes one clip at a time, so a slow model paces itself: partials that pile up while it works
/// collapse into the latest one, and settled segments wait their turn and are never skipped.
actor WindowedSession: StreamingTranscriptionSession {
    nonisolated let events: AsyncThrowingStream<StreamingTranscriptEvent, Error>
    private let output: AsyncThrowingStream<StreamingTranscriptEvent, Error>.Continuation
    private let wakes: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation
    private let transcriber: any ClipTranscriber
    private let request: StreamingTranscriptionRequest
    private var window: SpeechWindow
    private var settled: [[Float]] = []
    private var worker: Task<Void, Never>?
    private var isClosed = false

    init(transcriber: any ClipTranscriber, request: StreamingTranscriptionRequest) {
        (events, output) = AsyncThrowingStream.makeStream()
        (wakes, wake) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.transcriber = transcriber
        self.request = request
        window = SpeechWindow(sampleRate: request.sampleRate)
    }

    func send(_ samples: [Float]) async throws {
        guard !isClosed else { return }
        settled += window.append(samples)
        if worker == nil { worker = Task { await self.work() } }
        wake.yield()
    }

    func close() async {
        isClosed = true
        output.finish()
        worker?.cancel()
        wake.finish()
    }

    private func work() async {
        for await _ in wakes {
            while !Task.isCancelled, let (clip, isFinal) = nextClip() {
                do {
                    let text: String
                    if let progressive = transcriber as? any ProgressiveClipTranscriber {
                        text = try await progressive.transcribe(clip: clip, request: request) { [output] text in
                            output.yield(.partial(text))
                        }
                    } else {
                        text = try await transcriber.transcribe(clip: clip, request: request)
                    }
                    guard !Task.isCancelled else { return }
                    output.yield(isFinal ? .final(text) : .partial(text))
                } catch {
                    if !Task.isCancelled { output.finish(throwing: error) }
                    return
                }
            }
        }
    }

    private func nextClip() -> ([Float], Bool)? {
        if !settled.isEmpty { return (settled.removeFirst(), true) }
        return window.takePartial().map { ($0, false) }
    }
}

/// Cuts live audio into the segment being spoken. Silence before speech is dropped down to a short
/// lead-in, so Whisper is never handed silence it would invent words for. A segment settles after
/// a pause, or at the quietest moment of its last seconds once it grows too long to re-decode.
struct SpeechWindow: Sendable {
    static let frameSeconds = 0.1
    static let leadInFrames = 3
    static let pauseFrames = 7
    static let longestFrames = 150
    static let cutSearchFrames = 50
    static let partialStepSeconds = 0.5

    private let frameLength: Int
    private let partialStep: Int
    private var samples: [Float] = []
    /// RMS of each complete frame in `samples`, from its start.
    private var levels: [Float] = []
    private var floor: Float?
    private var heardSpeech = false
    private var quietFrames = 0
    private var partialMark = 0

    init(sampleRate: Int) {
        frameLength = max(1, Int(Double(sampleRate) * Self.frameSeconds))
        partialStep = Int(Double(sampleRate) * Self.partialStepSeconds)
    }

    /// Adds audio and returns the segments it settled, oldest first.
    mutating func append(_ new: [Float]) -> [[Float]] {
        samples += new
        var settled: [[Float]] = []
        while levels.count < samples.count / frameLength {
            let start = levels.count * frameLength
            let level = Self.rms(samples[start..<start + frameLength])
            levels.append(level)
            if isSpeech(level) {
                heardSpeech = true
                quietFrames = 0
            } else {
                quietFrames += 1
            }
            if !heardSpeech {
                drop(frames: levels.count - Self.leadInFrames)
            } else if quietFrames >= Self.pauseFrames {
                settled.append(cut(atFrame: levels.count))
                heardSpeech = false
                quietFrames = 0
            } else if levels.count >= Self.longestFrames {
                let search = levels.indices.suffix(Self.cutSearchFrames)
                let quietest = search.min { levels[$0] < levels[$1] } ?? levels.count
                settled.append(cut(atFrame: quietest))
                quietFrames = min(quietFrames, levels.count)
            }
        }
        return settled
    }

    /// The whole unsettled segment, once speech has started and enough new audio has arrived since the last one.
    mutating func takePartial() -> [Float]? {
        guard heardSpeech, samples.count - partialMark >= partialStep else { return nil }
        partialMark = samples.count
        return samples
    }

    private mutating func cut(atFrame frame: Int) -> [Float] {
        let clip = Array(samples.prefix(frame * frameLength))
        drop(frames: frame)
        partialMark = 0
        return clip
    }

    private mutating func drop(frames: Int) {
        guard frames > 0 else { return }
        samples.removeFirst(frames * frameLength)
        levels.removeFirst(frames)
        partialMark = max(0, partialMark - frames * frameLength)
    }

    /// Speech is louder than three times the quietest recent frame, within fixed bounds. The floor
    /// follows a quieter room at once and a louder one slowly.
    private mutating func isSpeech(_ level: Float) -> Bool {
        let floor = min(level, (self.floor ?? level) * 1.02)
        self.floor = floor
        return level > min(0.02, max(0.004, floor * 3))
    }

    private static func rms(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        let sum = frame.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(frame.count)).squareRoot()
    }
}
