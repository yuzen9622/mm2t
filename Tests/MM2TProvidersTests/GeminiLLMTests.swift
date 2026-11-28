import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

extension StubServer.Request {
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
    var geminiInput: String {
        let contents = json["contents"] as? [[String: Any]]
        let parts = contents?.first?["parts"] as? [[String: Any]]
        return parts?.first?["text"] as? String ?? ""
    }
    var geminiSystem: String {
        let system = json["systemInstruction"] as? [String: Any]
        return (system?["parts"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    }
    /// Utterance ids in the transcript lines of the prompt, in order.
    var utteranceIDs: [String] {
        // Lines before "逐字稿：" are the glossary and the read-only context, not what the model must clean.
        let data = geminiInput.components(separatedBy: "</data>").first ?? geminiInput
        let transcript = data.range(of: "逐字稿：\n", options: .backwards).map { data[$0.upperBound...] } ?? Substring(data)
        return transcript.split(separator: "\n").compactMap { line in
            guard let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]") else { return nil }
            return String(line[line.index(after: open)..<close])
        }
    }
}

@Suite struct GeminiLLMTests {
    let transcript = LLMTranscript(utterances: [
        utterance("u1", "me", 0, "嗯那個我們今天要討論那個 Kubernetes 的 migration"),
        utterance("u2", "r1", 5, "對我覺得禮拜三，不對，禮拜四之前要先把 cluster 升級", highlighted: true),
        utterance("u3", "r2", 12, "好那我來負責寫 migration plan"),
    ])

    func gemini(_ server: StubServer, limits: GeminiLLM.Limits = .init()) -> GeminiLLM {
        GeminiLLM(apiKey: "AIza-secret", session: server.session, limits: limits)
    }

    @Test func sendsAStructuredOutputRequestToTheModel() async throws {
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"paragraphs":[]}"#))
        _ = try await gemini(server).cleanTranscript(transcript)

        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        #expect(request.headers["x-goog-api-key"] == "AIza-secret")
        #expect(!request.url.absoluteString.contains("AIza-secret"))
        let config = try #require(request.json["generationConfig"] as? [String: Any])
        #expect(config["responseMimeType"] as? String == "application/json")
        let schema = try #require(config["responseJsonSchema"] as? [String: Any])
        let items = ((schema["properties"] as? [String: Any])?["paragraphs"] as? [String: Any])?["items"] as? [String: Any]
        let speaker = (items?["properties"] as? [String: Any])?["speaker"] as? [String: Any]
        #expect(speaker?["enum"] as? [String] == ["me", "r1", "r2"])
    }

    @Test func promptsBindTheModelToSpeakerTokensSourcesAndTheTranscriptLanguage() async throws {
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"paragraphs":[]}"#))
        _ = try await gemini(server).cleanTranscript(transcript)
        let request = try #require(server.requests.first)

        #expect(request.geminiSystem.contains("{{speaker:代號}}"))
        #expect(request.geminiInput.contains("sources"))
        #expect(request.geminiInput.contains("保留它的原始語言"))
        #expect(request.geminiInput.contains("精簡但不摘要"))
        #expect(request.geminiInput.contains("[u2] {{speaker:r1}} 00:00:05 對我覺得禮拜三"))
        #expect(request.geminiInput.contains("(重點) [u2]"))
    }

    @Test(arguments: [false, true])
    func translatedParagraphGetsOneIsolatedRepair(repairSucceeds: Bool) async throws {
        let english = "So how should we think about these findings? What does this all mean?"
        let mixed = "他這個翻譯真的不太 specific。"
        let translated = "那麼我們該如何看待這些發現？這一切意味著什麼？"
        let repaired = "How should we think about these findings? What does this all mean?"
        let lines = [utterance("u15", "r1", 187, english), utterance("u16", "me", 200, mixed)]
        let server = StubServer { request in
            let data: [[String: Any]] = request.utteranceIDs.map { id in
                if id == "u16" { return ["sources": [id], "speaker": "me", "text": mixed] }
                let fixed = repairSucceeds && request.utteranceIDs == ["u15"]
                return ["sources": [id], "speaker": "r1", "text": fixed ? repaired : translated]
            }
            let json = try! JSONSerialization.data(withJSONObject: ["paragraphs": data])
            return .status(200, Fixture.gemini(String(decoding: json, as: UTF8.self)))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: lines))
        #expect(server.requests.map(\.utteranceIDs) == [["u15", "u16"], ["u15"]])
        #expect(result.paragraphs.map(\.text) == [repairSucceeds ? repaired : english, mixed])
        #expect(result.paragraphs.flatMap(\.sources) == lines.map(\.id))
    }

    @Test(arguments: ["missing", "uncited", "otherSpeaker"])
    func unreliableSourcesAreRebuiltBySpeaker(_ failure: String) async throws {
        let english = "What does this discovery mean for the rest of the study?"
        let mixed = "他這個翻譯真的不太 specific。"
        let lines = [utterance("u1", "r1", 0, english), utterance("u2", "me", 4, mixed)]
        let server = StubServer { request in
            let ids = request.utteranceIDs
            let sources: [String]
            if ids.count == 1 { sources = ids }
            else if failure == "missing" { sources = ["u1"] }
            else if failure == "uncited" { sources = [] }
            else { sources = ids }
            let mic = ids == ["u2"]
            let row: [String: Any] = ["speaker": mic ? "me" : "r1", "sources": sources, "text": mic ? mixed : english]
            let json = try! JSONSerialization.data(withJSONObject: ["paragraphs": [row]])
            return .status(200, Fixture.gemini(String(decoding: json, as: UTF8.self)))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: lines))
        #expect(server.requests.map(\.utteranceIDs) == [["u1", "u2"], ["u1"], ["u2"]])
        #expect(result.paragraphs.map(\.speaker) == lines.map(\.speaker))
        #expect(result.paragraphs.map(\.text) == [english, mixed])
    }

    @Test(arguments: [true, false])
    func preservesMultilingualShortTurnsWhenCleanupCollapsesThem(citesEverything: Bool) async throws {
        let texts = ["どうぞよろしくお願いします。", "等一下。", "他為什麼？", "Hello。到了。", "なんで？"]
        let lines = texts.enumerated().map { index, text in utterance("u\(index + 1)", "me", Double(index), text) }
        let server = StubServer { request in
            let row: [String: Any] = ["speaker": "me", "sources": citesEverything ? request.utteranceIDs : [],
                                      "text": "好的，請多指教。"]
            let json = try! JSONSerialization.data(withJSONObject: ["paragraphs": [row]])
            return .status(200, Fixture.gemini(String(decoding: json, as: UTF8.self)))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: lines))
        #expect(result.paragraphs.map(\.text) == texts)
        #expect(result.paragraphs.flatMap(\.sources) == lines.map(\.id))
        #expect(server.requests.count == 2)
    }

    @Test(arguments: ["欸。", "欸？"])
    func distinguishesAHesitationFromAQuestion(_ opening: String) async throws {
        let edited = "你明天才回來嗎？"
        let original = opening + "你、你明天才回來嗎？"
        let line = utterance("u1", "me", 0, original)
        let server = StubServer { _ in
            .status(200, Fixture.gemini(#"{"paragraphs":[{"speaker":"me","text":"你明天才回來嗎？","sources":["u1"]}]}"#))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: [line]))
        #expect(result.paragraphs.map(\.text) == [opening == "欸。" ? edited : original])
    }

    @Test func retainsAQuestionAfterAnInstruction() async throws {
        let source = "請畫出登入頁面。它要怎麼觸發啊？我發現它開不了。"
        let lines = [utterance("u1", "me", 0, source)]
        let server = StubServer { request in
            let text = request.geminiInput.contains("本次僅編輯所附原句")
                ? "請畫出登入頁面。它要如何觸發？我發現它開不了。"
                : "請畫出登入頁面的觸發圖示。目前開不了。"
            let row: [String: Any] = ["speaker": "me", "text": text, "sources": ["u1"]]
            let data = try! JSONSerialization.data(withJSONObject: ["paragraphs": [row]])
            return .status(200, Fixture.gemini(String(decoding: data, as: UTF8.self)))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: lines))
        #expect(result.paragraphs.map(\.text) == ["請畫出登入頁面。它要如何觸發？我發現它開不了。"])
    }

    @Test func rejectsTranslationOfChineseAroundAnEnglishTerm() {
        let source = "specific. 他這個，這個翻譯真的不太"
        #expect(LLMTasks.changedLanguage(source: source, output: "Specific. His translation really is not very..."))
        #expect(!LLMTasks.changedLanguage(source: source, output: "他的翻譯不太 specific。"))
        #expect(LLMTasks.changedLanguage(source: source, output: "他的翻譯不太具體。"))
    }

    @Test func rejectsAnEnglishPassageBorrowedFromThePreviousSpeaker() async throws {
        let first = "We asked the model to read stories about emotions."
        let second = "The next experiment measured behavior."
        let lines = [utterance("u1", "me", 0, first), utterance("u2", "r1", 1, second)]
        let server = StubServer { request in
            var rows: [[String: Any]] = []
            if request.utteranceIDs.contains("u1") { rows.append(["speaker": "me", "sources": ["u1"], "text": first]) }
            rows.append(["speaker": "r1", "sources": ["u2"], "text": first + " " + second])
            let data = try! JSONSerialization.data(withJSONObject: ["paragraphs": rows])
            return .status(200, Fixture.gemini(String(decoding: data, as: UTF8.self)))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: lines))
        #expect(result.paragraphs.map(\.text) == [first, second])
    }

    @Test func acceptsJoinedFragmentsWithAStutter() async throws {
        let lines = [utterance("u1", "me", 0, "反"), utterance("u2", "me", 1, "正都，都一樣。哎。")]
        let server = StubServer { _ in
            .status(200, Fixture.gemini(#"{"paragraphs":[{"speaker":"me","text":"反正都一樣。","sources":["u1","u2"]}]}"#))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: lines))
        #expect(result.paragraphs.map(\.text) == ["反正都一樣。"])
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [("不同會員的 record、records。", "不同會員的 records。"),
                      ("老師在比較 record、records。", "老師在比較 record、records。")])
    func distinguishesAnEnglishRestartFromAWordComparison(_ text: String, _ expected: String) async throws {
        let lines = [utterance("u1", "me", 0, text)]
        let server = StubServer { request in
            if request.geminiInput.contains("唯一要編輯的發言：") {
                let data = try! JSONSerialization.data(withJSONObject: ["text": text])
                return .status(200, Fixture.gemini(String(decoding: data, as: UTF8.self)))
            }
            let row: [String: Any] = ["speaker": "me", "text": text, "sources": ["u1"]]
            let data = try! JSONSerialization.data(withJSONObject: ["paragraphs": [row]])
            return .status(200, Fixture.gemini(String(decoding: data, as: UTF8.self)))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: lines))
        #expect(result.paragraphs.map(\.text) == [expected])
    }

    @Test func keepsEditedRetryWhenOnlyAnIsolatedFillerWasOmitted() async throws {
        let lines = [utterance("u1", "me", 0, "うん。どうぞよろしくお願いします。"),
                     utterance("u2", "me", 3, "等一下。"), utterance("u3", "me", 5, "嗯。")]
        let server = StubServer { request in
            let output = request.geminiInput.contains("本次僅編輯所附原句")
                ? #"{"paragraphs":[{"speaker":"me","text":"どうぞよろしくお願いします。","sources":["u1"]},{"speaker":"me","text":"等一下。","sources":["u2"]}]}"#
                : #"{"paragraphs":[{"speaker":"me","text":"好的。","sources":[]}]}"#
            return .status(200, Fixture.gemini(output))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: lines))
        #expect(result.paragraphs.map(\.text) == ["どうぞよろしくお願いします。", "等一下。"])
        for request in server.requests {
            let prompt = request.geminiSystem + "\n" + request.geminiInput
            let tags = prompt.split(separator: "\n").filter { $0.hasPrefix("<") }
            #expect(tags == ["<role>", "</role>", "<context>", "</context>", "<data>", "</data>",
                             "<task>", "</task>", "<constraints>", "</constraints>", "<output_format>", "<reference>", "</reference>", "</output_format>"])
            let data = try #require(request.geminiInput.components(separatedBy: "</data>").first)
            #expect(data.contains("うん。どうぞよろしくお願いします。"))
        }
        #expect(server.requests.count == 2)
    }

    @Test func repairCanResolveASRWithPrecedingContextAndDropAnOrphanedPreposition() async throws {
        let english = "She showed her boarding pass at the gate."
        let repaired = "她在登機門出示了登機證。"
        let lines = [utterance("u1", "r1", 0, english), utterance("u2", "me", 4, "她在登機門出示了登記證。In")]
        let server = StubServer { request in
            let ids = request.utteranceIDs
            let mic = ids == ["u2"]
            let row: [String: Any] = ["speaker": mic ? "me" : "r1", "text": mic ? repaired : english,
                                      "sources": ids.count > 1 ? [] : ids]
            let json = try! JSONSerialization.data(withJSONObject: ["paragraphs": [row]])
            return .status(200, Fixture.gemini(String(decoding: json, as: UTF8.self)))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: lines))
        let retry = try #require(server.requests.first { $0.utteranceIDs == ["u2"] })
        #expect(retry.geminiInput.components(separatedBy: "逐字稿：\n").first?.contains(english) == true)
        #expect(result.paragraphs.map(\.text) == [english, repaired])
    }

    @Test func overlappingTracksCanUseContextWithoutReassigningTheOtherSpeakersWords() async throws {
        let lines = [utterance("u1", "r1", 0, "She showed her boarding pass at the gate."),
                     utterance("u2", "me", 1, "登記證她在登機門出示，pass、passes。In")]
        let server = StubServer { request in
            let output = request.geminiInput.contains("唯一要編輯的發言：")
                ? #"{"text":"她在登機門出示了 boarding pass。"}"#
                : #"{"paragraphs":[{"speaker":"r1","text":"She showed her boarding pass at the gate.","sources":["u1"]},{"speaker":"me","text":"登記證她在登機門出示，pass、passes。In","sources":["u2"]}]}"#
            return .status(200, Fixture.gemini(output))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: lines))
        let polish = try #require(server.requests.last)
        #expect(polish.geminiInput.contains("唯一要編輯的發言：登記證她在登機門出示，pass、passes。\n"))
        #expect(server.requests.count == 2)
        #expect(result.paragraphs.map(\.sources) == [[lines[0].id], [lines[1].id]])
        #expect(result.paragraphs.map(\.text) == [lines[0].text, "她在登機門出示了 boarding pass。"])
    }

    @Test func reviewsAnUnclearTailUsingBothNeighboursWithoutLosingTheQuestion() async throws {
        let original = "要改期嗎？我們先約星期三下午兩點。哦雨霸一"
        let lines = [utterance("u1", "r1", 0, "你們星期三下午有空嗎？"),
                     utterance("u2", "me", 5, original),
                     utterance("u3", "r1", 10, "兩點我可以。")]
        let expected = "要改期嗎？我們先約星期三下午兩點。〔辨識不清〕"
        let server = StubServer { request in
            if request.geminiInput.contains("待判定的尾句：") {
                return .status(200, Fixture.gemini(#"{"status":"unclear"}"#))
            }
            let rows = lines.map { ["speaker": $0.speaker.rawValue, "text": $0.text, "sources": [$0.id.rawValue]] as [String: Any] }
            let data = try! JSONSerialization.data(withJSONObject: ["paragraphs": rows])
            return .status(200, Fixture.gemini(String(decoding: data, as: UTF8.self)))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: lines))
        #expect(result.paragraphs.map(\.text) == [lines[0].text, expected, lines[2].text])
        let review = try #require(server.requests.last)
        #expect(review.geminiInput.contains(lines[0].text))
        #expect(review.geminiInput.contains(lines[2].text))
    }

    @Test func repairingANumberCanTrimTheClosingFillerButPreservesASeparateReply() async throws {
        let lines = [utterance("u1", "me", 0, "呃，前後側至少都有三，最少都有三十二位。好。"),
                     utterance("u2", "r1", 8, "好。")]
        let server = StubServer { request in
            if request.geminiInput.contains("唯一要編輯的發言：") {
                return .status(200, Fixture.gemini(#"{"text":"前後測至少都有三十二位。"}"#))
            }
            let rows = lines.map { ["speaker": $0.speaker.rawValue, "text": $0.text, "sources": [$0.id.rawValue]] as [String: Any] }
            let data = try! JSONSerialization.data(withJSONObject: ["paragraphs": rows])
            return .status(200, Fixture.gemini(String(decoding: data, as: UTF8.self)))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: lines))
        #expect(result.paragraphs.map(\.text) == ["前後測至少都有三十二位。", "好。"])
    }

    @Test(arguments: [true, false])
    func countHomophoneDependsOnRetrievalContext(retrieving: Bool) async throws {
        let question = retrieving ? "這些資料抓下來要多久？" : "手寫要寫多久？"
        let answer = "要看你的筆速吧。"
        let lines = [utterance("u1", "r1", 0, question), utterance("u2", "me", 5, answer),
                     utterance("u3", "me", 10, "處理六百筆要十幾分鐘。")]
        let server = StubServer { _ in
            let rows = lines.map { ["speaker": $0.speaker.rawValue, "text": $0.text, "sources": [$0.id.rawValue]] as [String: Any] }
            let data = try! JSONSerialization.data(withJSONObject: ["paragraphs": rows])
            return .status(200, Fixture.gemini(String(decoding: data, as: UTF8.self)))
        }
        let result = try await gemini(server).cleanTranscript(.init(utterances: lines))
        #expect(result.paragraphs[1].text == (retrieving ? "要看你的筆數吧。" : answer))
        #expect(result.paragraphs.map(\.sources) == lines.map { [$0.id] })
    }

    @Test func rewriteSendsTheInstructionAndReturnsTheRewrittenText() async throws {
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"text":"想跟您確認一下這份報告的進度。"}"#))
        let text = try await gemini(server).rewrite("這份報告寫得太慢了", instruction: "改得委婉一點")
        let request = try #require(server.requests.first)

        #expect(text == "想跟您確認一下這份報告的進度。")
        #expect(request.geminiInput.contains("改得委婉一點") && request.geminiInput.contains("這份報告寫得太慢了"))
        #expect(request.geminiSystem.contains("繁體中文"))
    }

    @Test func correctionLearningUsesOnlyTheSavedPassageAndRejectsInventedTerms() async throws {
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"corrections":[{"incorrect":"酷柏內提斯","correct":"Kubernetes","category":"technical"},{"incorrect":"蘇里","correct":"舒立","category":"name"},{"incorrect":"原詞","correct":"新增字","category":"technical"}]}"#))
        let pairs = try await gemini(server).vocabularyCorrections(from: "請蘇里用酷柏內提斯部署", to: "請舒立用 Kubernetes 部署")
        #expect(pairs == [.init(incorrect: "酷柏內提斯", correct: "Kubernetes"), .init(incorrect: "蘇里", correct: "舒立")])
        let request = try #require(server.requests.first)
        #expect(request.geminiInput == "修改前：\n請蘇里用酷柏內提斯部署\n\n修改後：\n請舒立用 Kubernetes 部署")
        #expect(request.geminiSystem.contains("短句"))
        #expect(request.geminiSystem.contains("空陣列"))
    }

    @Test func correctionLearningHasNoTwelveTermCap() async throws {
        let items = (0..<15).map { ["incorrect": "Wrong\($0)", "correct": "Right\($0)", "category": "technical"] }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["corrections": items]), as: UTF8.self)
        let server = StubServer(status: 200, body: Fixture.gemini(json))
        let old = items.map { $0["incorrect"]! }.joined(separator: " and ")
        let new = items.map { $0["correct"]! }.joined(separator: " and ")
        #expect(try await gemini(server).vocabularyCorrections(from: old, to: new).count == 15)
    }

    @Test func shortSentenceEditsAreNotANounCategory() async throws {
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"corrections":[{"incorrect":"不行","correct":"可以","category":"sentence"}]}"#))
        await #expect(throws: ProviderError.self) {
            try await gemini(server).vocabularyCorrections(from: "我覺得不行", to: "我覺得可以")
        }
    }

    @Test func anEmptyRewriteIsAMalformedResponse() async throws {
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"text":"  "}"#))
        await #expect(throws: ProviderError.self) { try await gemini(server).rewrite("原文", instruction: "精簡") }
    }

    @Test func cleanedTranscriptKeepsSpeakersAndDropsInventedSources() async throws {
        let output = #"""
        {"paragraphs":[
          {"speaker":"me","text":"我們今天要討論 Kubernetes 的 migration。","sources":["u1"]},
          {"speaker":"r1","text":"我覺得禮拜四之前要先把 cluster 升級。","sources":["u2","u99","u2"]},
          {"speaker":"r2","text":"好，那我來負責寫 migration plan。","sources":["u3"]}]}
        """#
        let server = StubServer(status: 200, body: Fixture.gemini(output, thought: true))
        let cleaned = try await gemini(server).cleanTranscript(transcript)

        #expect(cleaned.paragraphs.map(\.speaker) == [.me, SpeakerID("r1"), SpeakerID("r2")])
        #expect(cleaned.paragraphs[1].sources == [UtteranceID("u2")])
        #expect(cleaned.paragraphs[1].text == "我覺得禮拜四之前要先把 cluster 升級。")
    }

    // MARK: Long meetings

    /// Echoes each prompted utterance back as one paragraph, like a well-behaved model.
    static let echo: StubServer.Handler = { request in
        let paragraphs = request.utteranceIDs.map { #"{"speaker":"r1","text":"clean \#($0)","sources":["\#($0)"]}"# }
        return .status(200, Fixture.gemini(#"{"paragraphs":[\#(paragraphs.joined(separator: ","))]}"#))
    }

    func longMeeting(_ count: Int) -> LLMTranscript {
        LLMTranscript(utterances: (1...count).map { utterance("u\($0)", "r1", Double($0) * 3, String(repeating: "字", count: 100)) })
    }

    @Test func longMeetingIsCleanedInOrderedChunksThatCoverEveryUtterance() async throws {
        let server = StubServer(Self.echo)
        let cleaned = try await gemini(server, limits: .init(cleanChunkCharacters: 1_000)).cleanTranscript(longMeeting(25))

        #expect(server.requests.count == 3)
        #expect(server.requests.allSatisfy { $0.utteranceIDs.count <= 10 })
        #expect(cleaned.paragraphs.flatMap(\.sources) == (1...25).map { UtteranceID("u\($0)") })
    }

    @Test func chunkWhoseOutputHitsTheTokenCapIsSplitAndRetried() async throws {
        let server = StubServer { request in
            request.utteranceIDs.count > 2
                ? .status(200, Fixture.gemini(#"{"paragraphs":[{"speaker":"r1","text":"cut"#, finishReason: "MAX_TOKENS"))
                : Self.echo(request)
        }
        let cleaned = try await gemini(server).cleanTranscript(longMeeting(8))

        #expect(cleaned.paragraphs.flatMap(\.sources) == (1...8).map { UtteranceID("u\($0)") })
        #expect(server.requests.filter { $0.utteranceIDs.count <= 2 }.count == 4)
    }

    @Test func singleUtteranceThatStillOverflowsReportsTheMeetingTooLong() async throws {
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"paragraphs":["#, finishReason: "MAX_TOKENS"))
        await #expect(throws: ProviderError(.gemini, .meetingTooLong)) {
            try await gemini(server).cleanTranscript(longMeeting(1))
        }
    }

    @Test func transcriptBeyondTheInputBudgetIsRefusedWithoutARequest() async throws {
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"digests":[]}"#))
        let llm = gemini(server, limits: .init(maxInputCharacters: 1_000))
        await #expect(throws: ProviderError(.gemini, .meetingTooLong)) { try await llm.digestPerPerson(longMeeting(11)) }
        await #expect(throws: ProviderError(.gemini, .meetingTooLong)) {
            try await llm.summarize(SummaryRequest(transcript: longMeeting(11), prioritized: []))
        }
        #expect(server.requests.isEmpty)
    }

    // MARK: Other tasks

    @Test func namesAreKeptOnlyForSpeakersThatWereAsked() async throws {
        let output = #"""
        {"guesses":[
          {"speaker":"r2","name":" 小華 ","reason":"{{speaker:r1}} 叫他小華"},
          {"speaker":"r1","name":"Alice","reason":"already known"},
          {"speaker":"r2","name":"","reason":"none"}]}
        """#
        let server = StubServer(status: 200, body: Fixture.gemini(output))
        let guesses = try await gemini(server).inferNames(NameInferenceRequest(
            transcript: transcript, unnamedSpeakers: [SpeakerID("r2")], knownNames: [SpeakerID("r1"): "Alice"]))

        #expect(guesses == [NameGuess(speaker: SpeakerID("r2"), name: "小華", reason: "{{speaker:r1}} 叫他小華")])
        let input = try #require(server.requests.first?.geminiInput)
        #expect(input.contains("要推測的說話者：{{speaker:r2}}"))
        #expect(input.contains("{{speaker:r1}} = Alice"))
    }

    @Test func noUnnamedSpeakersMeansNoRequest() async throws {
        let server = StubServer(status: 500, body: "{}")
        let guesses = try await gemini(server).inferNames(NameInferenceRequest(transcript: transcript, unnamedSpeakers: [], knownNames: [:]))
        #expect(guesses.isEmpty && server.requests.isEmpty)
    }

    @Test(arguments: [MeetingOutputLanguage.traditionalChinese, .english])
    func summariesAndDigestsUseTheAppLanguageAndCleanupPreservesEachSource(_ language: MeetingOutputLanguage) async throws {
        let source = language == .traditionalChinese ? "The deadline is Friday." : "交件日期是週五。"
        let input = LLMTranscript(utterances: [
            utterance("u1", "me", 0, source),
            utterance("u2", "r1", 6, "予算の確認 and shipping dates"),
        ], outputLanguage: language)
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"paragraphs":[],"digests":[],"title":"t","headline":"h","decisions":[],"discussionPoints":[],"actionItems":[]}"#))
        let llm = gemini(server)
        _ = try await llm.cleanTranscript(input)
        _ = try await llm.digestPerPerson(input)
        _ = try await llm.summarize(SummaryRequest(transcript: input, prioritized: []))

        let directive = language == .traditionalChinese ? "輸出語言：繁體中文" : "Output language: English"
        let requests = server.requests
        try #require(requests.count == 3)
        #expect(requests[0].geminiInput.contains("保留它的原始語言"))
        #expect(!requests[0].geminiSystem.contains(directive))
        #expect(requests[0].geminiInput.contains("予算の確認 and shipping dates"))
        #expect(requests[1].geminiSystem.contains(directive))
        #expect(requests[2].geminiSystem.contains(directive))
    }

    @Test func digestsFollowFirstSpeakingOrder() async throws {
        let output = #"""
        {"digests":[
          {"speaker":"r2","points":[{"text":"負責寫 migration plan","sources":["u3"]}]},
          {"speaker":"me","points":[{"text":"提出 Kubernetes migration 議題","sources":["u1"]}]}]}
        """#
        let server = StubServer(status: 200, body: Fixture.gemini(output))
        let digests = try await gemini(server).digestPerPerson(transcript)
        #expect(digests.map(\.speaker) == [.me, SpeakerID("r2")])
        #expect(digests[1].points == [SourcedText(text: "負責寫 migration plan", sources: [UtteranceID("u3")])])
    }

    @Test func digestPointsDoNotRepeatTheNameTheyAreGroupedUnder() async throws {
        let output = #"""
        {"digests":[
          {"speaker":"r2","points":[
            {"text":"{{speaker:r2}} 負責寫 migration plan","sources":["u3"]},
            {"text":"{{speaker:r2}}：下週五前交付","sources":["u3"]},
            {"text":"請 {{speaker:r1}} 先確認預算","sources":["u3"]}]}]}
        """#
        let server = StubServer(status: 200, body: Fixture.gemini(output))
        let points = try await gemini(server).digestPerPerson(transcript).first?.points.map(\.text)
        #expect(points == ["負責寫 migration plan", "下週五前交付", "請 {{speaker:r1}} 先確認預算"])
    }

    @Test func summaryPutsHighlightsUpFrontAndDropsUnknownOwners() async throws {
        let output = #"""
        {"headline":" 決定禮拜四前升級 cluster，{{speaker:r2}} 寫 migration plan。 ",
         "decisions":[{"text":"禮拜四前升級 cluster","sources":["u2"]}],
         "discussionPoints":[{"text":"{{speaker:me}} 提出 migration","sources":["u1"]}],
         "actionItems":[
           {"text":"寫 migration plan","owner":"r2","sources":["u3"],"dueDate":null},
           {"text":"通知客戶","owner":"r9","sources":[],"dueDate":null},
           {"text":"排時程","owner":null,"sources":["u2"],"dueDate":null}]}
        """#
        let server = StubServer(status: 200, body: Fixture.gemini(output))
        let summary = try await gemini(server).summarize(SummaryRequest(
            transcript: transcript, prioritized: transcript.utterances.filter(\.isHighlighted)))

        #expect(summary.headline == "決定禮拜四前升級 cluster，{{speaker:r2}} 寫 migration plan。")
        #expect(summary.decisions == [SourcedText(text: "禮拜四前升級 cluster", sources: [UtteranceID("u2")])])
        #expect(summary.actionItems.map(\.owner) == [SpeakerID("r2"), nil, nil])
        let request = try #require(server.requests.first)
        let highlights = try #require(request.geminiInput.components(separatedBy: "完整逐字稿").first)
        #expect(highlights.contains("[u2]") && !highlights.contains("[u1]"))
        #expect(request.geminiSystem.contains("重點"))
    }

    // MARK: Malformed output

    @Test func summaryCarriesMeetingTimeZoneAndDecodesDueDates() async throws {
        let output = #"""
        {"headline":"交付排程","decisions":[],"discussionPoints":[],"actionItems":[
          {"text":"明天下午三點半寄出","owner":null,"sources":["u1"],"dueDate":"2026-11-15T15:30:00+08:00"},
          {"text":"今天確認","owner":null,"sources":["u1"],"dueDate":"2026-11-14"},
          {"text":"明天中午十二點聯絡","owner":null,"sources":["u1"],"dueDate":null},
          {"text":"有空整理","owner":null,"sources":[],"dueDate":null}]}
        """#
        let server = StubServer(status: 200, body: Fixture.gemini(output))
        let reference = ISO8601DateFormatter().date(from: "2026-11-14T10:00:00+08:00")!
        let summary = try await gemini(server).summarize(SummaryRequest(transcript: transcript, prioritized: [],
            meetingStartedAt: reference, timeZoneIdentifier: "Asia/Taipei"))
        #expect(summary.actionItems[0].due?.dateComponents.hour == 15)
        #expect(summary.actionItems[0].due?.dateComponents.minute == 30)
        #expect(summary.actionItems[1].due?.hasTime == false)
        #expect(summary.actionItems[2].due == nil)
        #expect(summary.actionItems[3].due == nil)
        let request = try #require(server.requests.first)
        #expect(request.geminiInput.contains("2026-11-14T10:00:00+08:00"))
        #expect(request.geminiInput.contains("Asia/Taipei"))
        let config = try #require(request.json["generationConfig"] as? [String: Any])
        let schema = try #require(config["responseJsonSchema"] as? [String: Any])
        let action = ((schema["properties"] as? [String: Any])?["actionItems"] as? [String: Any])?["items"] as? [String: Any]
        #expect((action?["properties"] as? [String: Any])?["dueDate"] != nil)
    }

    static let malformed: [(name: String, body: String)] = [
        ("text is not JSON", Fixture.gemini("Sure! Here is the transcript:")),
        ("JSON missing a required key", Fixture.gemini(#"{"paras":[]}"#)),
        ("speaker not in the meeting", Fixture.gemini(#"{"paragraphs":[{"speaker":"r7","text":"x","sources":["u1"]}]}"#)),
        ("no candidates", #"{"usageMetadata":{"promptTokenCount":10}}"#),
        ("envelope is not JSON", "<html>502</html>"),
        ("only thoughts", #"{"candidates":[{"content":{"parts":[{"text":"hmm","thought":true}]},"finishReason":"STOP"}]}"#),
    ]

    @Test(arguments: malformed)
    func malformedOutputIsReportedNotTrusted(_ c: (name: String, body: String)) async throws {
        let server = StubServer(status: 200, body: c.body)
        await #expect(throws: ProviderError(.gemini, .malformedResponse), "\(c.name)") {
            try await gemini(server).cleanTranscript(transcript)
        }
    }

    @Test func blockedContentIsReportedAsSuch() async throws {
        let prompt = StubServer(status: 200, body: #"{"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}}"#)
        await #expect(throws: ProviderError(.gemini, .blocked)) { try await gemini(prompt).digestPerPerson(transcript) }
        let output = StubServer(status: 200, body: Fixture.gemini("{}", finishReason: "SAFETY"))
        await #expect(throws: ProviderError(.gemini, .blocked)) { try await gemini(output).digestPerPerson(transcript) }
    }

    // MARK: Errors and keys

    static let httpFailures: [(status: Int, body: String, kind: ProviderError.Kind)] = [
        (400, Fixture.googleError(400, status: "INVALID_ARGUMENT", message: "API key not valid. Please pass a valid API key.", reason: "API_KEY_INVALID"), .invalidCredential),
        (401, #"{"error":{"code":"authentication","message":"The API key is missing, invalid, or expired."}}"#, .invalidCredential),
        (403, Fixture.googleError(403, status: "PERMISSION_DENIED", message: "Your API key was reported as leaked."), .permissionDenied),
        (400, Fixture.googleError(400, status: "FAILED_PRECONDITION", message: "User location is not supported for the API use."), .permissionDenied),
        (402, #"{"error":{"code":"payment_required","message":"Prepay credit depleted"}}"#, .outOfCredit),
        (429, Fixture.googleError(429, status: "RESOURCE_EXHAUSTED", message: "Quota exceeded"), .rateLimited),
        (400, Fixture.googleError(400, status: "INVALID_ARGUMENT", message: "Request contains an invalid argument."), .rejectedInput),
        (500, Fixture.googleError(500, status: "INTERNAL", message: "An internal error has occurred."), .serviceError),
        (503, Fixture.googleError(503, status: "UNAVAILABLE", message: "The model is overloaded."), .unavailable),
    ]

    @Test(arguments: httpFailures)
    func mapsHTTPFailures(_ c: (status: Int, body: String, kind: ProviderError.Kind)) async throws {
        let server = StubServer(status: c.status, body: c.body)
        let error = await #expect(throws: ProviderError.self) { try await gemini(server).summarize(SummaryRequest(transcript: transcript, prioritized: [])) }
        #expect(error?.kind == c.kind)
        #expect(error.map { !allMessages(of: $0).contains("AIza-secret") && !allMessages(of: $0).contains("{") } == true)
    }

    @Test func connectionFailureIsUnreachable() async throws {
        let server = StubServer { _ in .failure(.notConnectedToInternet) }
        await #expect(throws: ProviderError(.gemini, .unreachable)) { try await gemini(server).cleanTranscript(transcript) }
    }

    @Test func validateKey() async throws {
        let ok = StubServer(status: 200, body: #"{"name":"models/gemini-3.8-flash","inputTokenLimit":1048576,"outputTokenLimit":65536}"#)
        #expect(await gemini(ok).validateKey() == .valid)
        let request = try #require(ok.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash")
        #expect(request.headers["x-goog-api-key"] == "AIza-secret")

        let bad = StubServer(status: 400, body: Fixture.googleError(400, status: "INVALID_ARGUMENT", message: "API key not valid.", reason: "API_KEY_INVALID"))
        guard case .rejected(let message) = await gemini(bad).validateKey() else { Issue.record("bad key should reject"); return }
        #expect(message.contains("Gemini API Key") && !message.contains("AIza-secret"))

        let offline = StubServer { _ in .failure(.cannotFindHost) }
        guard case .inconclusive = await gemini(offline).validateKey() else { Issue.record("offline is not a verdict"); return }
    }

    @Test func providerDescriptionHidesTheKey() {
        let llm = GeminiLLM(apiKey: "AIza-secret")
        #expect(!String(reflecting: llm).contains("AIza-secret"))
        #expect(!"\(llm)".contains("AIza-secret"))
    }
}
