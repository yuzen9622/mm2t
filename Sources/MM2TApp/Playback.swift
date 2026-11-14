import AVFoundation
import Foundation
import MM2TSystem
import Observation

/// The transcript list observes line changes; only the current lyric and transport observe time.
@MainActor @Observable
public final class TranscriptPlayhead {
    public private(set) var time: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var isPlaying = false
    public private(set) var currentLine: Int?
    @ObservationIgnored private var starts: [TimeInterval] = []

    public init() {}

    public func follow(_ starts: [TimeInterval]) {
        self.starts = starts
        currentLine = KaraokeTiming.currentLine(starts: starts, at: time)
    }

    public func sample(time: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        self.time = time
        self.duration = duration
        self.isPlaying = isPlaying
        currentLine = KaraokeTiming.currentLine(starts: starts, at: time)
    }
}

public enum PlaybackStatus: Equatable, Sendable {
    case loading
    case ready
    case unavailable
    case failed
}

/// Plays a meeting's two tracks together.
@MainActor
public protocol MeetingPlayback: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    /// The longer track's length; 0 before anything loaded.
    var duration: TimeInterval { get }
    var status: PlaybackStatus { get }
    func load(mic: URL, remote: URL) async
    func play(from time: TimeInterval)
    func pause()
    /// Moves the playhead without starting or stopping playback.
    func seek(to time: TimeInterval)
}

extension MeetingPlayback {
    public var duration: TimeInterval { 0 }
    public var status: PlaybackStatus { .ready }
    public func seek(to time: TimeInterval) {
        if isPlaying { play(from: time) }
    }
}

/// Two `AVAudioPlayer`s started on the same device time, so the mic and remote tracks stay
/// aligned the way the recorder wrote them.
@MainActor @Observable
public final class TwoTrackPlayer: MeetingPlayback {
    public private(set) var isPlaying = false
    public private(set) var status: PlaybackStatus = .loading
    public private(set) var duration: TimeInterval = 0
    @ObservationIgnored private var players: [AVAudioPlayer] = []
    @ObservationIgnored private var audio: PlaybackAudio?
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private lazy var finish = FinishObserver { [weak self] in self?.isPlaying = false }

    public init() {}

    deinit { audio?.removeTemporaryFiles() }

    public var currentTime: TimeInterval { players.first?.currentTime ?? 0 }

    public func seek(to time: TimeInterval) {
        if isPlaying {
            play(from: time)
        } else {
            players.forEach { $0.currentTime = min(max(0, time), $0.duration) }
        }
    }

    public func load(mic: URL, remote: URL) async {
        let request = UUID()
        loadID = request
        pause()
        players = []
        audio?.removeTemporaryFiles()
        audio = nil
        status = .loading
        duration = 0
        let metadata = await Task.detached(priority: .userInitiated) {
            let urls = [mic, remote].filter { FileManager.default.fileExists(atPath: $0.path) }
            let duration = urls.compactMap { url -> TimeInterval? in
                guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
                return Double(file.length) / file.processingFormat.sampleRate
            }.max() ?? 0
            return (exists: !urls.isEmpty, duration: duration)
        }.value
        guard loadID == request else { return }
        duration = metadata.duration
        guard metadata.exists else {
            status = .unavailable
            return
        }
        // Keep the original tracks intact. Filtering a long recording must not block the UI.
        let prepared = await Task.detached(priority: .userInitiated) {
            PlaybackAudio.prepare(mic: mic, remote: remote)
        }.value
        guard loadID == request else {
            prepared.removeTemporaryFiles()
            return
        }
        audio = prepared
        players = [prepared.mic, prepared.remote].compactMap { try? AVAudioPlayer(contentsOf: $0) }
        players.forEach { $0.prepareToPlay() }
        // The longer track ends last; when it does, playback is over.
        players.max { $0.duration < $1.duration }?.delegate = finish
        duration = players.map(\.duration).max() ?? 0
        status = players.isEmpty ? .failed : .ready
    }

    public func play(from time: TimeInterval) {
        guard let first = players.first else { return }
        let start = first.deviceCurrentTime + 0.05
        for player in players {
            player.currentTime = min(time, player.duration)
            player.play(atTime: start)
        }
        isPlaying = true
    }

    public func pause() {
        players.forEach { $0.pause() }
        isPlaying = false
    }
}

/// Playback needs the same echo-free microphone signal as transcription. Raw files remain the
/// source of truth, including for older meetings that predate this playback fix.
struct PlaybackAudio: Sendable {
    let mic: URL
    let remote: URL
    private let temporaryMic: URL?

    static func prepare(mic: URL, remote: URL) -> PlaybackAudio {
        let cleaned = try? EchoRemover().clean(mic: mic, remote: remote)
        return PlaybackAudio(mic: cleaned?.audio ?? mic, remote: remote, temporaryMic: cleaned?.audio)
    }

    func removeTemporaryFiles() {
        if let temporaryMic { try? FileManager.default.removeItem(at: temporaryMic) }
    }
}

/// Tells the player its audio ran out, which `AVAudioPlayer` only says through a delegate.
private final class FinishObserver: NSObject, AVAudioPlayerDelegate {
    let finished: @MainActor () -> Void

    init(_ finished: @escaping @MainActor () -> Void) { self.finished = finished }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [finished] in finished() }
    }
}
