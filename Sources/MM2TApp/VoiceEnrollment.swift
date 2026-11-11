import AVFoundation
import Foundation
import MM2TCore
import MM2TSystem
import Observation

/// Records the microphone alone to a mono 16-bit WAV, for the passage the user reads at setup.
/// The meeting recorder is not used here: it also taps system audio, which would ask for a second
/// permission before the user has seen what the app does.
public protocol VoiceSampleRecording: AnyObject, Sendable {
    func start(to url: URL) throws
    /// 0 to 1, for the level meter.
    var level: Double { get }
    func stop()
}

public final class MicrophoneSampleRecorder: VoiceSampleRecording, @unchecked Sendable {
    private var recorder: AVAudioRecorder?

    public init() {}

    public func start(to url: URL) throws {
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw VoiceEnrollmentError.recorder("The microphone could not start.") }
        self.recorder = recorder
    }

    public var level: Double {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        // -50 dB and below reads as empty, 0 dB as full.
        return min(1, max(0, (Double(recorder.averagePower(forChannel: 0)) + 50) / 50))
    }

    public func stop() {
        recorder?.stop()
        recorder = nil
    }
}

public enum VoiceEnrollmentError: Error, Equatable {
    case recorder(String)
}

/// The user reading a passage aloud once, which becomes their voiceprint.
@MainActor @Observable
public final class VoiceEnrollmentModel {
    public enum Problem: Equatable, Sendable {
        /// Less speech than the passage takes to read.
        case tooShort
        /// Speech recognition heard something else.
        case differentWords
        /// The on-device speaker model is not downloaded yet.
        case modelMissing
        case microphoneDenied
        case failed(String)
    }

    public enum State: Equatable, Sendable {
        case idle
        case recording
        case checking
        case rejected(Problem)
        case enrolled
    }

    /// Seconds of speech the passage must produce; reading it takes about twice this.
    public static let minimumSpeech: TimeInterval = 5

    public private(set) var state: State = .idle
    public private(set) var level = 0.0
    /// Whether the user has a voiceprint, from this run or an earlier one.
    public private(set) var hasVoice = false

    @ObservationIgnored private let voiceprints: VoiceprintStore
    @ObservationIgnored private let recorder: any VoiceSampleRecording
    @ObservationIgnored private let permissions: any PermissionsProviding
    @ObservationIgnored private let scratch: URL
    @ObservationIgnored private let transcribe: @MainActor (URL) async -> String?
    @ObservationIgnored private let embed: @MainActor (URL, TimeInterval) async throws -> [Embedding]?
    @ObservationIgnored private var meter: Task<Void, Never>?

    /// `transcribe` returns what speech recognition heard, or nil when no service is set up or it
    /// could not answer; the words are then not checked. `embed` returns nil when the speaker
    /// model is not on disk.
    public init(
        voiceprints: VoiceprintStore, recorder: any VoiceSampleRecording, permissions: any PermissionsProviding,
        scratch: URL,
        transcribe: @escaping @MainActor (URL) async -> String?,
        embed: @escaping @MainActor (URL, TimeInterval) async throws -> [Embedding]?
    ) {
        self.voiceprints = voiceprints
        self.recorder = recorder
        self.permissions = permissions
        self.scratch = scratch
        self.transcribe = transcribe
        self.embed = embed
    }

    public func refresh() async {
        hasVoice = await voiceprints.user() != nil
        if hasVoice, state == .idle { state = .enrolled }
    }

    public func start() async {
        switch state {
        case .recording, .checking: return
        default: break
        }
        if permissions.microphone != .granted, !(await permissions.requestMicrophone()) {
            state = .rejected(.microphoneDenied)
            return
        }
        do {
            try FileManager.default.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: scratch)
            try recorder.start(to: scratch)
        } catch {
            state = .rejected(.failed(String(describing: error)))
            return
        }
        state = .recording
        meter = Task { [weak self] in
            while !Task.isCancelled, let self {
                self.level = self.recorder.level
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    /// Stops recording and checks the reading against `passage`; `name` labels the user's entry among people.
    public func finish(passage: String, name: String) async {
        guard state == .recording else { return }
        meter?.cancel()
        meter = nil
        level = 0
        recorder.stop()
        state = .checking
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let audio = try Self.samples(of: scratch)
            guard ReadAloud.speechSeconds(audio.samples, sampleRate: audio.sampleRate) >= Self.minimumSpeech else {
                state = .rejected(.tooShort)
                return
            }
            if let heard = await transcribe(scratch),
               ReadAloud.coverage(of: passage, in: heard) < ReadAloud.requiredCoverage {
                state = .rejected(.differentWords)
                return
            }
            guard let embeddings = try await embed(scratch, audio.duration) else {
                state = .rejected(.modelMissing)
                return
            }
            guard !embeddings.isEmpty else {
                state = .rejected(.tooShort)
                return
            }
            try await voiceprints.enrollUser(name: name, embeddings: embeddings)
            hasVoice = true
            state = .enrolled
        } catch {
            state = .rejected(.failed(String(describing: error)))
        }
    }

    /// Read through AVFoundation, since the system's recorder pads its WAV header in ways a plain parser need not know.
    private static func samples(of url: URL) throws -> WAVAudio {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw VoiceEnrollmentError.recorder("The recording could not be read.")
        }
        try file.read(into: buffer)
        let count = Int(buffer.frameLength) * Int(file.processingFormat.channelCount)
        let samples = buffer.int16ChannelData.map { Array(UnsafeBufferPointer(start: $0[0], count: count)) } ?? []
        return WAVAudio(sampleRate: Int(file.processingFormat.sampleRate), samples: samples)
    }

    /// Lets the user read again, keeping any voiceprint they already have until the new one passes.
    public func retry() {
        if case .rejected = state { state = hasVoice ? .enrolled : .idle } else if state == .enrolled { state = .idle }
    }
}
