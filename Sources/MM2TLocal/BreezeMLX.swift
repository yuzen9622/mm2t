import AVFoundation
import Darwin
import FluidAudio
import Foundation
import MM2TCore

/// Both the live-edge recorder and file import use the same resident MLX model.
public protocol TrackTranscriber: TranscriptionProvider {
    func transcribeTracks(_ tracks: [[Float]], hints: [String]) async throws -> [[TimedWord]]
}

extension LocalTranscription: TrackTranscriber {}

public struct BreezeMLX: TrackTranscriber, ClipTranscriber {
    private let engine: BreezeWorker
    private let language: TranscriptionLanguage

    public init(folder: URL) {
        self.engine = BreezeWorker(folder: folder)
        self.language = .auto
    }

    private init(engine: BreezeWorker, language: TranscriptionLanguage) {
        self.engine = engine
        self.language = language
    }

    public func speaking(_ language: TranscriptionLanguage) -> Self { Self(engine: engine, language: language) }
    public func prepare() async throws { try await engine.prepare() }

    public func transcribeTracks(_ tracks: [[Float]], hints: [String]) async throws -> [[TimedWord]] {
        var result: [[TimedWord]] = []
        for track in tracks {
            try Task.checkCancellation()
            result.append(try await engine.words(track, language: language.code, hints: hints))
        }
        return result
    }

    public func transcribe(clip: [Float], request: StreamingTranscriptionRequest) async throws -> String {
        let samples = LocalTranscription.resampled(clip, from: request.sampleRate, to: 16_000)
        return Alignment.joined(try await engine.words(samples, language: request.languageCode, hints: request.hints))
    }

    public func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        try await transcribeAudioWindows(audio) { samples in
            try await engine.words(samples, language: language.code, hints: hints)
        }
    }
}

private actor BreezeWorker {
    private nonisolated let ioQueue = DispatchSerialQueue(label: "dev.mm2t.breeze.ipc")
    nonisolated var unownedExecutor: UnownedSerialExecutor { ioQueue.asUnownedSerialExecutor() }

    struct Header: Encodable { let frames: Int; let language: String?; let prompt: String? }
    struct Word: Decodable { let text: String; let start, end: Double }
    struct Response: Decodable { let ready: Bool?; let words: [Word]? }
    private let folder: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    init(folder: URL) { self.folder = folder }
    deinit { if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) } }

    nonisolated func prepare() async throws {
        try await cancellableInference { try await self.prepareProcess() }
    }

    nonisolated func words(_ samples: [Float], language: String?, hints: [String]) async throws -> [TimedWord] {
        try await cancellableInference { try await self.transcribe(samples, language: language, hints: hints) }
    }

    private func prepareProcess() throws {
        try Task.checkCancellation()
        if process?.isRunning == true { return }
        let task = Process()
        let stdin = Pipe(), stdout = Pipe()
        task.executableURL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/BreezeMLX.app/Contents/MacOS/BreezeMLX")
        task.arguments = [folder.path]
        task.standardInput = stdin
        task.standardOutput = stdout
        try task.run()
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process = task
        do {
            for handle in [stdin.fileHandleForWriting, stdout.fileHandleForReading] {
                let fd = handle.fileDescriptor
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
            }
            guard try response(until: .now + .seconds(120)).ready == true else { throw TranscriptionError.failed("MLX model could not be loaded.") }
        } catch { close(); throw error }
    }

    private func transcribe(_ samples: [Float], language: String?, hints: [String]) throws -> [TimedWord] {
        if samples.isEmpty { return [] }
        try prepareProcess()
        do {
            var request = try JSONEncoder().encode(Header(frames: samples.count, language: language, prompt: hints.isEmpty ? nil : hints.joined(separator: "、")))
            request.append(10)
            guard let input else { throw POSIXError(.EPIPE) }
            // One deadline covers the header, PCM and answer, including a helper that stops reading.
            let deadline = ContinuousClock.now + .seconds(120)
            try request.withUnsafeBytes { try write($0, to: input.fileDescriptor, until: deadline) }
            try samples.withUnsafeBytes { try write($0, to: input.fileDescriptor, until: deadline) }
            guard let words = try response(until: deadline).words else { throw TranscriptionError.failed("MLX transcription failed.") }
            return words.map { TimedWord(text: $0.text, range: .init(start: $0.start, end: $0.end)) }
        } catch { close(); throw error }
    }

    private func wait(_ fd: Int32, for events: Int16, until deadline: ContinuousClock.Instant) throws {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let result = poll(&descriptor, 1, 100)
            if result > 0 { return } // read/write reports EOF or the underlying pipe error.
            if result < 0 && errno != EINTR { throw POSIXError(.EIO) }
        }
        throw TranscriptionError.failed("The Breeze MLX helper timed out.")
    }

    private func write(_ bytes: UnsafeRawBufferPointer, to fd: Int32, until deadline: ContinuousClock.Instant) throws {
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            try wait(fd, for: Int16(POLLOUT), until: deadline)
            let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
            if count > 0 { offset += count }
            else if count == 0 || (errno != EAGAIN && errno != EINTR) { throw POSIXError(.EPIPE) }
        }
    }

    private func response(until deadline: ContinuousClock.Instant) throws -> Response {
        guard let fd = output?.fileDescriptor else { throw POSIXError(.EPIPE) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.last != 10 {
            try wait(fd, for: Int16(POLLIN), until: deadline)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                throw TranscriptionError.failed("MLX worker stopped.")
            }
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func close() {
        try? input?.close()
        try? output?.close()
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process = nil
        input = nil
        output = nil
    }
}
