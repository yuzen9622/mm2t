import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TApp

@MainActor @Suite struct AssistantFixtureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_WRITE_ASSISTANT_FIXTURE"] != nil))
    func writeSyntheticLibrary() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MM2T_WRITE_ASSISTANT_FIXTURE"])
        let target = URL(filePath: path)
        guard path.hasPrefix("/Volumes/KINGSTON/"), !FileManager.default.fileExists(atPath: path) else {
            throw AssistantQueryError.invalid("Fixture target must be a new directory on KINGSTON")
        }
        let world = try World()
        try await world.app.voiceprints.enrollUser(name: "測試使用者", embeddings: [])
        for number in 0..<12 {
            var meeting = try await world.recordedMeeting(title: "合成驗證 \(number + 1)")
            meeting.metadata.startedAt = Date().addingTimeInterval(-Double(number) * 86_400)
            var items: [Summary.ActionItem] = []
            var utterances: [Utterance] = []
            for task in 0..<(number == 11 ? 3 : 4) {
                let uid = UtteranceID("assignment\(task)")
                let text = "寄送第 \(number * 4 + task + 1) 份報價單"
                utterances.append(.init(id: uid, speaker: SpeakerID("r1"), range: .init(start: Double(task * 4), end: Double(task * 4 + 3)),
                    isOverlapping: false, text: "請你\(text)，期限是這週五。", words: []))
                items.append(.init(text: text, owner: .me, sources: [uid],
                    due: ActionDeadline.parse(AssistantEngine.day(Date().addingTimeInterval(3 * 86_400)), timeZoneIdentifier: TimeZone.current.identifier)))
            }
            items.append(.init(text: "其他人的工作，不應列為我的", owner: SpeakerID("r1"), sources: [utterances[0].id]))
            meeting.utterances = utterances
            meeting.outputs.summary = Summary(decisions: [], discussionPoints: [], actionItems: items)
            meeting.outputs.cleaned = nil
            meeting.status = .completed
            try await world.library.save(meeting)
        }
        try FileManager.default.copyItem(at: world.root, to: target)
        try Data("synthetic-assistant-fixture-v1".utf8).write(to: target.appending(path: "assistant-fixture.txt"))
        let questions = ["我有哪些沒做、會議交代我做的事情？", "第二項是誰交代的？", "只留本週要完成的，按期限排序。"]
        try JSONEncoder().encode(questions).write(to: target.appending(path: "scenario.json"))
    }
}
