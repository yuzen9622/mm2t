import Foundation
import MM2TCore
@testable import MM2TDiarization

/// The AliMeeting data, models and harness output that `Evaluation/diarization/run_all.sh`
/// leaves on disk. They are not in git, so on a fresh clone these tests skip.
struct EvaluationData {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Evaluation/diarization")
    /// The 4-speaker session; `nearmix_opus` is the condition closest to the app's remote track.
    static let session = "R8007_M8011"

    let models = DiarizationModels(directory: Self.root.appending(path: "models"))
    let track = Self.root.appending(path: "data/wav/nearmix_opus/\(Self.session)__nearmix_opus.wav")
    let reference = Self.root.appending(path: "data/ref/\(Self.session).rttm")
    let uem = Self.root.appending(path: "data/ref/\(Self.session).uem")
    let harness = Self.root.appending(path: "out/nemotron3-offline/nearmix_opus/\(Self.session)__nearmix_opus.rttm")

    static var missing: String? {
        let data = EvaluationData()
        guard data.models.isDownloaded else { return "no models under \(data.models.directory.path); run Evaluation/diarization/run_all.sh" }
        for file in [data.track, data.reference, data.uem, data.harness]
        where !FileManager.default.fileExists(atPath: file.path) {
            return "missing \(file.path); run Evaluation/diarization/run_all.sh"
        }
        return nil
    }

    static var available: Bool {
        if let missing { print("Skipping real-audio test: \(missing)") }
        return missing == nil
    }

    func scoredEnd() throws -> TimeInterval {
        let fields = try String(contentsOf: uem, encoding: .utf8).split(separator: " ")
        return Double(fields[3].trimmingCharacters(in: .whitespacesAndNewlines))!
    }
}

/// `SPEAKER <file> 1 <start> <duration> <NA> <NA> <speaker> <NA> <NA>` lines.
func readRTTM(_ url: URL) throws -> [Diarization.Segment] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
        let fields = line.split(separator: " ")
        guard fields.count >= 8, fields[0] == "SPEAKER", let start = Double(fields[3]), let length = Double(fields[4])
        else { return nil }
        return segment(String(fields[7]), start, start + length)
    }
}

/// DER components on a 10 ms grid with pyannote.metrics' conventions: a collar of `collar` seconds
/// centred on every reference boundary is not scored, overlapped speech is, and hypothesis
/// clusters map one-to-one onto reference speakers to maximize matched time.
struct Score: CustomStringConvertible {
    var miss = 0.0, falseAlarm = 0.0, confusion = 0.0, total = 0.0
    var referenceSpeakers = 0, hypothesisSpeakers = 0
    var mapping: [ClusterID: ClusterID] = [:]

    var der: Double { (miss + falseAlarm + confusion) / total }
    var description: String {
        String(format: "DER %.2f%% (miss %.2f%%, false alarm %.2f%%, confusion %.2f%%), speakers %d/%d",
               der * 100, miss / total * 100, falseAlarm / total * 100, confusion / total * 100,
               referenceSpeakers, hypothesisSpeakers)
    }

    init(reference: [Diarization.Segment], hypothesis: [Diarization.Segment], from start: TimeInterval = 0,
         to end: TimeInterval, collar: TimeInterval) {
        let step = 0.01
        let frames = Int(((end - start) / step).rounded())
        func activity(_ segments: [Diarization.Segment]) -> (labels: [ClusterID], active: [[Bool]]) {
            let labels = Array(Set(segments.map(\.cluster))).sorted { $0.rawValue < $1.rawValue }
            var active = Array(repeating: [Bool](repeating: false, count: frames), count: labels.count)
            for segment in segments {
                let row = labels.firstIndex(of: segment.cluster)!
                let first = max(0, Int(((segment.range.start - start) / step - 0.5).rounded(.up)))
                let last = min(frames, Int(((segment.range.end - start) / step - 0.5).rounded(.up)))
                if first < last { for frame in first..<last { active[row][frame] = true } }
            }
            return (labels, active)
        }
        let ref = activity(reference), hyp = activity(hypothesis)
        referenceSpeakers = ref.labels.count
        hypothesisSpeakers = hyp.labels.count

        var scored = [Bool](repeating: true, count: frames)
        if collar > 0 {
            for boundary in reference.flatMap({ [$0.range.start, $0.range.end] }) {
                let lo = max(0, Int(((boundary - collar / 2 - start) / step - 0.5).rounded(.up)))
                let hi = min(frames, Int(((boundary + collar / 2 - start) / step - 0.5).rounded(.up)))
                if lo < hi { for frame in lo..<hi { scored[frame] = false } }
            }
        }

        var cooccurrence = Array(repeating: [Double](repeating: 0, count: ref.labels.count), count: hyp.labels.count)
        for frame in 0..<frames where scored[frame] {
            for h in hyp.labels.indices where hyp.active[h][frame] {
                for r in ref.labels.indices where ref.active[r][frame] { cooccurrence[h][r] += step }
            }
        }
        let assignment = Self.bestAssignment(cooccurrence, references: ref.labels.count)
        for (h, r) in assignment.enumerated() { if let r { mapping[hyp.labels[h]] = ref.labels[r] } }

        for frame in 0..<frames where scored[frame] {
            let speaking = ref.labels.indices.filter { ref.active[$0][frame] }
            let detected = hyp.labels.indices.filter { hyp.active[$0][frame] }
            let correct = detected.filter { assignment[$0].map(speaking.contains) ?? false }.count
            total += Double(speaking.count) * step
            miss += Double(max(0, speaking.count - detected.count)) * step
            falseAlarm += Double(max(0, detected.count - speaking.count)) * step
            confusion += Double(min(speaking.count, detected.count) - correct) * step
        }
    }

    /// Exhaustive one-to-one assignment; meetings have at most 8 clusters.
    private static func bestAssignment(_ weights: [[Double]], references: Int) -> [Int?] {
        var best: (score: Double, assignment: [Int?]) = (-1, [])
        func search(_ h: Int, _ used: Set<Int>, _ score: Double, _ current: [Int?]) {
            if h == weights.count {
                if score > best.score { best = (score, current) }
                return
            }
            search(h + 1, used, score, current + [nil])
            for r in 0..<references where !used.contains(r) {
                search(h + 1, used.union([r]), score + weights[h][r], current + [r])
            }
        }
        search(0, [], 0, [])
        return best.assignment
    }
}

/// Fraction of 10 ms frames on which two diarizations mark exactly the same set of cluster names.
func frameAgreement(_ a: [Diarization.Segment], _ b: [Diarization.Segment], to end: TimeInterval) -> Double {
    let frames = Int((end / 0.01).rounded())
    func sets(_ segments: [Diarization.Segment]) -> [Set<String>] {
        var result = [Set<String>](repeating: [], count: frames)
        for segment in segments {
            let first = max(0, Int((segment.range.start / 0.01 - 0.5).rounded(.up)))
            let last = min(frames, Int((segment.range.end / 0.01 - 0.5).rounded(.up)))
            if first < last { for frame in first..<last { result[frame].insert(segment.cluster.rawValue) } }
        }
        return result
    }
    let left = sets(a), right = sets(b)
    return Double(zip(left, right).filter { $0 == $1 }.count) / Double(frames)
}
