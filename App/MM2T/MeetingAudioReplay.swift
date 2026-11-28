#if DEBUG
import Foundation
import MM2TApp
import MM2TSystem
import MM2TCore

/// The Debug benchmark replaces only the capture device. Both recognition paths use the app's normal providers.
struct MeetingAudioReplay: Recorder {
    let root: URL
    func start(_ configuration: RecorderConfiguration) async throws -> any RecordingSession {
        let session = try ReplaySession(root: root, configuration: configuration)
        await session.startReplay()
        return session
    }
}

private actor ReplaySession: RecordingSession {
    nonisolated let events: AsyncStream<RecorderEvent>
    private let eventWriter: AsyncStream<RecorderEvent>.Continuation
    private let stream: AsyncStream<[Float]>
    private let audio: AsyncStream<[Float]>.Continuation
    private let configuration: RecorderConfiguration
    private let root: URL
    private var manifest: RecordingManifest
    private var inputs: [FileHandle] = [], outputs: [FileHandle] = []
    private var pending = [Data(), Data()]
    private var frames = 0
    private var ended = false
    private var paused = false
    private let length: Int
    private var replay: Task<Void, Never>?

    init(root: URL, configuration: RecorderConfiguration) throws {
        self.root = root
        self.configuration = configuration
        (events, eventWriter) = AsyncStream.makeStream()
        (stream, audio) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(20))
        manifest = RecordingManifest(title: configuration.title, startedAt: Date(), platform: configuration.platform,
                                     targetBundleID: configuration.systemAudio.appBundleID)
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        try manifest.write(to: configuration.directory)
        length = try WAVFormat.frameCount(root.appending(path: "mic-full.wav"))
        for name in ["mic", "remote"] {
            let source = root.appending(path: "\(name)-full.wav")
            guard try WAVFormat.frameCount(source) == length else { throw CocoaError(.fileReadCorruptFile) }
            let input = try FileHandle(forReadingFrom: source)
            let header = try input.read(upToCount: 44) ?? Data()
            guard header.count == 44, header.subdata(in: 36..<40) == Data("data".utf8) else { throw CocoaError(.fileReadCorruptFile) }
            inputs.append(input)
            let destination = configuration.directory.appending(path: "\(name).wav")
            try header.write(to: destination)
            let output = try FileHandle(forWritingTo: destination)
            try output.seekToEnd()
            outputs.append(output)
        }
    }

    var elapsed: TimeInterval { Double(frames) / 16_000 }
    func pause() { paused = true }
    func resume() { paused = false }
    func markHighlight() -> Highlight { Highlight(time: elapsed) }
    func audioStream() -> AsyncStream<[Float]> { stream }
    func startReplay() {
        if replay == nil { replay = Task { await play() } }
    }

    private func play() async {
        var deadline = ContinuousClock.now
        do {
            while !ended, frames < length {
                let count = min(1600, length - frames)
                deadline += .milliseconds(Double(count) / 16)
                try await ContinuousClock().sleep(until: deadline)
                guard !ended else { return }
                if paused { continue }
                let captionIndex = configuration.systemAudio.captionTrack == .me ? 0 : 1
                var levels: [AudioLevel] = []
                for track in inputs.indices {
                    let bytes = try inputs[track].read(upToCount: count * 2) ?? Data()
                    guard bytes.count == count * 2 else { throw CocoaError(.fileReadCorruptFile) }
                    let captured = track == 1 && configuration.systemAudio == .off ? Data(count: bytes.count) : bytes
                    pending[track].append(captured)
                    captured.withUnsafeBytes { ptr in
                        let pcm = ptr.bindMemory(to: Int16.self).map { Float($0) / 32768 }
                        levels.append(pcm.withUnsafeBufferPointer { AudioLevel(samples: $0) })
                        if track == captionIndex { audio.yield(pcm) }
                    }
                }
                frames += count
                if frames % 16_000 == 0 { try flush() }
                eventWriter.yield(.levels(TrackLevels(me: levels[0], remote: levels[1])))
            }
            if frames == length { try Data().write(to: root.appending(path: "replay-ended"), options: .atomic) }
        } catch { if !ended { eventWriter.yield(.writeFailed(String(describing: error))) } }
    }

    private func flush() throws {
        for i in outputs.indices {
            try outputs[i].write(contentsOf: pending[i])
            pending[i].removeAll(keepingCapacity: true)
        }
    }

    func stop() throws -> Recording {
        ended = true
        replay?.cancel()
        audio.finish()
        eventWriter.finish()
        try flush()
        for output in outputs {
            for (offset, size) in [(4, 36 + frames * 2), (40, frames * 2)] {
                try output.seek(toOffset: UInt64(offset))
                try withUnsafeBytes(of: UInt32(size).littleEndian) { try output.write(contentsOf: Data($0)) }
            }
            try output.synchronize()
            try output.close()
        }
        for input in inputs { try input.close() }
        manifest.duration = elapsed
        try manifest.write(to: configuration.directory)
        return Recording(micTrack: configuration.directory.appending(path: "mic.wav"),
            remoteTrack: configuration.directory.appending(path: "remote.wav"), highlights: [],
            metadata: MeetingMetadata(title: configuration.title, startedAt: manifest.startedAt, duration: elapsed))
    }
}
#endif
