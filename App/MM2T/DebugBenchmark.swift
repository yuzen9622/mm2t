import AppKit
import MM2TApp
import MM2TCore

/// Debug-build timing hook. With `MM2T_BENCH_REMOTE`, `MM2T_BENCH_MIC` (audio files) and
/// `MM2T_BENCH_OUT` (a report path) set, the app processes that recording with the user's own keys,
/// settings and models, writes how long each step took, and quits. Point `-MM2TDataRoot` at a
/// scratch folder so the recording stays out of the real library.
@MainActor
enum DebugBenchmark {
    #if DEBUG
    private static let env = ProcessInfo.processInfo.environment
    static var isRequested: Bool { env["MM2T_BENCH_REMOTE"] != nil && env["MM2T_BENCH_MIC"] != nil && env["MM2T_BENCH_OUT"] != nil }
    #else
    static var isRequested: Bool { false }
    #endif

    static func run(app: AppController) {
        #if DEBUG
        Task {
            var report: [String: Any] = [:]
            defer {
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(filePath: env["MM2T_BENCH_OUT"]!))
                }
                NSApp.terminate(nil)
            }
            do {
                let staging = app.paths.root.appending(path: "staging-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let mic = staging.appending(path: "mic.wav"), remote = staging.appending(path: "remote.wav")
                try FileManager.default.copyItem(at: URL(filePath: env["MM2T_BENCH_MIC"]!), to: mic)
                try FileManager.default.copyItem(at: URL(filePath: env["MM2T_BENCH_REMOTE"]!), to: remote)
                let meeting = try await app.library.create(Recording(
                    micTrack: mic, remoteTrack: remote, highlights: [],
                    metadata: MeetingMetadata(title: "Recording", startedAt: Date(), duration: 0)))

                var marks: [(String, Date)] = []
                func watch() {
                    withObservationTracking {
                        if case .running(let step?) = app.queue.jobs[meeting.id], marks.last?.0 != step.rawValue {
                            marks.append((step.rawValue, Date()))
                        }
                    } onChange: { Task { @MainActor in watch() } }
                }
                watch()
                let start = Date()
                await app.queue.run(.process, on: meeting.id)
                let end = Date()

                var steps: [String: Double] = [:]
                for (index, mark) in marks.enumerated() {
                    steps[mark.0] = (index + 1 < marks.count ? marks[index + 1].1 : end).timeIntervalSince(mark.1)
                }
                let done = try await app.library.meeting(meeting.id)
                report["steps"] = steps
                report["order"] = marks.map(\.0)
                report["total"] = end.timeIntervalSince(start)
                report["status"] = String(describing: done.status)
                report["job"] = String(describing: app.queue.jobs[meeting.id])
                report["title"] = done.metadata.title
                report["separatedTrack"] = done.separatedTrack?.rawValue ?? "remote"
                report["attribution"] = done.attribution?.source?.rawValue ?? "none"
                report["speakers"] = done.speakers.count
                report["utterances"] = done.utterances.count
                report["characters"] = done.utterances.reduce(0) { $0 + $1.text.count }
                report["paragraphs"] = done.outputs.cleaned?.paragraphs.count ?? 0
                report["cleanedCharacters"] = done.outputs.cleaned?.paragraphs.reduce(0) { $0 + $1.text.count } ?? 0
                report["terms"] = done.outputs.summary?.terms ?? []
                report["document"] = app.paths.meetings.appending(path: meeting.id.description).path
            } catch {
                report["error"] = String(describing: error)
            }
        }
        #endif
    }
}
