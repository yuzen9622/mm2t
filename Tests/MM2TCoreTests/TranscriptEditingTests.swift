import Foundation
import Testing
@testable import MM2TCore

@Suite struct TranscriptEditingTests {
    @Test func aCorrectedUtteranceAndParagraphAreSaved() async throws {
        let world = try await World()
        let meeting = try await world.processed()
        let editing = TranscriptEditing(library: world.library)

        try await editing.edit(meeting.utterances[1].id, in: meeting.id, to: " 我覺得不行 ")
        try await editing.editCleaned(paragraph: 0, in: meeting.id, to: "Hi team")
        let saved = try await world.library.meeting(meeting.id)

        #expect(saved.utterances[1].text == "我覺得不行")
        #expect(saved.utterances[1].words == meeting.utterances[1].words)
        #expect(saved.outputs.cleaned?.paragraphs[0].text == "Hi team")
        await #expect(throws: TranscriptEditError.unknownParagraph(99)) {
            try await editing.editCleaned(paragraph: 99, in: meeting.id, to: "x")
        }
    }

    @Test func aMeetingBeingProcessedCannotBeEdited() async throws {
        let world = try await World()
        let meeting = try await world.record()
        await #expect(throws: TranscriptEditError.meetingIsProcessing) {
            try await TranscriptEditing(library: world.library).rename(meeting.id, to: "x")
        }
    }

    @Test(arguments: [
        ("我們用酷柏內提斯部署", "我們用 Kubernetes 部署", ["Kubernetes"]),
        ("請蘇里確認", "請舒立確認", ["舒立"]),
        ("deploy to kubernets today", "deploy to kubernetes today", ["kubernetes"]),
        ("我們在開會", "我們再開會", []),
        ("好的，謝謝", "好的。謝謝", []),
        ("嗯那個我覺得可以", "我覺得可以", []),
        ("短", "這是一段被整個重寫而且非常非常長的句子，不應該被當成一個詞彙", []),
    ])
    func correctionsTeachTheReplacedTerm(old: String, new: String, terms: [String]) {
        #expect(VocabularyLearning.terms(correcting: old, to: new) == terms)
    }

    @Test func subtitlesCutLongLinesAndShareTheTimeByLength() async throws {
        let cues = Subtitles.cues("第一句話到這裡。第二句話比較長一點，後面還有，然後繼續說下去直到超過一行的長度為止", in: TimeRange(start: 10, end: 20))
        #expect(cues.allSatisfy { $0.text.count <= Subtitles.maxCueCharacters })
        #expect(cues.first?.range.start == 10)
        #expect(cues.last?.range.end == 20)
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.range.end == $1.range.start })
        #expect(Subtitles.timestamp(3725.5) == "01:02:05,500")
    }

    @Test func srtNumbersCuesAndNamesSpeakers() async throws {
        let world = try await World()
        let meeting = try await world.processed()
        let srt = try #require(Subtitles.srt(meeting, view: .raw) { $0 == .me ? "Me" : $0.rawValue })

        #expect(srt.hasPrefix("1\n00:00:00,500 --> "))
        #expect(srt.contains("r2: 我覺得可以"))
        #expect(Subtitles.srt(meeting, view: .summary) { $0.rawValue } == nil)
    }

    @Test func findsTheCallLinkAmongEventText() {
        #expect(MeetingLink.find(in: ["", "Room 4", "Join: https://meet.google.com/abc-defg-hij now"])?.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(MeetingLink.find(in: ["https://us02web.zoom.us/j/123?pwd=x"])?.host() == "us02web.zoom.us")
        #expect(MeetingLink.find(in: ["https://example.com/agenda", "see notzoom.us.evil.com"]) == nil)
    }
}
