import Foundation
import MM2TCore
import MM2TSystem

/// Transcribes a recording while it is still being made, a few minutes at a time, so that when the
/// meeting ends only its last stretch is left to send. Speech recognition is the one step whose wait
/// grows with the meeting's length; this takes it out of the wait after the meeting.
///
/// Pieces are transcribed without speaker labels, which a service numbers per file and so cannot be
/// joined across pieces; the on-device model separates the speakers afterwards. Any failure makes
/// `finish` return nil, and the meeting is transcribed whole as before.
public actor LiveTranscriber {
    /// Length of a piece. Shorter means less left at the end and more requests.
    public static let pieceSeconds: TimeInterval = 180
    /// How far back from a piece's end to look for a quiet place to cut.
    static let searchSeconds: TimeInterval = 10

    private var mic: URL
    private var remote: URL
    private let chain: TranscriptionChain
    private let hints: [String]
    private let pieceSeconds: TimeInterval
    private let scratch: URL

    private var cut = 0
    private var words: [Track: [TimedWord]] = [.me: [], .remote: []]
    private var sources: [Track: TranscriptionSource] = [:]
    private var failed = false
    private var working: Task<Void, Never>?

    /// `mic` and `remote` are the files the recorder is writing. `scratch` holds each piece while it uploads.
    public init(mic: URL, remote: URL, chain: TranscriptionChain, hints: [String], scratch: URL,
                pieceSeconds: TimeInterval = LiveTranscriber.pieceSeconds) {
        self.mic = mic
        self.remote = remote
        self.chain = chain
        self.hints = hints
        self.scratch = scratch
        self.pieceSeconds = pieceSeconds
    }

    /// Seconds of the recording transcribed so far.
    public private(set) var transcribedSeconds: TimeInterval = 0

    /// Transcribes every whole piece the recording has grown past. Call it now and then while recording;
    /// a call made while an earlier one is still working waits for it rather than starting a second.
    public func advance() async {
        await run { await self.transcribePieces(final: false) }
    }

    /// Transcribes what is left once the recorder has closed the files, which by then have moved to
    /// `mic` and `remote` in the library. nil when any piece failed or no word was heard.
    public func finish(mic: URL, remote: URL) async -> Transcription? {
        await working?.value
        self.mic = mic
        self.remote = remote
        defer { try? FileManager.default.removeItem(at: scratch) }
        await run { await self.transcribePieces(final: true) }
        // Nothing heard at all is more likely this class judging quiet speech silent than a meeting
        // without a word, so that case is left to the whole-file transcription too.
        guard !failed, let fallback = chain.routes.first?.source,
              !(words[.me]!.isEmpty && words[.remote]!.isEmpty) else { return nil }
        return Transcription(
            me: TrackTranscript(source: sources[.me] ?? fallback, content: .unlabeled(words[.me]!)),
            remote: TrackTranscript(source: sources[.remote] ?? fallback, content: .unlabeled(words[.remote]!)))
    }

    private func run(_ work: @escaping @Sendable () async -> Void) async {
        let previous = working
        let task = Task {
            await previous?.value
            await work()
        }
        working = task
        await task.value
    }

    private func transcribePieces(final: Bool) async {
        while !failed {
            do {
                let available = min(try WAVFormat.frameCount(mic), try WAVFormat.frameCount(remote))
                let rate = try WAVFormat.read(mic, frames: 0..<1).sampleRate
                let piece = Int(pieceSeconds * Double(rate)), search = Int(Self.searchSeconds * Double(rate))
                var end = available
                if !final || available - cut > piece {
                    guard available - cut >= piece else { return }
                    // End the piece where both tracks are quietest, so no word is cut in half.
                    let from = cut + piece - search
                    let tail = (try WAVFormat.read(mic, frames: from..<cut + piece), try WAVFormat.read(remote, frames: from..<cut + piece))
                    end = from + QuietCut.index(mic: tail.0.samples, remote: tail.1.samples, window: rate * 3 / 10)
                }
                guard end > cut else { return }
                let range = cut..<end
                async let mine = transcribe(.me, mic, range, rate)
                async let theirs = transcribe(.remote, remote, range, rate)
                let (a, b) = try await (mine, theirs)
                for (track, result) in [(Track.me, a), (.remote, b)] {
                    words[track]! += result.words
                    if let source = result.source { sources[track] = source }
                }
                cut = end
                transcribedSeconds = Double(end) / Double(rate)
                if final, end == available { return }
            } catch {
                failed = true
            }
        }
    }

    /// The words of one piece of one track, timed from the start of the recording.
    private nonisolated func transcribe(_ track: Track, _ url: URL, _ range: Range<Int>, _ rate: Int) async throws
        -> (words: [TimedWord], source: TranscriptionSource?) {
        let audio = try WAVFormat.read(url, frames: range)
        if QuietCut.isSilent(audio.samples) { return ([], nil) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appending(path: "\(track.rawValue)-\(range.lowerBound).wav")
        try WAVFormat.write(audio, to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transcript = try await chain.transcribe(audio: file, hints: hints, labelSpeakers: false)
        let offset = Double(range.lowerBound) / Double(rate)
        let words = transcript.words.map {
            TimedWord(text: $0.text, range: TimeRange(start: $0.range.start + offset, end: $0.range.end + offset))
        }
        return (words, transcript.source)
    }
}
