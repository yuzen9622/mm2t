import Foundation
import MM2TCore
import Testing

struct CollabTests {
    @Test(arguments: [
        (#"{"op":"create","id":"plan-1","kind":"gantt","title":"時程","source":"command"}"#,
         CollabOp.create(id: "plan-1", kind: .gantt, title: "時程", source: .command)),
        (#"{"op":"set","id":"poll-1","field":"closed","value":true}"#,
         .set(id: "poll-1", field: .closed, value: .bool(true))),
        (#"{"op":"upsertItem","id":"plan-1","collection":"tasks","item":{"id":"t1","name":"試跑","start":"2026-11-20","end":"2026-11-21","dependsOn":["t0"],"progress":0.5}}"#,
         .upsertItem(id: "plan-1", collection: .tasks, item: ["id": .string("t1"), "name": .string("試跑"), "start": .string("2026-11-20"), "end": .string("2026-11-21"), "dependsOn": .array([.string("t0")]), "progress": .number(0.5)])),
        (#"{"op":"removeItem","id":"plan-1","collection":"tasks","itemId":"t1"}"#,
         .removeItem(id: "plan-1", collection: .tasks, itemId: "t1")),
        (##"{"op":"appendText","id":"doc","field":"markdown","text":"# 紀錄\n\n"}"##,
         .appendText(id: "doc", field: .markdown, text: "# 紀錄\n\n")),
        (#"{"op":"replaceText","id":"doc","field":"markdown","text":"新紀錄"}"#,
         .replaceText(id: "doc", field: .markdown, text: "新紀錄")),
        (#"{"op":"done","id":"plan-1"}"#, .done(id: "plan-1")),
        (#"{"op":"remove","id":"plan-1"}"#, .remove(id: "plan-1")),
    ]) func operationGolden(test: (String, CollabOp)) throws {
        let (wire, expected) = test
        let bytes = Data(wire.utf8)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(CollabOp.self, from: bytes) == expected)
        let encoded = try JSONEncoder().encode(expected)
        #expect(try decoder.decode(CollabJSON.self, from: encoded) == decoder.decode(CollabJSON.self, from: bytes))
    }

    @Test func componentRoundTripPreservesKindData() throws {
        let wire = Data(#"{"id":"a","kind":"actions","title":"待辦","source":"suggestion","building":false,"createdAt":"2026-11-20T12:00:00Z","updatedAt":"2026-11-20T12:01:00Z","rev":2,"rows":{"r":{"id":"r","task":"寄信","status":"open"}},"rowsOrder":["r"]}"#.utf8)
        let decoder = JSONDecoder()
        let component = try decoder.decode(CollabComponent.self, from: wire)
        #expect(component.id == "a")
        #expect(component.kind == .actions)
        #expect(component.source == .suggestion)
        #expect(component.fields["rowsOrder"] == .array([.string("r")]))
        #expect(try decoder.decode(CollabJSON.self, from: JSONEncoder().encode(component)) == decoder.decode(CollabJSON.self, from: wire))
    }

    @Test func parserAcrossAllCharacterBoundariesAndMalformedLines() {
        let text = "  ```json\r\n \n{\"op\":\"done\",\"id\":\"first\"}\r\nno\n"
            + #"{"op":"upsertItem","id":"first","collection":"rows","item":{}}"# + "\n"
            + #"{"op":"set","id":"first","field":"closed","value":"true"}"# + "\n"
            + #"{"op":"done","id":"INVALID"}"# + "\n"
            + #"{"op":"set","id":"first","field":"unknown","value":true}"# + "\n```\n"
            + #"{"op":"remove","id":"last"}"#
        for cut in text.indices {
            var parser = CollabOpStreamParser()
            var ops = parser.feed(String(text[..<cut]))
            ops += parser.feed(String(text[cut...]))
            #expect(ops == [.done(id: "first")])
            #expect(parser.finish() == [.remove(id: "last")])
            #expect(parser.rejectedLines == 5)
            #expect(parser.finish().isEmpty)
        }
    }

    @Test func parserRejectsInvalidItemFieldsWithoutDiscardingOtherLines() {
        var parser = CollabOpStreamParser()
        let bad = [
            #"{"op":"upsertItem","id":"board","collection":"nodes","item":{"id":"n","shape":"circle"}}"#,
            #"{"op":"upsertItem","id":"plan","collection":"tasks","item":{"id":"t","start":"tomorrow"}}"#,
            #"{"op":"upsertItem","id":"plan","collection":"tasks","item":{"id":"t","progress":1.5}}"#,
            #"{"op":"upsertItem","id":"actions","collection":"rows","item":{"id":"r","status":"closed"}}"#,
        ]
        let ok = #"{"op":"upsertItem","id":"plan","collection":"tasks","item":{"id":"t","progress":1}}"#
        let parsed = parser.feed((bad + [ok, ""]).joined(separator: "\n"))
        #expect(parsed == [.upsertItem(id: "plan", collection: .tasks, item: ["id": .string("t"), "progress": .number(1)])])
        #expect(parser.rejectedLines == 4)
    }

    @Test func suggestionsUseCaptionTimeCountVisibilityAndCooldown() {
        let start = Date(timeIntervalSince1970: 1000)
        func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }
        var policy = SuggestionPolicy(now: start)
        func ask(_ offset: TimeInterval, on: Bool = true, shown: Bool = false) -> Bool {
            policy.shouldAsk(now: at(offset), captionsOn: on, cardVisible: shown)
        }
        func offer(_ title: String) -> Bool { policy.offer(kind: .document, title: title) }
        policy.record(39)
        #expect(!ask(20))
        policy.record(1)
        #expect(!ask(19.99))
        #expect(!ask(20, on: false))
        #expect(!ask(20, shown: true))
        #expect(ask(20))
        #expect(!ask(40))
        policy.record(40)
        policy.closed(at: at(35))
        #expect(!ask(94.99))
        #expect(ask(95))
        policy.remember(kind: .document, title: "api 規格")
        #expect(!offer(" ＡＰＩ  規格"))
        #expect(offer("  Project   Plan "))
        #expect(!offer("project plan"))
    }

    @Test func suggestionsRememberSimilarTitlesWithinTheirKind() {
        var policy = SuggestionPolicy(now: Date())
        func offer(kind: CollabComponentKind, title: String) -> Bool { policy.offer(kind: kind, title: title) }
        #expect(offer(kind: .document, title: "會議摘要"))
        policy.closed(at: Date())
        #expect(!offer(kind: .document, title: "建立會議摘要"))
        #expect(!offer(kind: .document, title: "摘要"))
        policy.remember(kind: .poll, title: "午餐地點投票")
        #expect(!offer(kind: .poll, title: "晚餐地點投票"))
        #expect(offer(kind: .poll, title: "下次開會時間"))
        #expect(offer(kind: .whiteboard, title: "會議摘要"))
        policy.remember(kind: .document, title: "abcde")
        #expect(!offer(kind: .document, title: "abcdf")) // 3 of 5 bigrams
        #expect(offer(kind: .document, title: "abcef"))
        #expect(offer(kind: .poll, title: "甲"))
        #expect(offer(kind: .poll, title: "乙"))
    }

    @Test func hoveringPreservesTheUnusedPartOfTheFifteenSeconds() {
        let start = Date(timeIntervalSince1970: 0)
        func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }
        var card = SuggestionPolicy.Card(now: start)
        #expect(card.progress(at: at(0)) == 1)
        #expect(card.progress(at: at(7.5)) == 0.5)
        card.hover(true, now: at(7.5))
        card.hover(true, now: at(27.5))
        #expect(card.progress(at: at(31.5)) == 0.5)
        card.hover(false, now: at(32.5))
        #expect(card.timeLeft(at: at(39)) == 1)
        #expect(card.progress(at: at(40)) == 0)
    }

    @Test func liveUpdateSelectsOnlyEligibleKindsAndRunsOldestFirst() {
        let now = Date(timeIntervalSince1970: 1000)
        func candidate(_ id: String, _ kind: CollabComponentKind, _ age: TimeInterval, _ size: Int) -> LiveUpdatePolicy.Candidate {
            .init(id: id, kind: kind, lastUpdated: now.addingTimeInterval(-age), newCharacters: size)
        }
        let excluded = [candidate("too-young", .document, 89.99, 999), candidate("too-short", .actions, 999, 199),
                        candidate("poll", .poll, 200, 900), candidate("html", .experimental, 200, 900)]
        #expect(LiveUpdatePolicy.next(excluded, now: now, inFlight: false) == nil)
        let candidates = excluded + [candidate("gantt", .gantt, 90, 200), candidate("board", .whiteboard, 91, 200)]
        #expect(LiveUpdatePolicy.next(candidates, now: now, inFlight: false) == "board")
        #expect(LiveUpdatePolicy.next(candidates, now: now, inFlight: true) == nil)
        for kind in [CollabComponentKind.whiteboard, .gantt, .actions, .document] {
            #expect(LiveUpdatePolicy.next([candidate("edge", kind, 90, 200)], now: now, inFlight: false) == "edge")
        }
    }
}

struct CollabParserLimitTests {
    @Test func overlongLineIsDiscardedOnceAndParsingResumes() {
        var parser = CollabOpStreamParser()
        let limit = 512 * 1024
        #expect(parser.feed(String(repeating: "a", count: limit)).isEmpty)
        #expect(parser.rejectedLines == 0)
        #expect(parser.feed("é").isEmpty)
        #expect(parser.feed(String(repeating: "z", count: limit)).isEmpty)
        #expect(parser.rejectedLines == 1)
        #expect(parser.feed("\r\n" + #"{"op":"done","id":"after"}"# + "\r\n") == [.done(id: "after")])
        #expect(parser.finish().isEmpty)
        #expect(parser.rejectedLines == 1)
    }

    @Test func oneCharacterFragmentsScaleLinearlyFrom200KBTo2MB() {
        func fragments(_ length: Int) -> [String] {
            let header = #"{"op":"appendText","id":"doc","field":"markdown","text":""#
            let line = header + String(repeating: "x", count: length - header.utf8.count - 3) + "\"}\n"
            return line.map(String.init)
        }
        let smallLine = fragments(200_000)
        let largeLine = fragments(500_000)
        func measure(_ fragments: [String], lines: Int) -> Double {
            var parser = CollabOpStreamParser()
            var parsed = 0
            let elapsed = ContinuousClock().measure {
                for _ in 0..<lines {
                    for fragment in fragments { parsed += parser.feed(fragment).count }
                }
            }
            #expect(parsed == lines)
            #expect(parser.rejectedLines == 0)
            let duration = elapsed.components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
        _ = measure(smallLine, lines: 1)
        var small: [Double] = []
        var large: [Double] = []
        for _ in 0..<5 { small.append(measure(smallLine, lines: 1)); large.append(measure(largeLine, lines: 4)) }
        let ratio = large.sorted()[2] / small.sorted()[2]
        print("Collab parser 200 KB: \(small) s; 2 MB: \(large) s; median ratio: \(ratio)")
        #expect(ratio < 15)
    }
}

@Test func drawnOpsRoundTripAndRejectInvalidPayloads() throws {
    let decoder = JSONDecoder()
    let edits: [CollabOp] = [
        .setElement(id: "board", elementId: "mark", shape: .diamond, text: "Updated", strokeColor: "#A533de", backgroundColor: nil),
        .removeElement(id: "board", elementId: "mark"),
    ]
    for edit in edits {
        #expect(try decoder.decode(CollabOp.self, from: JSONEncoder().encode(edit)) == edit)
        #expect(edit.targeting("other").id == "other")
    }
    for json in [
        #"{"op":"setElement","id":"board","elementId":"mark","strokeColor":"red"}"#,
        #"{"op":"setElement","id":"board","elementId":"mark","shape":"arrow"}"#,
        #"{"op":"setElement","id":"board","elementId":"mark","text":null}"#,
        #"{"op":"removeElement","id":"board","elementId":""}"#,
    ] {
        #expect(throws: DecodingError.self) { try decoder.decode(CollabOp.self, from: Data(json.utf8)) }
    }
}
