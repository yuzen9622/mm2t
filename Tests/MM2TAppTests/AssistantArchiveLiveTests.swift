import Foundation
@testable import MM2TCore
import MM2TLocal
import Testing
@testable import MM2TApp

@Suite struct AssistantArchiveLiveTests {
    /// The opt-in archive is read-only. Index and voiceprint state belong to this test run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_ASSISTANT_ARCHIVE"] != nil),
          arguments: [false, true])
    func listsEveryMeetingWithItsSource(reviewContent: Bool) async throws {
        let env = ProcessInfo.processInfo.environment
        let library = MeetingLibrary(root: URL(filePath: try #require(env["MM2T_ASSISTANT_ARCHIVE"])))
        let meetings = try await library.list()
        try #require(meetings.count > 8)
        let work = URL(filePath: try #require(env["MM2T_ASSISTANT_SCRATCH"])).appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        let index = MeetingIndex(fileURL: work.appending(path: "search.sqlite"))
        try await index.rebuild(from: meetings)
        let engine = AssistantEngine(library: library, index: index, voiceprints: try VoiceprintStore(fileURL: work.appending(path: "voices.json")))
        let provider = LocalLLM(model: .qwen35(in: URL(filePath: try #require(env["MM2T_FOLDER_MODEL_ROOT"]))))
        var answer = "", cited = Set<MeetingID>(), counts = [Int](), finished = false
        var sources: [AssistantSource] = []
        let question = reviewContent
            ? "請逐篇檢查全部會議，每篇從逐字稿原封不動摘錄一句，用「」標出原文，不要改寫。每篇都要附上來源。"
            : "請列出全部會議的完整標題，每篇附上來源，並告訴我總篇數。"
        for await event in engine.events(question: question, provider: provider) {
            switch event {
            case .answerDelta(let chunk): answer += chunk
            case .toolFinished(_, let result): counts.append(result.count)
            case .finished(let result): sources = result; cited = Set(result.map(\.meeting)); finished = true
            case .failed(let reason): Issue.record("Local archive evaluation failed: \(reason)")
            default: break
            }
        }
        let titles = meetings.filter { answer.contains($0.metadata.title) }.count
        print("archive=\(meetings.count) toolCounts=\(counts) exactTitles=\(titles) distinctCitations=\(cited.count)")
        if reviewContent {
            let rows = answer.components(separatedBy: "\n- ")
            let checked = sources.filter { source in
                guard let meeting = meetings.first(where: { $0.id == source.meeting }),
                      let row = rows.first(where: { $0.contains("[\(source.id)]") }) else { return false }
                let utterances = meeting.utterances.map(\.text).joined(separator: "\n")
                guard let uid = source.utterance, let utterance = meeting.utterance(uid) else { return false }
                return source.time == utterance.range.start && source.quote == utterance.text
                    && row.contains("「" + utterance.text + "」") && utterances.contains(utterance.text)
            }.count
            print("verbatimExcerptInCorrectMeeting=\(checked)/\(meetings.count)")
            #expect(checked == meetings.count)
        }
        #expect(finished)
        #expect(titles == meetings.count)
        #expect(cited.count == meetings.count)
    }

    /// Replay the reported request against an opt-in archive with an isolated copy of its placements.
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_ASSISTANT_FOLDER_SNAPSHOT"] != nil))
    func reviewsCurrentFolderPlacementsBeforeConfirmation() async throws {
        let env = ProcessInfo.processInfo.environment
        let world = try World()
        let library = MeetingLibrary(root: URL(filePath: try #require(env["MM2T_ASSISTANT_ARCHIVE"])))
        let snapshot = URL(filePath: try #require(env["MM2T_ASSISTANT_FOLDER_SNAPSHOT"]))
        let copy = world.root.appending(path: "review-folders.json")
        try FileManager.default.copyItem(at: snapshot, to: copy)
        let before = try Data(contentsOf: copy)
        let folders = try MeetingFolders(file: copy)
        let meetings = try await library.list()
        try #require(!meetings.isEmpty)
        try await world.app.searchIndex.rebuild(from: meetings)
        let engine = AssistantEngine(library: library, index: world.app.searchIndex, voiceprints: world.app.voiceprints, folders: folders)
        let provider = LocalLLM(model: .qwen35(in: URL(filePath: try #require(env["MM2T_FOLDER_MODEL_ROOT"]))))
        var coverage = "", receivedPreview = false, finished = false
        var proposedIDs: [MeetingID] = []
        var filingStep: UUID?
        for await event in engine.events(question: "幫我整理資料夾", provider: provider) {
            switch event {
            case .toolStarted(let id, .filing, _): filingStep = id
            case .toolFinished(let id, let result) where id == filingStep: coverage = result.coverage
            case .filed(_, let proposals):
                receivedPreview = true
                proposedIDs = proposals.flatMap(\.meetings)
            case .finished: finished = true
            case .failed(let reason): Issue.record("Folder review failed: \(reason)")
            default: break
            }
        }
        print("Folder replay: \(coverage)")
        #expect(receivedPreview && finished)
        #expect(coverage.contains("Checked \(meetings.count) eligible meetings"))
        #expect(Set(proposedIDs).isSubset(of: Set(meetings.map(\.id))))
        #expect(Set(proposedIDs).count == proposedIDs.count)
        #expect(try Data(contentsOf: copy) == before)

        for question in ["幫我看整理一下要有哪些資料夾？", "請整理這場會議的重點"] {
            let mode = try await FolderOrganizer.previewMode(provider: provider, question: question)
            #expect(mode == nil)
        }
        let onlyUnfiled = try await FolderOrganizer.previewMode(provider: provider, question: "幫我整理未分類會議")
        #expect(onlyUnfiled == .unfiledOnly)
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_FOLDER_MODEL_ROOT"] != nil))
    func distinguishesFinalDecisionFromProposalAndRespectsSelectedMeetings() async throws {
        let world = try World()
        func record(_ title: String, text: String) async throws -> Meeting {
            var meeting = try await world.recordedMeeting(title: title)
            meeting.utterances = [.init(id: UtteranceID("final"), speaker: .me, range: .init(start: 0, end: 3),
                                        isOverlapping: false, text: text, words: [])]
            meeting.outputs = LLMOutputs()
            try await world.library.save(meeting)
            return meeting
        }
        let amended = try await record("甲組交付", text: "初稿的交付代碼是 ALPHA-104。主席否決，最終定案改用 BRAVO-735。")
        let pending = try await record("乙組交付", text: "提案使用 CHARLIE-802，但今天沒有表決，最終交付代碼尚未決定。")
        let outside = try await record("丙組交付", text: "已確定交付代碼 DELTA-998。")
        try await world.app.searchIndex.rebuild(from: [amended, pending, outside])
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex,
                                     voiceprints: world.app.voiceprints, folders: world.app.folders)
        let root = try #require(ProcessInfo.processInfo.environment["MM2T_FOLDER_MODEL_ROOT"])
        let provider = LocalLLM(model: .qwen35(in: URL(filePath: root)))
        var answer = "", sources: [AssistantSource] = [], steps: [String] = []
        for await event in engine.events(question: "逐篇核對選取的兩場會議，只列各場最終定案的交付代碼，尚未定案就寫「未定案」。不要列出草案代碼。", provider: provider, scope: [amended.id, pending.id]) {
            switch event {
            case .answerDelta(let chunk): answer += chunk
            case .finished(let result): sources = result
            case .toolFinished(_, let result): steps.append(result.coverage)
            case .failed(let failure): Issue.record("Synthetic decision review failed: \(failure)")
            default: break
            }
        }
        print("Synthetic decision review: \(steps) / \(answer)")
        #expect(answer.contains("BRAVO-735"))
        #expect(answer.contains("未定案"))
        #expect(!answer.contains("ALPHA-104"))
        #expect(!answer.contains("CHARLIE-802"))
        #expect(!answer.contains("DELTA-998"))
        #expect(Set(sources.map(\.meeting)) == [amended.id, pending.id])
        #expect(world.app.folders.folders.isEmpty)
    }
}
