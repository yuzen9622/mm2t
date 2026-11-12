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
        let transcript = geminiInput.range(of: "逐字稿：\n", options: .backwards).map { geminiInput[$0.upperBound...] } ?? Substring(geminiInput)
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
        #expect(request.geminiSystem.contains("sources"))
        #expect(request.geminiSystem.contains("繁體中文"))
        #expect(request.geminiSystem.contains("不要濃縮"))
        #expect(request.geminiInput.contains("[u2] {{speaker:r1}} 00:00:05 對我覺得禮拜三"))
        #expect(request.geminiInput.contains("(重點) [u2]"))
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

    static let englishDirective = "Output language: English"

    @Test func anEnglishMeetingIsAnsweredInEnglishByEveryTask() async throws {
        let english = LLMTranscript(utterances: [
            utterance("u1", "me", 0, "Okay, so the remote control has to be under twenty five euros."),
            utterance("u2", "r1", 6, "Right, and I think we should drop the LCD screen to save cost."),
            utterance("u3", "r2", 14, "I'll send the market research before the next meeting."),
        ])
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"paragraphs":[],"digests":[],"guesses":[],"title":"t","terms":[],"headline":"h","decisions":[],"discussionPoints":[],"actionItems":[]}"#))
        let llm = gemini(server)
        _ = try await llm.cleanTranscript(english)
        _ = try await llm.digestPerPerson(english)
        _ = try? await llm.summarize(SummaryRequest(transcript: english, prioritized: []))
        _ = try? await llm.inferNames(NameInferenceRequest(transcript: english, unnamedSpeakers: [SpeakerID("r1")], knownNames: [:]))

        #expect(server.requests.count == 4)
        for request in server.requests {
            #expect(request.geminiSystem.contains(Self.englishDirective))
        }
    }

    @Test func aMandarinMeetingFullOfEnglishTermsStaysInTraditionalChinese() async throws {
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"digests":[]}"#))
        _ = try await gemini(server).digestPerPerson(transcript)
        let request = try #require(server.requests.first)
        #expect(!request.geminiSystem.contains(Self.englishDirective))
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
           {"text":"寫 migration plan","owner":"r2","sources":["u3"]},
           {"text":"通知客戶","owner":"r9","sources":[]},
           {"text":"排時程","owner":null,"sources":["u2"]}]}
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
