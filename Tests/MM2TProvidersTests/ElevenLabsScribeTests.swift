import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

@Suite struct ElevenLabsScribeTests {
    func provider(_ server: StubServer) -> ElevenLabsScribe {
        ElevenLabsScribe(apiKey: "xi-secret", session: server.session)
    }

    @Test func sendsTheDocumentedRequest() async throws {
        let server = StubServer(status: 200, body: Fixture.scribe(diarized: true))
        _ = try await provider(server).transcribe(audio: try audioFile("remote.wav"), hints: ["王小明"], labelSpeakers: true)

        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
        #expect(request.headers["xi-api-key"] == "xi-secret")
        #expect(request.field("model_id") == ["scribe_v2"])
        #expect(request.field("diarize") == ["true"])
        #expect(request.field("timestamps_granularity") == ["word"])
        #expect(request.field("tag_audio_events") == ["false"])
        #expect(request.field("language_code").isEmpty)
        #expect(request.bodyText.contains(#"name="file"; filename="remote.wav""#))
    }

    @Test func aRecordingWithNoSamplesIsNeverUploaded() async throws {
        let server = StubServer(status: 200, body: Fixture.scribe(diarized: false))
        let empty = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
        try silentWAV(seconds: 0).write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }

        await #expect(throws: TranscriptionError.failed(ProviderError(.elevenLabs, .audioUnreadable).description)) {
            try await provider(server).transcribe(audio: empty, hints: [], labelSpeakers: false)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func micTrackIsNotDiarized() async throws {
        let server = StubServer(status: 200, body: Fixture.scribe(diarized: false))
        let result = try await provider(server).transcribe(audio: try audioFile(), hints: [], labelSpeakers: false)
        #expect(server.requests.first?.field("diarize") == ["false"])
        #expect(result.labeledWords == nil)
    }

    @Test func diarizedWordsCarryScribeSpeakerLabels() async throws {
        let server = StubServer(status: 200, body: Fixture.scribe(diarized: true))
        let labeled = try #require(try await provider(server).transcribe(audio: try audioFile(), hints: [], labelSpeakers: true).labeledWords)
        #expect(labeled.map(\.speaker.rawValue) == ["speaker_0", "speaker_0", "speaker_1", "speaker_1", "speaker_1", "speaker_1"])
        #expect(labeled[0].word == TimedWord("大家", 0.10, 0.40))
    }

    @Test func dropsSpacingAndAudioEventTokens() throws {
        let words = try ElevenLabsScribe.parse(Data(Fixture.scribe(diarized: false).utf8), labelSpeakers: false).words
        #expect(!words.contains { $0.text == "(笑聲)" || $0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(words.count == 6)
    }

    @Test func partialSpeakerLabelsBecomeAnUnlabeledTrack() throws {
        let body = """
        {"language_code":"eng","language_probability":0.9,"text":"hi there","words":[
          {"text":"hi","start":0.0,"end":0.2,"type":"word","speaker_id":"speaker_0","logprob":-0.1},
          {"text":"there","start":0.3,"end":0.6,"type":"word","speaker_id":null,"logprob":-0.1}]}
        """
        let result = try ElevenLabsScribe.parse(Data(body.utf8), labelSpeakers: true)
        #expect(result == .unlabeled([TimedWord("hi", 0.0, 0.2), TimedWord("there", 0.3, 0.6)]))
    }

    @Test func missingOrInvertedTimesNeverProduceAnInvalidRange() throws {
        let body = """
        {"language_code":"eng","language_probability":0.9,"text":"a b c","words":[
          {"text":"a","start":1.0,"end":1.4,"type":"word","logprob":-0.1},
          {"text":"b","start":null,"end":null,"type":"word","logprob":-0.1},
          {"text":"c","start":2.0,"end":1.9,"type":"word","logprob":-0.1}]}
        """
        let words = try ElevenLabsScribe.parse(Data(body.utf8), labelSpeakers: false).words
        #expect(words == [TimedWord("a", 1.0, 1.4), TimedWord("b", 1.4, 1.4), TimedWord("c", 2.0, 2.0)])
    }

    @Test func keytermsRespectScribeLimits() {
        let hints = ["王小明", "王小明", "Kubernetes", "<script>", "a b c d e f", String(repeating: "x", count: 51), "  spaced   out  ", ""]
            + (0..<200).map { "term\($0)" }
        let terms = ElevenLabsScribe.keyterms(from: hints)

        #expect(Array(terms.prefix(4)) == ["王小明", "Kubernetes", "script", "spaced out"])
        #expect(terms.count == ElevenLabsScribe.maxKeyterms)
        #expect(terms.allSatisfy { $0.count <= 50 && $0.split(separator: " ").count <= 5 })
        #expect(!terms.contains { $0.contains(where: { "<>{}[]\\".contains($0) }) })
    }

    @Test func keytermsAreRepeatedFormFields() async throws {
        let server = StubServer(status: 200, body: Fixture.scribe(diarized: false))
        _ = try await provider(server).transcribe(audio: try audioFile(), hints: ["王小明", "Kubernetes"], labelSpeakers: false)
        #expect(server.requests.first?.field("keyterms") == ["王小明", "Kubernetes"])
    }

    static let failures: [(status: Int, body: String, unreachable: Bool, says: String)] = [
        (401, #"{"detail":{"type":"authentication_error","code":"invalid_api_key","message":"Invalid API key","request_id":"r1"}}"#, false, "invalid"),
        (401, #"{"detail":{"status":"quota_exceeded","message":"This request exceeds your quota."}}"#, false, "out of credit"),
        (402, #"{"detail":{"type":"payment_required","code":"insufficient_credits","message":"x"}}"#, false, "out of credit"),
        (403, #"{"detail":{"type":"authorization_error","code":"insufficient_permissions","message":"x"}}"#, false, "isn't allowed"),
        (422, #"{"detail":[{"loc":["body","file"],"msg":"field required","type":"value_error.missing"}]}"#, false, "rejected"),
        (429, #"{"detail":{"type":"rate_limit_error","code":"concurrent_limit_exceeded","message":"x"}}"#, false, "limit"),
        (500, #"{"detail":{"type":"internal_error","code":"internal_error","message":"x"}}"#, false, "internal error"),
        (503, #"{"detail":{"type":"service_unavailable","code":"maintenance","message":"x"}}"#, true, "temporarily unavailable"),
        (200, #"{"unexpected":true}"#, false, "unexpected format"),
    ]

    @Test(arguments: failures)
    func mapsServiceErrors(_ failure: (status: Int, body: String, unreachable: Bool, says: String)) async throws {
        let server = StubServer(status: failure.status, body: failure.body)
        let error = await #expect(throws: TranscriptionError.self) {
            try await provider(server).transcribe(audio: try audioFile(), hints: [], labelSpeakers: false)
        }
        switch error {
        case .unreachable(let message)?:
            #expect(failure.unreachable)
            #expect(message.contains(failure.says))
        case .failed(let message)?:
            #expect(!failure.unreachable)
            #expect(message.contains(failure.says))
            #expect(!message.contains("request_id") && !message.contains("{"))
        case nil:
            break
        }
    }

    @Test func missingAudioFileIsNotUnreachable() async throws {
        let server = StubServer(status: 200, body: Fixture.scribe(diarized: false))
        let error = await #expect(throws: TranscriptionError.self) {
            try await provider(server).transcribe(audio: URL(filePath: "/nonexistent/remote.wav"), hints: [], labelSpeakers: false)
        }
        guard case .failed = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(server.requests.isEmpty)
    }

    @Test func validateKey() async throws {
        let ok = StubServer(status: 200, body: #"{"language_code":"eng","language_probability":0.5,"text":"","words":[]}"#)
        #expect(await provider(ok).validateKey() == .valid)
        #expect(ok.requests.first?.field("model_id") == ["scribe_v2"])

        let bad = StubServer(status: 401, body: #"{"detail":{"type":"authentication_error","code":"invalid_api_key","message":"x"}}"#)
        guard case .rejected = await provider(bad).validateKey() else { Issue.record("401 should reject"); return }

        let offline = StubServer { _ in .failure(.notConnectedToInternet) }
        guard case .inconclusive = await provider(offline).validateKey() else { Issue.record("offline is not a verdict"); return }

        let busy = StubServer(status: 429, body: #"{"detail":{"type":"rate_limit_error","code":"rate_limit_exceeded","message":"x"}}"#)
        guard case .inconclusive = await provider(busy).validateKey() else { Issue.record("rate limit is not a verdict"); return }
    }
}
