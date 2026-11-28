import Foundation
import os
import Testing
import MM2TCore
@testable import MM2TProviders

struct HostedCaptionsTests {
    private static let sessions = URL(string: "https://fixture.invalid/v1/hosted/sessions")!

    @Test func freeLeaseFinishesAndSkipsToLocalWithoutRequestingAKey() async throws {
        let server = StubServer { request in
            switch request.url.path {
            case Self.sessions.path: .status(200, Self.lease(false))
            case Self.sessions.path + "/lease/finish": .status(204, "")
            default: .status(500, "unexpected request")
            }
        }
        let hosted = makeProvider(server) { _ in
            Issue.record("Free must never open a Soniox socket")
            return Socket()
        }
        let local = Local()
        let chain = StreamingTranscriptionChain([.init(.mm2t, hosted), .init(.local, local)])
        let session = try await chain.open(.init(languageCode: nil, hints: [], sampleRate: 16_000))
        var events = session.events.makeAsyncIterator()
        #expect(try await events.next() == .final("本機字幕"))
        await chain.stop(retainingLeaseFor: nil)
        #expect(server.requests.map(\.url.path) == [Self.sessions.path, Self.sessions.path + "/lease/finish"])
    }

    @Test(arguments: [false, true])
    func nextRecordingCleansUpALeaseWhenThePreviousFinishFailed(networkError: Bool) async throws {
        let saved = OSAllocatedUnfairLock(initialState: [String]())
        let leases = HostedLeases(recall: { saved.withLock { $0 } }, keep: { ids in saved.withLock { $0 = ids } })
        #expect(await leases.adopt("assigned-to-batch", for: "saved-meeting"))
        let phase = OSAllocatedUnfairLock(initialState: 0)
        let server = StubServer { request in
            let step = phase.withLock { count in defer { count += 1 }; return count }
            switch (step, request.url.path) {
            case (0, Self.sessions.path), (4, Self.sessions.path):
                return .status(200, Self.lease(false))
            case (1, Self.sessions.path + "/lease/finish"):
                return networkError ? .failure(.networkConnectionLost) : .status(503, "")
            case (2, Self.sessions.path):
                return .status(409, #"{"error":{"code":"session_active"}}"#)
            case (3, Self.sessions.path + "/lease/finish"), (5, Self.sessions.path + "/lease/finish"):
                return .status(204, "")
            default:
                Issue.record("Unexpected lease request at step \(step)")
                return .status(500, "")
            }
        }
        for _ in 0..<2 {
            let hosted = makeProvider(server, leases: leases) { _ in
                Issue.record("Free must never open a Soniox socket")
                return Socket()
            }
            let chain = StreamingTranscriptionChain([.init(.mm2t, hosted), .init(.local, Local())])
            let session = try await chain.open(.init(languageCode: nil, hints: [], sampleRate: 16_000))
            var events = session.events.makeAsyncIterator()
            #expect(try await events.next() == .final("本機字幕"))
            await chain.stop(retainingLeaseFor: nil)
        }
        #expect(phase.withLock { $0 } == 6)
        #expect(saved.withLock { $0 } == ["assigned-to-batch"])
    }

    @Test(arguments: [("zh", false), ("en", true)])
    func sendsSonioxFramesAndConvertsCommittedAndReplacingPartialTokens(language: String, traditional: Bool) async throws {
        let server = paidServer()
        let socket = Socket()
        let hosted = makeProvider(server, traditional: traditional) { url in
            #expect(url.absoluteString == "wss://stt-rt.soniox.com/transcribe-websocket")
            return socket
        }
        let chain = StreamingTranscriptionChain([.init(.mm2t, hosted), .init(.local, Local())])
        let session = try await chain.open(.init(languageCode: language, hints: [], sampleRate: 16_000))
        try await session.send([0, 1, -1])
        socket.reply(#"{"tokens":[{"text":"学习","is_final":true},{"text":"简","is_final":false}]}"#)
        socket.reply(#"{"tokens":[{"text":"简体","is_final":false}]}"#)
        socket.reply(#"{"tokens":[{"text":"简体","is_final":true},{"text":"<end>","is_final":true}]}"#)
        var events = session.events.makeAsyncIterator()
        #expect(try await events.next() == .final("學習"))
        #expect(try await events.next() == .partial("簡"))
        #expect(try await events.next() == .partial("簡體"))
        #expect(try await events.next() == .final("簡體"))
        #expect(try await events.next() == .partial(""))
        await session.close()
        await chain.stop(retainingLeaseFor: nil)
        #expect(try await events.next() == nil)
        let frames = socket.frames
        try #require(frames.count == 3)
        let config = try Self.config(frames[0])
        #expect(config["api_key"] as? String == "key-1")
        #expect(config["model"] as? String == "stt-rt-v6")
        #expect(config["audio_format"] as? String == "pcm_s16le")
        #expect(config["sample_rate"] as? Int == 16_000)
        #expect(config["num_channels"] as? Int == 1)
        #expect(config["language_hints"] as? [String] == [language])
        if case .data(let pcm) = frames[1] { #expect(pcm.count == 6) }
        else { Issue.record("Expected a binary PCM frame") }
        if case .string(let end) = frames[2] { #expect(end.isEmpty) }
        else { Issue.record("Expected the end frame") }
        #expect(server.requests.allSatisfy { $0.method == "POST" && $0.headers["Authorization"] == "Bearer account-fixture" })
    }

    @Test func simultaneousRecordingAndCaptionsKeepOneLeaseUntilTranscriptFinishes() async throws {
        let server = paidServer()
        let leases = HostedLeases(), id = MeetingID()
        let captions = HostedCaptions(url: Self.sessions, authorization: .fixed("account-fixture"),
            traditionalChinese: false, leases: leases, meeting: id.description, http: server.session,
            socket: { _ in Socket() })
        let stt = HostedTranscriptionTests().provider(server, leases: leases)
        let clip = try HostedTranscriptionTests().tone(seconds: 1)
        async let socket = captions.open(.init(languageCode: nil, hints: [], sampleRate: 16_000))
        async let words = TranscriptionContext.$current.withValue(.init(meeting: id.description, track: .me, recordingOffset: 30)) {
            try await stt.transcribe(audio: clip, hints: [], labelSpeakers: false)
        }
        let (stream, transcript) = try await (socket, words)
        #expect(transcript.words.count == 1)
        await stream.close()
        await captions.stop(retainingLeaseFor: id)
        #expect(!server.requests.contains { $0.url.path.hasSuffix("/finish") })
        await stt.finishSession(meeting: id.description)
        #expect(server.requests.filter { $0.url.path == Self.sessions.path }.count == 1)
        #expect(server.requests.filter { $0.url.path.hasSuffix("/finish") }.count == 1)
    }

    @Test func aDroppedSocketGetsAFreshKeyAndTheSavedMeetingKeepsItsLease() async throws {
        let server = paidServer()
        let pool = SocketPool()
        let leases = HostedLeases()
        let hosted = makeProvider(server, leases: leases) { _ in pool.open() }
        let first = try await hosted.open(.init(languageCode: nil, hints: [], sampleRate: 16_000))
        let firstSocket = try #require(pool.last)
        firstSocket.reply(#"{"tokens":[{"text":"第一段","is_final":true}]}"#)
        firstSocket.reply(#"{"error_code":408,"error_message":"temp_api_key_session_expired"}"#)
        var committed: [String] = []
        do {
            for try await event in first.events { if case .final(let text) = event { committed.append(text) } }
            Issue.record("A socket error must end the stream with an error so the caption loop reconnects")
        } catch { }
        let second = try await hosted.open(.init(languageCode: nil, hints: [], sampleRate: 16_000, previousText: committed.last))
        let secondSocket = try #require(pool.last)
        secondSocket.reply(#"{"tokens":[{"text":"第二段","is_final":true}],"finished":true}"#)
        for try await event in second.events { if case .final(let text) = event { committed.append(text) } }
        #expect(committed == ["第一段", "第二段"])
        let frames = firstSocket.frames + secondSocket.frames
        #expect(try frames.map { try Self.config($0)["api_key"] as? String } == ["key-1", "key-2"])

        let meeting = MeetingID()
        await hosted.stop(retainingLeaseFor: meeting)
        #expect(server.requests.map(\.url.path) == [Self.sessions.path, Self.sessions.path + "/lease/captions", Self.sessions.path + "/lease/captions"])
        let stt = HostedTranscription(baseURL: Self.sessions.deletingLastPathComponent().appending(component: "stt"),
                                      authorization: .fixed("account-fixture"), leases: leases, session: server.session)
        try FileManager.default.createDirectory(at: testScratch, withIntermediateDirectories: true)
        let audio = testScratch.appending(component: "caption-handoff-\(UUID()).wav")
        let samples = (0..<16_000).map { Float(0.25 * sin(Double($0) * .pi / 20)) }
        try wav(samples, sampleRate: 16_000).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let context = TranscriptionContext(meeting: meeting.description, track: .me)
        let words = try await TranscriptionContext.$current.withValue(context) {
            try await stt.transcribe(audio: audio, hints: [], labelSpeakers: false).words
        }
        #expect(words.count == 1)
        #expect(server.requests.filter { $0.url.path == Self.sessions.path }.count == 1)
        #expect(server.requests.last?.headers["X-MM2T-Session"] == "lease")
        await stt.finishSession(meeting: meeting.description)
        #expect(server.requests.last?.url.path == Self.sessions.path + "/lease/finish")
    }

    private func makeProvider(_ server: StubServer, traditional: Bool = false, leases: HostedLeases = HostedLeases(),
                              socket: @escaping @Sendable (URL) -> any CaptionWebSocket) -> HostedCaptions {
        HostedCaptions(url: Self.sessions, authorization: .fixed(Secret("account-fixture")), traditionalChinese: traditional,
                       leases: leases, http: server.session, socket: socket)
    }

    private static func lease(_ live: Bool) -> String {
        #"{"id":"lease","expiresAt":"2099-01-01T00:00:00.123Z","maxSeconds":7200,"features":{"liveCaptions":\#(live)}}"#
    }

    private func paidServer() -> StubServer {
        let sequence = OSAllocatedUnfairLock(initialState: 0)
        return StubServer { request in
            switch request.url.path {
            case Self.sessions.path: return .status(200, Self.lease(true))
            case Self.sessions.path + "/lease/captions":
                let key = sequence.withLock { $0 += 1; return $0 }
                return .status(200, #"{"apiKey":"key-\#(key)","expiresAt":"2099-01-01T00:00:00Z","websocketUrl":"wss://stt-rt.soniox.com/transcribe-websocket","model":"stt-rt-v6","maxSessionSeconds":7200}"#)
            case Self.sessions.path + "/lease/finish": return .status(204, "")
            case "/v1/hosted/stt/v1/transcriptions":
                return .status(200, #"{"segments":[{"start":0,"end":0.5,"text":"好","words":[{"word":"好","start":0,"end":0.5}]}]}"#)
            default: return .status(500, "unexpected request")
            }
        }
    }

    private static func config(_ frame: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        guard case .string(let text) = frame else { throw URLError(.cannotDecodeContentData) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private struct Local: StreamingTranscriptionProvider, StreamingTranscriptionSession {
        var events: AsyncThrowingStream<StreamingTranscriptEvent, Error> {
            AsyncThrowingStream { $0.yield(.final("本機字幕")); $0.finish() }
        }
        func open(_ request: StreamingTranscriptionRequest) async throws -> any StreamingTranscriptionSession { self }
        func send(_ samples: [Float]) async throws {}
        func close() async {}
    }

    private final class SocketPool: Sendable {
        private let sockets = OSAllocatedUnfairLock(initialState: [Socket]())
        var last: Socket? { sockets.withLock { $0.last } }
        func open() -> Socket {
            let socket = Socket()
            sockets.withLock { $0.append(socket) }
            return socket
        }
    }

    private final class Socket: Sendable, CaptionWebSocket {
        typealias Frame = URLSessionWebSocketTask.Message
        private let incoming = AsyncThrowingStream<Frame, Error>.makeStream()
        private let sent = OSAllocatedUnfairLock(initialState: [Frame]())
        var frames: [Frame] { sent.withLock { $0 } }

        func send(_ message: Frame) async throws {
            sent.withLock { $0.append(message) }
            if case .string("") = message { reply(#"{"finished":true}"#) }
        }
        func receive() async throws -> Frame {
            var iterator = incoming.stream.makeAsyncIterator()
            guard let frame = try await iterator.next() else { throw URLError(.networkConnectionLost) }
            return frame
        }
        func reply(_ text: String) { incoming.continuation.yield(.string(text)) }
        func closeSocket() { incoming.continuation.finish() }
    }
}
