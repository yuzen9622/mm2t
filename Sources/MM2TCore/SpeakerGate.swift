import Accelerate
import AVFoundation
import Foundation

/// Decides where each detected turn goes, without consulting the voiceprint store.
public struct SpeakerGate: Sendable {
    public enum Mode: Sendable { case callMic, call, room }
    public enum Destination: Hashable, Sendable {
        case foreground(ClusterID)
        case background(ClusterID)
    }

    struct CallMicThresholds: Sendable {
        let createDrop: Double
        let keepDrop: Double

        init(createDrop: Double, keepDrop: Double) {
            precondition(createDrop <= keepDrop)
            self.createDrop = createDrop
            self.keepDrop = keepDrop
        }
    }

    private struct CallMicIdentity {
        let anchor: ClusterID?
        let protected: Set<ClusterID>

        init(userEmbeddings: [Embedding], heard: Diarization, thresholds: MatchThresholds) {
            let clusters = Set(heard.segments.map(\.cluster))
            let similarities: [ClusterID: Double] = Dictionary(uniqueKeysWithValues: clusters.compactMap { cluster in
                let vectors = heard.embeddings[cluster] ?? heard.briefEmbeddings[cluster] ?? []
                let similarity = userEmbeddings.flatMap { a in vectors.map { a.cosineSimilarity(to: $0) } }.max()
                return similarity.map { (cluster, $0) }
            })
            anchor = similarities.filter { $0.value >= thresholds.suggest }
                .min { lhs, rhs in
                    lhs.value == rhs.value ? lhs.key.rawValue < rhs.key.rawValue : lhs.value > rhs.value
                }?.key
            protected = Set(similarities.filter { $0.value >= thresholds.user }.keys)
        }
    }

    // AliMeeting Eval, 96 online-mic mixes with enrollment and single-drop fallback when unanchored:
    // 98.53% worst solo retention, 99.80% worst speaker-matched retention, 13 TV clusters vs 46.
    static let enrolledCallMic = CallMicThresholds(createDrop: 8, keepDrop: 14)

    // AliMeeting Eval, 96 online-mic mixes: 18 dB kept 95.87% of reference speech and at least
    // 98.10% of detected reference speech in every mix condition. The second sweep kept this
    // as the unenrolled default: no fallback dual threshold met both new 98% retention floors.
    public static let callMicDrop = 18.0
    // AliMeeting Eval: 10 dB with the 15 s cap and a 2 s minimum removed 7 of 12 TV speakers
    // without changing any of the eight clean-room DERs (8.110% pooled).
    public static let roomDrop = 10.0
    public static let minForegroundSpeech: TimeInterval = 2
    public static let roomQuietSpeechLimit: TimeInterval = 15
    // MatchThresholds.campPlus.suggest; calibrated on AliMeeting Eval in Evaluation/diarization/RESULTS.md.
    public static let fragmentSimilarity = 0.60
    private static let referencePercentile = 0.90

    public let callMicDrop: Double
    public let roomDrop: Double
    public let minForegroundSpeech: TimeInterval

    public init(callMicDrop: Double = Self.callMicDrop, roomDrop: Double = Self.roomDrop,
                minForegroundSpeech: TimeInterval = Self.minForegroundSpeech) {
        self.callMicDrop = callMicDrop
        self.roomDrop = roomDrop
        self.minForegroundSpeech = minForegroundSpeech
    }

    /// Acoustic evidence depends on the input track, not the thresholds or cluster assignments.
    public struct Evidence: Sendable {
        fileprivate let heard: Diarization
        fileprivate let levels: [SpeechEnergy.Level?]
        fileprivate let speechDurations: [ClusterID: TimeInterval]?
        fileprivate let micGroups: [ClusterID: SpeechEnergy.Level]

        public init(for heard: Diarization, energy: SpeechEnergy?) {
            self.init(for: heard, energy: energy, speechDurations: nil)
        }

        init(for heard: Diarization, energy: SpeechEnergy?, measuringMicGroups: Bool) {
            self.init(for: heard, energy: energy, speechDurations: nil, measuringMicGroups: measuringMicGroups)
        }

        init(for heard: Diarization, energy: SpeechEnergy?, speechDurations: [ClusterID: TimeInterval]?,
             measuringMicGroups: Bool = false) {
            self.heard = heard
            self.speechDurations = speechDurations
            levels = heard.segments.map { energy?.level(in: $0.range) }
            if measuringMicGroups, let energy {
                micGroups = Dictionary(grouping: heard.segments, by: \.cluster).compactMapValues { turns in
                    energy.voicedMedian(in: turns.map(\.range))
                }
            } else {
                micGroups = [:]
            }
        }
    }

    /// One destination per input turn, in input order. A cluster can have both foreground and
    /// background turns on the call mic. Those destinations stay distinct through alignment.
    public func destinations(for heard: Diarization, mode: Mode, energy: SpeechEnergy? = nil,
                             protecting user: ClusterID? = nil) -> [Destination] {
        destinations(for: Evidence(for: heard, energy: mode == .call ? nil : energy), mode: mode, protecting: user)
    }

    public func destinations(for evidence: Evidence, mode: Mode, protecting user: ClusterID? = nil) -> [Destination] {
        let heard = evidence.heard, segments = heard.segments
        let levels = evidence.levels
        let reference = percentile(levels.compactMap { $0 }, Self.referencePercentile)
        let audible = segments.indices.map { i in
            guard mode == .callMic, let reference, let level = levels[i] else { return true }
            return level.db >= reference - callMicDrop
        }
        let groups = Dictionary(grouping: segments.indices, by: { segments[$0].cluster })
        var foreground: Set<ClusterID> = []
        var quiet: Set<ClusterID> = []
        for (cluster, indices) in groups {
            if cluster == user { foreground.insert(cluster); continue }
            let speech = evidence.speechDurations?[cluster] ?? indices.filter { audible[$0] }.reduce(0.0) { seconds, i in
                seconds + (levels[i]?.seconds ?? segments[i].range.duration)
            }
            if mode == .room, let reference, let median = percentile(indices.compactMap { levels[$0] }, 0.5),
               median < reference - roomDrop, speech < Self.roomQuietSpeechLimit {
                quiet.insert(cluster)
            } else if speech >= minForegroundSpeech {
                foreground.insert(cluster)
            }
        }
        var merged: [ClusterID: ClusterID] = [:]
        if mode != .callMic {
            func vectors(_ cluster: ClusterID) -> [Embedding] {
                (heard.embeddings[cluster] ?? []) + (heard.briefEmbeddings[cluster] ?? [])
            }
            let targets = foreground.sorted { $0.rawValue < $1.rawValue }.map { ($0, vectors($0)) }
            for cluster in groups.keys where !foreground.contains(cluster) && !quiet.contains(cluster) {
                var best = Self.fragmentSimilarity
                for (target, candidates) in targets {
                    if let score = vectors(cluster).flatMap({ a in candidates.map { a.cosineSimilarity(to: $0) } }).max(),
                       score >= Self.fragmentSimilarity, merged[cluster] == nil || score > best {
                        best = score
                        merged[cluster] = target
                    }
                }
            }
        }
        return segments.indices.map { i in
            let cluster = segments[i].cluster
            if audible[i], foreground.contains(cluster) { return .foreground(cluster) }
            if let target = merged[cluster] { return .foreground(target) }
            return .background(cluster)
        }
    }

    private func callMicDestinations(for evidence: Evidence, thresholds: CallMicThresholds,
                                     identity: CallMicIdentity) -> [Destination] {
        callMicDestinations(for: evidence, thresholds: thresholds, anchor: identity.anchor, protecting: identity.protected)
    }

    func callMicDestinations(for evidence: Evidence, thresholds: CallMicThresholds,
                             userEmbeddings: [Embedding], matchThresholds: MatchThresholds,
                             allowUnanchoredDual: Bool = false) -> [Destination] {
        let identity = CallMicIdentity(userEmbeddings: userEmbeddings, heard: evidence.heard, thresholds: matchThresholds)
        guard identity.anchor != nil || allowUnanchoredDual else {
            return destinations(for: evidence, mode: .callMic)
        }
        return callMicDestinations(for: evidence, thresholds: thresholds, identity: identity)
    }

    private func callMicDestinations(for evidence: Evidence, thresholds: CallMicThresholds,
                                     anchor: ClusterID?, protecting user: Set<ClusterID>) -> [Destination] {
        let reference = anchor.flatMap { evidence.micGroups[$0]?.db }.flatMap { $0.isFinite ? $0 : nil }
            ?? percentile(evidence.levels.compactMap { $0 }, Self.referencePercentile)
        let segments = evidence.heard.segments
        let groups = Dictionary(grouping: segments.indices, by: { segments[$0].cluster })
        let created = Set(groups.compactMap { cluster, indices -> ClusterID? in
            if user.contains(cluster) { return cluster }
            let group = evidence.micGroups[cluster]
            let duration = group?.seconds ?? indices.reduce(0) { $0 + segments[$1].range.duration }
            guard duration >= minForegroundSpeech else { return nil }
            if let reference, let group, group.db < reference - thresholds.createDrop { return nil }
            return cluster
        })
        return segments.indices.map { index in
            let cluster = segments[index].cluster
            if user.contains(cluster) { return .foreground(cluster) }
            guard created.contains(cluster) else { return .background(cluster) }
            if let reference, let level = evidence.levels[index], level.db < reference - thresholds.keepDrop {
                return .background(cluster)
            }
            return .foreground(cluster)
        }
    }

    /// STT can hear distant voices in gaps where the diarizer heard no speaker.
    /// Compare those words to this recording's detected turns, keeping quiet detected speech intact.
    func quietMicGaps(words: [TimedWord], turns: [TimeRange], energy: SpeechEnergy) -> [TimeRange] {
        let ordered = turns.sorted { $0.start < $1.start }
        let levels = ordered.compactMap { energy.level(in: $0) }
        guard let reference = percentile(levels, Self.referencePercentile), reference.isFinite else { return [] }
        var gaps: [TimeRange] = []
        var run: TimeRange?
        var index = 0
        func finish() {
            if let run, run.duration >= minForegroundSpeech { gaps.append(run) }
            run = nil
        }
        for word in words.sorted(by: { $0.range.start < $1.range.start }) {
            let range = word.range
            while index < ordered.count && ordered[index].end < range.start { index += 1 }
            if let run, range.start - run.end > Alignment.maxPause { finish() }
            if index < ordered.count && ordered[index].start <= range.end {
                finish()
                continue
            }
            // Include the immediate syllable around point timestamps and sub-frame word boundaries.
            let window = TimeRange(start: max(0, range.start - EchoProfile.margin), end: range.end + EchoProfile.margin)
            guard let level = energy.voicedMedian(in: [window]), level.db < reference - callMicDrop else {
                finish()
                continue
            }
            run = TimeRange(start: run?.start ?? range.start, end: max(run?.end ?? range.end, range.end))
        }
        finish()
        return gaps
    }

    private func percentile(_ levels: [SpeechEnergy.Level], _ fraction: Double) -> Double? {
        let ordered = levels.filter { $0.seconds > 0 }.sorted { $0.db < $1.db }
        let target = ordered.reduce(0) { $0 + $1.seconds } * fraction
        var seconds = 0.0
        for level in ordered {
            seconds += level.seconds
            if seconds >= target { return level.db }
        }
        return ordered.last?.db
    }
}

/// 20 ms mean-square frames, kept instead of copying whole recordings into memory.
public struct SpeechEnergy: Sendable {
    private static let frameSeconds = 0.02
    private static let silencePower = Float(pow(10.0, -80.0 / 10))
    private static let voicedRangePower: Float = 0.01 // 20 dB below a turn's loud frames.
    private let frames: [Float]

    /// Recording audio arrives in arbitrary pieces, so only complete frames are committed here.
    public struct Builder: Sendable {
        private static let frameLength = 320  // 20 ms at the streaming session's 16 kHz.
        private var frames: [Float] = []
        private var sum: Float = 0
        private var count = 0

        public init() {}

        public mutating func append(_ samples: [Float]) {
            samples.withUnsafeBufferPointer { audio in
                guard let base = audio.baseAddress else { return }
                var offset = 0
                while offset < audio.count {
                    let take = min(audio.count - offset, Self.frameLength - count)
                    var power: Float = 0
                    vDSP_svesq(base.advanced(by: offset), 1, &power, vDSP_Length(take))
                    sum += power
                    count += take
                    offset += take
                    if count == Self.frameLength {
                        frames.append(sum / Float(count))
                        sum = 0
                        count = 0
                    }
                }
            }
        }

        public var energy: SpeechEnergy? {
            guard !frames.isEmpty || count > 0 else { return nil }
            return SpeechEnergy(frames: count == 0 ? frames : frames + [sum / Float(count)])
        }
    }

    private init(frames: [Float]) { self.frames = frames }

    public init(reading url: URL, through end: TimeInterval? = nil) throws {
        let audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = audio.processingFormat
        let frameLength = max(1, Int(format.sampleRate * Self.frameSeconds))
        let block = frameLength * 100
        let sampleCount = min(audio.length, end.map { AVAudioFramePosition(ceil($0 * format.sampleRate)) } ?? audio.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var frames: [Float] = []
        while audio.framePosition < sampleCount {
            try Task.checkCancellation()
            try audio.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(block), sampleCount - audio.framePosition)))
            let count = Int(buffer.frameLength)
            guard let channels = buffer.floatChannelData, count > 0 else { break }
            for start in stride(from: 0, to: count, by: frameLength) {
                let stop = min(start + frameLength, count)
                var sum: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    var channelPower: Float = 0
                    vDSP_svesq(channels[channel].advanced(by: start), 1, &channelPower, vDSP_Length(stop - start))
                    sum += channelPower
                }
                frames.append(sum / Float((stop - start) * Int(format.channelCount)))
            }
        }
        self.frames = frames
    }

    struct Level: Sendable {
        let db: Double
        let seconds: TimeInterval
    }

    func voicedMedian(in ranges: [TimeRange]) -> Level? {
        var voiced: [(power: Float, seconds: Double)] = []
        var measured = false
        for range in ranges {
            measured = visitVoiced(in: range) { voiced.append(($0, $1)) } || measured
        }
        guard measured else { return nil }
        let total = voiced.reduce(0) { $0 + $1.seconds }
        var elapsed = 0.0
        for frame in voiced.sorted(by: { $0.power < $1.power }) {
            elapsed += frame.seconds
            if elapsed >= total / 2 { return Level(db: 10 * log10(Double(frame.power)), seconds: total) }
        }
        return Level(db: -.infinity, seconds: 0)
    }

    func level(in range: TimeRange) -> Level? {
        var power: Double = 0, seconds: TimeInterval = 0
        let measured = visitVoiced(in: range) { meanSquare, weight in
            power += Double(meanSquare) * weight
            seconds += weight
        }
        return measured ? Level(db: seconds > 0 ? 10 * log10(power / seconds) : -.infinity, seconds: seconds) : nil
    }

    private func visitVoiced(in range: TimeRange, _ visit: (Float, TimeInterval) -> Void) -> Bool {
        let first = max(0, Int(floor(range.start / Self.frameSeconds)))
        let end = min(frames.count, Int(ceil(range.end / Self.frameSeconds)))
        guard first < end else { return false }
        let powers = frames[first..<end]
        let loud = powers.sorted()[Int(Double(powers.count - 1) * 0.9)]
        let floor = max(Self.silencePower, loud * Self.voicedRangePower)
        for i in first..<end where frames[i] >= floor {
            let start = Double(i) * Self.frameSeconds
            let weight = max(0, min(range.end, start + Self.frameSeconds) - max(range.start, start))
            if weight > 0 { visit(frames[i], weight) }
        }
        return true
    }
}
