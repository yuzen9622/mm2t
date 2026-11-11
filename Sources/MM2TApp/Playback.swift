import AVFoundation
import Foundation
import Observation

/// Plays a meeting's two tracks together.
@MainActor
public protocol MeetingPlayback: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    func load(mic: URL, remote: URL)
    func play(from time: TimeInterval)
    func pause()
}

/// Two `AVAudioPlayer`s started on the same device time, so the mic and remote tracks stay
/// aligned the way the recorder wrote them.
@MainActor @Observable
public final class TwoTrackPlayer: MeetingPlayback {
    public private(set) var isPlaying = false
    @ObservationIgnored private var players: [AVAudioPlayer] = []

    public init() {}

    public var currentTime: TimeInterval { players.first?.currentTime ?? 0 }

    public func load(mic: URL, remote: URL) {
        pause()
        players = [mic, remote].compactMap { try? AVAudioPlayer(contentsOf: $0) }
        players.forEach { $0.prepareToPlay() }
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
