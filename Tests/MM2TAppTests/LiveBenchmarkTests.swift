import Foundation
import Testing
@testable import MM2TApp
import MM2TCore
import MM2TDiarization
import MM2TLocal
import MM2TProviders

/// Times the app's real pipeline on a long recording, with the keys in the Keychain and the models
/// the app downloaded. Runs only when asked:
/// `MM2T_BENCH_REMOTE=meeting.wav MM2T_BENCH_MIC=silence.wav MM2T_BENCH_ROOT=/scratch swift test --filter LiveBenchmarkTests`.
/// Swap the two files to time a meeting recorded in the room.
@Suite struct LiveBenchmarkTests {
    static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["MM2T_BENCH_REMOTE"] != nil && env["MM2T_BENCH_MIC"] != nil && env["MM2T_BENCH_ROOT"] != nil))
    @MainActor func processesALongMeeting() async throws {
        let root = URL(filePath: Self.env["MM2T_BENCH_ROOT"]!).appending(path: UUID().uuidString)
        let staging = root.appending(path: "staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let mic = staging.appending(path: "mic.wav"), remote = staging.appending(path: "remote.wav")
        try FileManager.default.copyItem(at: URL(filePath: Self.env["MM2T_BENCH_MIC"]!), to: mic)
        try FileManager.default.copyItem(at: URL(filePath: Self.env["MM2T_BENCH_REMOTE"]!), to: remote)

        let paths = AppPaths.standard()
        let library = MeetingLibrary(root: root.appending(path: "Meetings"))
        let setup = PipelineSetup(
            library: library, voiceprints: try VoiceprintStore(fileURL: root.appending(path: "voiceprints.json")),
            credentials: KeychainCredentialStore(),
            catalog: LiveProviderCatalog(
                models: DiarizationModels(directory: paths.models),
                transcriptionModel: .breeze(in: paths.models), llmModel: .qwen35(in: paths.models)))
        guard case .ready(let pipeline) = try setup.build(AppSettings()) else {
            Issue.record("the app is not set up: keys or the speaker model are missing")
            return
        }
        let meeting = try await library.create(Recording(
            micTrack: mic, remoteTrack: remote, highlights: [],
            metadata: MeetingMetadata(title: "Recording", startedAt: Date(), duration: 0)))

        let marks = Box<[(ProcessingStep, Date)]>([])
        let start = Date()
        let done = try await pipeline.process(meeting.id) { step in marks.update { $0.append((step, Date())) } }
        let end = Date()

        let steps = marks.get
        for (index, (step, began)) in steps.enumerated() {
            let finished = index + 1 < steps.count ? steps[index + 1].1 : end
            print(String(format: "BENCH %@ %.1fs", step.rawValue, finished.timeIntervalSince(began)))
        }
        print(String(format: "BENCH total %.1fs", end.timeIntervalSince(start)))
        print("BENCH status \(done.status) title \(done.metadata.title) separated \(String(describing: done.separatedTrack))")
        print("BENCH speakers \(done.speakers.count) utterances \(done.utterances.count) characters \(done.utterances.reduce(0) { $0 + $1.text.count }) paragraphs \(done.outputs.cleaned?.paragraphs.count ?? 0)")
        print("BENCH document \(root.path)")
        #expect(done.status == .completed)
    }
}
