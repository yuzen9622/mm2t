import AVFoundation
import Foundation
import Observation

/// Plays a meeting's two tracks together.
@MainActor
public protocol MeetingPlayback: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    /// The longer track's length; 0 before anything loaded.
    var duration: TimeInterval { get }
    func load(mic: URL, remote: URL)
    func play(from time: TimeInterval)
    func pause()
    /// Moves the playhead without starting or stopping playback.
    func seek(to time: TimeInterval)
}

extension MeetingPlayback {
    public var duration: TimeInterval { 0 }
    public func seek(to time: TimeInterval) {
        if isPlaying { play(from: time) }
    }
}

/// Two `AVAudioPlayer`s started on the same device time, so the mic and remote tracks stay
/// aligned the way the recorder wrote them.
@MainActor @Observable
public final class TwoTrackPlayer: MeetingPlayback {
    public private(set) var isPlaying = false
    @ObservationIgnored private var players: [AVAudioPlayer] = []
    @ObservationIgnored private lazy var finish = FinishObserver { [weak self] in self?.isPlaying = false }

    public init() {}

    public var currentTime: TimeInterval { players.first?.currentTime ?? 0 }
    public var duration: TimeInterval { players.map(\.duration).max() ?? 0 }

    public func seek(to time: TimeInterval) {
        if isPlaying {
            play(from: time)
        } else {
            players.forEach { $0.currentTime = min(max(0, time), $0.duration) }
        }
    }

    public func load(mic: URL, remote: URL) {
        pause()
        players = [mic, remote].compactMap { try? AVAudioPlayer(contentsOf: $0) }
        players.forEach { $0.prepareToPlay() }
        // The longer track ends last; when it does, playback is over.
        players.max { $0.duration < $1.duration }?.delegate = finish
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

/// Tells the player its audio ran out, which `AVAudioPlayer` only says through a delegate.
private final class FinishObserver: NSObject, AVAudioPlayerDelegate {
    let finished: @MainActor () -> Void

    init(_ finished: @escaping @MainActor () -> Void) { self.finished = finished }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in finished() }
    }
}
