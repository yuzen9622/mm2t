import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

/// The hosted plan's lease protocol, against a fake backend that routes by path.
@Suite struct HostedTranscriptionTests {
    let base = URL(string: "https://api.mm2t.test/v1/hosted/stt")!

    /// A tone of `seconds`, so no piece is skipped as silence.
    func tone(seconds: Double) throws -> URL {
        let rate = 16000
        let samples = (0..<Int(seconds * Double(rate))).map { Float(0.25 * sin(2 * Double.pi * 440 * Double($0) / Double(rate))) }
        let dir = testScratch.appending(path: "hosted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "track.wav")
        try wav(samples, sampleRate: rate).write(to: url)
        return url
    }

    /// One word half a second into each piece.
    static let word = #"{"segments":[{"start":0.5,"end":0.9,"text":"好","words":[{"word":"好","start":0.5,"end":0.9}]}]}"#

    func provider(_ server: StubServer, leases: HostedLeases = HostedLeases(), parallel: Int = 3) -> HostedTranscription {
        HostedTranscription(baseURL: base, authorization: .fixed("tok"), leases: leases, session: server.session,
                            pieceSeconds: 2, parallelPieces: parallel)
    }

    func uploads(_ server: StubServer) -> [StubServer.Request] { server.requests.filter { $0.url.path.hasSuffix("/v1/transcriptions") } }
    func paths(_ server: StubServer) -> [String] { server.requests.map(\.url.path) }

    func run(_ provider: HostedTranscription, _ audio: URL, meeting: String = "m1", track: Track = .remote) async throws -> [TimedWord] {
        try await TranscriptionContext.$current.withValue(TranscriptionContext(meeting: meeting, track: track)) {
            try await provider.transcribe(audio: audio, hints: [], labelSpeakers: false).words
        }
    }

    @Test func opensOneLeaseAndSendsEachPieceWithItsHeaders() async throws {
        let server = StubServer { request in
            if request.url.path == "/v1/hosted/sessions" { return .status(201, #"{"id":"lease-1","expiresAt":"x","maxSeconds":3600}"#) }
            return .status(200, Self.word)
        }
        let provider = provider(server)
        let words = try await run(provider, try tone(seconds: 5))

        #expect(words.map(\.range.start) == [0.5, 2.5, 4.5])
        #expect(paths(server).filter { $0 == "/v1/hosted/sessions" }.count == 1)
        let sent = uploads(server)
        #expect(Set(sent.compactMap { $0.headers["X-MM2T-Piece"] }) == ["0", "2", "4"])
        #expect(sent.allSatisfy { $0.headers["X-MM2T-Session"] == "lease-1" && $0.headers["X-MM2T-Track"] == "system" })
        #expect(sent.allSatisfy { $0.headers["Authorization"] == "Bearer tok" })

        await provider.finishSession(meeting: "m1")
        #expect(server.requests.last?.url.path == "/v1/hosted/sessions/lease-1/finish")
        #expect(server.requests.last?.method == "POST")
    }

    @Test func micTrackIsSentAsMic() async throws {
        let server = StubServer { request in
            request.url.path == "/v1/hosted/sessions" ? .status(201, #"{"id":"lease-1"}"#) : .status(200, Self.word)
        }
        _ = try await run(provider(server), try tone(seconds: 1), track: .me)
        #expect(uploads(server).first?.headers["X-MM2T-Track"] == "mic")
    }

    @Test func keepsWhatCameBackWhenTheMeetingReachesThePlanLength() async throws {
        let server = StubServer { request in
            if request.url.path == "/v1/hosted/sessions" { return .status(201, #"{"id":"lease-1"}"#) }
            if request.headers["X-MM2T-Piece"] == "4" { return .status(402, #"{"error":{"code":"session_limit_reached"}}"#) }
            return .status(200, Self.word)
        }
        let words = try await run(provider(server, parallel: 1), try tone(seconds: 7))

        #expect(words.map(\.range.start) == [0.5, 2.5])
        // Nothing after the refused piece goes up.
        #expect(uploads(server).compactMap { $0.headers["X-MM2T-Piece"] } == ["0", "2", "4"])
    }

    @Test func limitOnTheFirstPieceFails() async throws {
        let server = StubServer { request in
            request.url.path == "/v1/hosted/sessions"
                ? .status(201, #"{"id":"lease-1"}"#) : .status(402, #"{"error":{"code":"session_limit_reached"}}"#)
        }
        await #expect(throws: TranscriptionError.self) { try await run(provider(server, parallel: 1), try tone(seconds: 1)) }
    }

    @Test func finishesAnAbandonedLeaseWhenAnotherIsActive() async throws {
        let opened = Counter()
        let kept = Box<[String]>(["old"])
        let leases = HostedLeases(recall: { kept.value }, keep: { kept.value = $0 })
        let server = StubServer { request in
            switch request.url.path {
            case "/v1/hosted/sessions":
                return opened.next() == 0
                    ? .status(409, #"{"error":{"code":"session_active"}}"#) : .status(201, #"{"id":"lease-2"}"#)
            case "/v1/hosted/sessions/old/finish": return .status(200, "{}")
            default: return .status(200, Self.word)
            }
        }
        _ = try await run(provider(server, leases: leases), try tone(seconds: 1))

        #expect(paths(server) == ["/v1/hosted/sessions", "/v1/hosted/sessions/old/finish", "/v1/hosted/sessions", "/v1/hosted/stt/v1/transcriptions"])
        #expect(kept.value == ["lease-2"])
    }

    @Test func finishesTheLeaseOfAnIdleFailedMeeting() async throws {
        let opened = Counter()
        let server = StubServer { request in
            switch request.url.path {
            case "/v1/hosted/sessions":
                switch opened.next() {
                case 0: return .status(201, #"{"id":"old"}"#)
                case 1: return .status(409, #"{"error":{"code":"session_active"}}"#)
                default: return .status(201, #"{"id":"lease-2"}"#)
                }
            case "/v1/hosted/sessions/old/finish": return .status(200, "{}")
            default:
                return request.headers["X-MM2T-Session"] == "old" ? .status(503, "{}") : .status(200, Self.word)
            }
        }
        let provider = provider(server)
        let audio = try tone(seconds: 1)
        await #expect(throws: TranscriptionError.self) { try await run(provider, audio, meeting: "m1") }
        #expect(try await run(provider, audio, meeting: "m2").map(\.text) == ["好"])
        #expect(Array(paths(server).dropFirst(2)) == [
            "/v1/hosted/sessions", "/v1/hosted/sessions/old/finish", "/v1/hosted/sessions", "/v1/hosted/stt/v1/transcriptions",
        ])
    }

    @Test func sessionActiveRecoveryDoesNotFinishAnotherMeetingsUpload() async throws {
        let opened = Counter()
        let kept = Box<[String]>([])
        let leases = HostedLeases(recall: { kept.value }, keep: { kept.value = $0 })
        let (started, signalStart) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let server = StubServer { request in
            switch request.url.path {
            case "/v1/hosted/sessions":
                return opened.next() == 0
                    ? .status(201, #"{"id":"lease-1"}"#) : .status(409, #"{"error":{"code":"session_active"}}"#)
            case "/v1/hosted/stt/v1/transcriptions":
                return .after {
                    signalStart.yield(())
                    for await _ in released { break }
                    return (200, Self.word)
                }
            default: return .status(200, "{}")
            }
        }
        let provider = provider(server, leases: leases)
        let audio = try tone(seconds: 1)
        let first = Task {
            defer { signalStart.finish() }
            return try await run(provider, audio, meeting: "m1")
        }
        var starts = started.makeAsyncIterator()
        _ = try #require(await starts.next())

        await #expect(throws: ProviderError(.mm2tPlan, .sessionActive).asTranscriptionError) {
            try await run(provider, audio, meeting: "m2")
        }
        #expect(!paths(server).contains("/v1/hosted/sessions/lease-1/finish"))
        #expect(kept.value == ["lease-1"])

        release.finish()
        #expect(try await first.value.map(\.text) == ["好"])
        #expect(uploads(server).compactMap { $0.headers["X-MM2T-Session"] } == ["lease-1"])
    }

    @Test(arguments: [503, 409, 0], [204, 404, 409])
    func unconfirmedFinishKeepsLeaseForNextRecovery(status: Int, confirmation: Int) async throws {
        let opened = Counter()
        let finishes = Counter()
        let closed = Box(false)
        let kept = Box<[String]>([])
        let leases = HostedLeases(recall: { kept.value }, keep: { kept.value = $0 })
        let server = StubServer { request in
            switch request.url.path {
            case "/v1/hosted/sessions":
                if opened.next() == 0 { return .status(201, #"{"id":"lease-1"}"#) }
                return closed.value
                    ? .status(201, #"{"id":"lease-2"}"#) : .status(409, #"{"error":{"code":"session_active"}}"#)
            case "/v1/hosted/sessions/lease-1/finish":
                if finishes.next() > 0 {
                    closed.value = true
                    return .status(confirmation, confirmation == 409 ? #"{"error":{"code":"session_closed"}}"# : "")
                }
                return status == 0 ? .failure(.timedOut) : .status(status, "{}")
            default: return .status(200, Self.word)
            }
        }
        let provider = provider(server, leases: leases)
        let audio = try tone(seconds: 1)
        _ = try await run(provider, audio, meeting: "m1")
        await provider.finishSession(meeting: "m1")
        #expect(kept.value == ["lease-1"])

        _ = try await run(provider, audio, meeting: "m2")
        #expect(paths(server).filter { $0 == "/v1/hosted/sessions/lease-1/finish" }.count == 2)
        #expect(kept.value == ["lease-2"])
    }

    @Test func reopensALeaseTheBackendClosed() async throws {
        let opened = Counter()
        let kept = Box<[String]>([])
        let leases = HostedLeases(recall: { kept.value }, keep: { kept.value = $0 })
        let server = StubServer { request in
            if request.url.path == "/v1/hosted/sessions" { return .status(201, #"{"id":"lease-\#(opened.next() + 1)"}"#) }
            if request.headers["X-MM2T-Session"] == "lease-1" { return .status(409, #"{"error":{"code":"session_closed"}}"#) }
            return .status(200, Self.word)
        }
        let words = try await run(provider(server, leases: leases), try tone(seconds: 1))

        #expect(words.count == 1)
        #expect(uploads(server).compactMap { $0.headers["X-MM2T-Session"] } == ["lease-1", "lease-2"])
        #expect(kept.value == ["lease-2"])
    }

    @Test func aRetryReusesResultsAndResendsTheSameBytes() async throws {
        let failing = Box(true)
        let server = StubServer { request in
            if request.url.path == "/v1/hosted/sessions" { return .status(201, #"{"id":"lease-1"}"#) }
            if request.headers["X-MM2T-Piece"] == "2", failing.value { return .status(503, #"{"error":{"code":"unavailable"}}"#) }
            return .status(200, Self.word)
        }
        let provider = provider(server, parallel: 1)
        let audio = try tone(seconds: 5)
        await #expect(throws: (any Error).self) { try await run(provider, audio) }
        let firstTry = uploads(server).filter { $0.headers["X-MM2T-Piece"] == "2" }

        failing.value = false
        let words = try await run(provider, audio)

        #expect(words.map(\.range.start) == [0.5, 2.5, 4.5])
        let pieces = uploads(server).compactMap { $0.headers["X-MM2T-Piece"] }
        #expect(pieces.filter { $0 == "0" }.count == 1)
        #expect(paths(server).filter { $0 == "/v1/hosted/sessions" }.count == 1)
        let retried = uploads(server).filter { $0.headers["X-MM2T-Piece"] == "2" }
        #expect(retried.count == 2)
        #expect(firstTry.first.map { audioPart($0) } == audioPart(retried[1]))
    }

    @Test func outsideAMeetingTheLeaseCoversOneFile() async throws {
        let server = StubServer { request in
            request.url.path == "/v1/hosted/sessions" ? .status(201, #"{"id":"lease-9"}"#) : .status(200, Self.word)
        }
        _ = try await provider(server).transcribe(audio: try tone(seconds: 1), hints: [], labelSpeakers: false)
        #expect(paths(server).last == "/v1/hosted/sessions/lease-9/finish")
    }

    @Test func silentPiecesAreNotSent() async throws {
        let server = StubServer { request in
            request.url.path == "/v1/hosted/sessions" ? .status(201, #"{"id":"lease-1"}"#) : .status(200, Self.word)
        }
        let dir = testScratch.appending(path: "hosted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let silent = dir.appending(path: "silent.wav")
        try silentWAV(seconds: 3).write(to: silent)

        #expect(try await run(provider(server), silent).isEmpty)
        #expect(uploads(server).isEmpty)
    }

    /// The bytes after the file part's headers.
    func audioPart(_ request: StubServer.Request) -> Data? {
        guard let start = request.body.range(of: Data("filename=\"piece.m4a\"".utf8)),
              let body = request.body.range(of: Data("\r\n\r\n".utf8), in: start.upperBound..<request.body.endIndex) else { return nil }
        guard let end = request.body.range(of: Data("\r\n--".utf8), options: .backwards) else { return nil }
        return request.body[body.upperBound..<end.lowerBound]
    }
}

@Suite struct HostedAuthorizationTests {
    @Test func renewsOnceAfterA401() async throws {
        let renewed = Box<[String]>([])
        let auth = HostedAuthorization(stored: "old", current: { "old" }, renew: { rejected in
            renewed.value.append(rejected.revealed)
            return "new"
        })
        let server = StubServer { request in
            request.headers["Authorization"] == "Bearer new" ? .status(200, "{}") : .status(401, #"{"error":{"code":"invalid_token"}}"#)
        }
        let response = try await auth.send(server.session) { token in
            var request = URLRequest(url: URL(string: "https://api.mm2t.test/v1/hosted/sessions")!)
            request.setValue("Bearer \(token.revealed)", forHTTPHeaderField: "Authorization")
            return request
        }
        #expect(response.status == 200)
        #expect(renewed.value == ["old"])
        #expect(server.requests.map { $0.headers["Authorization"] } == ["Bearer old", "Bearer new"])
    }

    @Test func aFixedTokenIsNotRenewed() async throws {
        let server = StubServer(status: 401, body: #"{"error":{"code":"invalid_token"}}"#)
        await #expect(throws: ProviderError.self) {
            _ = try await HostedAuthorization.fixed("tok").send(server.session) { _ in
                URLRequest(url: URL(string: "https://api.mm2t.test/x")!)
            }
        }
        #expect(server.requests.count == 1)
    }

    @Test func mapsHostedErrorCodes() {
        func kind(_ status: Int, _ body: String) -> ProviderError.Kind { HTTPResponse(status: status, body: Data(body.utf8)).hostedFailure }
        #expect(kind(402, #"{"error":{"code":"quota_exceeded"}}"#) == .outOfCredit)
        #expect(kind(402, #"{"error":{"code":"session_limit_reached"}}"#) == .sessionLimitReached)
        #expect(kind(409, #"{"error":{"code":"session_active"}}"#) == .sessionActive)
        #expect(kind(402, #"{"error":{"code":"ai_quota_exceeded","scope":"daily"}}"#) == .aiQuotaExceeded(.daily))
        #expect(kind(402, #"{"error":{"code":"ai_quota_exceeded"}}"#) == .aiQuotaExceeded(.monthly))
        #expect(kind(403, #"{"error":{"code":"billing_blocked"}}"#) == .permissionDenied)
        #expect(kind(429, #"{"error":{"code":"rate_limited"}}"#) == .rateLimited)
        #expect(kind(413, #"{"error":{"code":"input_too_large"}}"#) == .meetingTooLong)
        #expect(kind(401, #"{"error":{"code":"invalid_token"}}"#) == .invalidCredential)
    }
}

@Suite struct HostedLLMPurposeTests {
    func llm(_ server: StubServer) -> OpenAICompatibleLLM {
        OpenAICompatibleLLM(baseURL: URL(string: "https://api.mm2t.test/v1/hosted/llm")!, apiKey: nil, model: "mm2t",
                            session: server.session, authorization: .fixed("tok"))
    }

    @Test func questionsAreAsksAndRewritesAreRewrites() async throws {
        let server = StubServer(status: 200, body: Fixture.chatCompletion(#"{"text":"好"}"#))
        let provider = llm(server)
        _ = try await provider.generateText(system: "s", input: "問")
        _ = try await provider.rewrite("原文", instruction: "改短")
        let purposes = server.requests.map { $0.headers["X-MM2T-Purpose"] }
        #expect(purposes.first == "ask")
        #expect(purposes.last == "rewrite")
        #expect(server.requests.allSatisfy { $0.headers["Authorization"] == "Bearer tok" })
    }

    @Test func meetingProcessingIsAuto() async throws {
        let server = StubServer(status: 200, body: Fixture.chatCompletion(#"{"names":[]}"#))
        _ = try? await llm(server).inferNames(NameInferenceRequest(
            transcript: LLMTranscript(utterances: [utterance("u1", "r1", 0, "大家好")]), unnamedSpeakers: [SpeakerID("r1")], knownNames: [:]))
        #expect(!server.requests.isEmpty)
        #expect(server.requests.allSatisfy { $0.headers["X-MM2T-Purpose"] == "auto" })
    }

    @Test func aiLimitIsItsOwnFailure() async throws {
        let server = StubServer(status: 402, body: #"{"error":{"code":"ai_quota_exceeded","scope":"asks"}}"#)
        do {
            _ = try await llm(server).generateText(system: "s", input: "問")
            Issue.record("expected a failure")
        } catch let error as ProviderError {
            #expect(error.kind == .aiQuotaExceeded(.asks))
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
