import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

/// One implementation of `TranscriptionProvider` behind a fake network that answers
/// with that service's documented response shape.
struct ContractCase: CustomTestStringConvertible, Sendable {
    let name: String
    let canLabelSpeakers: Bool
    let secret: Secret
    let make: @Sendable (StubServer) -> any TranscriptionProvider
    let answer: @Sendable (StubServer.Request) -> StubServer.Reply

    var testDescription: String { name }

    static let all: [ContractCase] = [
        ContractCase(
            name: "ElevenLabs Scribe", canLabelSpeakers: true, secret: "xi-secret-123",
            make: { ElevenLabsScribe(apiKey: "xi-secret-123", session: $0.session) },
            answer: { .status(200, Fixture.scribe(diarized: $0.field("diarize") == ["true"])) }),
        ContractCase(
            name: "Self-hosted server", canLabelSpeakers: false, secret: "lan-token-456",
            make: { SelfHostedTranscription(baseURL: URL(string: "http://gpu-box:8000")!, token: "lan-token-456", session: $0.session) },
            answer: { .status(200, $0.url.path == "/healthz" ? Fixture.health : Fixture.selfHosted) }),
    ]
}

@Suite struct TranscriptionContractTests {
    let hints = ["王小明", "Kubernetes"]

    @Test(arguments: ContractCase.all)
    func returnsWordsWithOrderedTimestamps(_ c: ContractCase) async throws {
        let server = StubServer(c.answer)
        let words = try await c.make(server).transcribe(audio: try audioFile(), hints: hints, labelSpeakers: false).words

        #expect(words.map(\.text) == ["大家", "好", "我是", "小明", "Kubernetes", "cluster"])
        #expect(words.allSatisfy { $0.range.end >= $0.range.start })
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.range.start <= $1.range.start })
        #expect(words.last!.range.end > 2.8)
    }

    @Test(arguments: ContractCase.all)
    func everyHintReachesTheRequest(_ c: ContractCase) async throws {
        let server = StubServer(c.answer)
        _ = try await c.make(server).transcribe(audio: try audioFile(), hints: hints, labelSpeakers: true)

        let upload = try #require(server.requests.last)
        for hint in hints { #expect(upload.bodyText.contains(hint), "\(hint) missing from the upload") }
    }

    @Test(arguments: ContractCase.all)
    func labelsSpeakersOnlyWhenAsked(_ c: ContractCase) async throws {
        let server = StubServer(c.answer)
        let provider = c.make(server)

        let unasked = try await provider.transcribe(audio: try audioFile(), hints: [], labelSpeakers: false)
        #expect(unasked.labeledWords == nil)

        let asked = try await provider.transcribe(audio: try audioFile(), hints: [], labelSpeakers: true)
        if c.canLabelSpeakers {
            let labeled = try #require(asked.labeledWords)
            #expect(labeled.count == asked.words.count)
        } else {
            #expect(asked.labeledWords == nil)
        }
    }

    @Test(arguments: ContractCase.all)
    func connectionFailureFallsThroughTheChain(_ c: ContractCase) async throws {
        let server = StubServer { _ in .failure(.cannotConnectToHost) }
        let next = StubServer(ContractCase.all[1].answer)
        let chain = TranscriptionChain([
            .init(.cloud, c.make(server)),
            .init(.selfHosted, ContractCase.all[1].make(next)),
        ])

        let result = try await chain.transcribe(audio: try audioFile(), hints: [], labelSpeakers: false)
        #expect(result.source == .selfHosted)
    }

    @Test(arguments: ContractCase.all, [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .networkConnectionLost])
    func connectionLevelFailuresAreUnreachable(_ c: ContractCase, code: URLError.Code) async throws {
        let server = StubServer { _ in .failure(code) }
        let error = await #expect(throws: TranscriptionError.self) {
            try await c.make(server).transcribe(audio: try audioFile(), hints: [], labelSpeakers: false)
        }
        guard case .unreachable = error else { Issue.record("\(code) mapped to \(String(describing: error))"); return }
    }

    @Test(arguments: ContractCase.all)
    func rejectedCredentialStopsTheChain(_ c: ContractCase) async throws {
        let server = StubServer { request in
            request.url.path == "/healthz"
                ? .status(200, Fixture.health)
                : .status(401, #"{"detail":{"type":"authentication_error","code":"invalid_api_key","message":"Invalid API key"},"error":{"code":"unauthorized","message":"missing or invalid bearer token"}}"#)
        }
        let fallback = StubServer(ContractCase.all[1].answer)
        let chain = TranscriptionChain([.init(.cloud, c.make(server)), .init(.selfHosted, ContractCase.all[1].make(fallback))])

        let error = await #expect(throws: TranscriptionError.self) {
            try await chain.transcribe(audio: try audioFile(), hints: [], labelSpeakers: false)
        }
        guard case .failed(let message) = error else { Issue.record("expected .failed, got \(String(describing: error))"); return }
        #expect(message.contains("無效"))
        #expect(fallback.requests.isEmpty)
    }

    @Test(arguments: ContractCase.all)
    func secretNeverAppearsInURLsOrErrors(_ c: ContractCase) async throws {
        let ok = StubServer(c.answer)
        _ = try await c.make(ok).transcribe(audio: try audioFile(), hints: hints, labelSpeakers: true)
        #expect(!ok.requests.isEmpty)
        for request in ok.requests { #expect(!request.url.absoluteString.contains(c.secret.revealed)) }

        for reply in [StubServer.Reply.status(401, "{}"), .status(500, "{}"), .status(200, "not json"), .failure(.timedOut)] {
            let failing = StubServer { $0.url.path == "/healthz" ? .status(200, Fixture.health) : reply }
            do {
                _ = try await c.make(failing).transcribe(audio: try audioFile(), hints: [], labelSpeakers: false)
                Issue.record("expected a failure for \(reply)")
            } catch {
                #expect(!allMessages(of: error).contains(c.secret.revealed))
            }
        }
        #expect(!String(reflecting: c.make(ok)).contains(c.secret.revealed))
    }
}
