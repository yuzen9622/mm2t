import AVFoundation
import Foundation
import MM2TCore
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
    @ObservationIgnored private var loadID = UUID()
    /// Removing the echo from a recording that has no kept playback track yet.
    @ObservationIgnored private(set) var cleaning: Task<Void, Never>?
    @ObservationIgnored private lazy var finish = FinishObserver { [weak self] in self?.isPlaying = false }

    public init() {}

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
        status = .loading
        duration = 0
        let found = await Task.detached(priority: .userInitiated) {
            (exists: [mic, remote].contains { FileManager.default.fileExists(atPath: $0.path) },
             kept: PlaybackMic.kept(beside: mic))
        }.value
        guard loadID == request else { return }
        guard found.exists else {
            status = .unavailable
            return
        }
        install(PlaybackAudio(mic: found.kept ?? mic, remote: remote))
        guard found.kept == nil, status == .ready else { return }
        // Removing the echo reads the whole recording, minutes of work for a long one. The tracks
        // play as recorded until it is done, and the result is kept so it happens once a meeting.
        cleaning = Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) {
                PlaybackAudio.prepare(mic: mic, remote: remote)
            }.value
            guard let self, self.loadID == request, prepared.mic != mic else { return }
            self.install(prepared)
        }
    }

    /// Replaces the tracks being played, keeping the playhead where it is.
    private func install(_ audio: PlaybackAudio) {
        let time = currentTime, wasPlaying = isPlaying
        players.forEach { $0.stop() }
        players = [audio.mic, audio.remote].compactMap { try? AVAudioPlayer(contentsOf: $0) }
        players.forEach { $0.prepareToPlay() }
        // The longer track ends last; when it does, playback is over.
        players.max { $0.duration < $1.duration }?.delegate = finish
        duration = players.map(\.duration).max() ?? 0
        status = players.isEmpty ? .failed : .ready
        if wasPlaying {
            play(from: time)
        } else {
            seek(to: time)
        }
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

    /// The kept playback track when the meeting has one; otherwise removes the echo and keeps the
    /// result. The mic as recorded when it heard no echo or cannot be cleaned.
    static func prepare(mic: URL, remote: URL) -> PlaybackAudio {
        if PlaybackMic.kept(beside: mic) == nil {
            do {
                PlaybackMic.keep(try EchoRemover().clean(mic: mic, remote: remote)?.audio, beside: mic)
            } catch {
                // Unreadable tracks are not marked as echo-free; the next load tries again.
            }
        }
        return PlaybackAudio(mic: PlaybackMic.kept(beside: mic) ?? mic, remote: remote)
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
