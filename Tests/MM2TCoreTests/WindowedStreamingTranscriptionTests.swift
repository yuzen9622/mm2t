import Foundation
import Testing
@testable import MM2TCore

@Suite struct WindowedStreamingTranscriptionTests {
    static let rate = 16_000
    let request = StreamingTranscriptionRequest(languageCode: "zh", hints: ["王小明"], sampleRate: rate)

    func speech(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(Self.rate))).map { 0.1 * sin(Float($0) * 0.2) }
    }

    func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(Self.rate)))
    }

    func seconds(_ clip: [Float]) -> Double {
        (Double(clip.count) / Double(Self.rate) * 10).rounded() / 10
    }

    // MARK: Window

    @Test func silenceIsNeverDecoded() {
        var window = SpeechWindow(sampleRate: Self.rate)
        #expect(window.append(silence(5)).isEmpty)
        #expect(window.takePartial() == nil)
    }

    @Test func aPauseSettlesTheSegmentWithAShortLeadIn() {
        var window = SpeechWindow(sampleRate: Self.rate)
        _ = window.append(silence(2))
        #expect(window.append(speech(1)).isEmpty)
        let partial = window.takePartial()
        #expect(partial.map(seconds) == 1.3)
        #expect(window.takePartial() == nil, "nothing new since the last partial")

        #expect(window.append(silence(1)).map(seconds) == [2.0])
        #expect(window.takePartial() == nil)
    }

    @Test func aLongSegmentIsCutAtItsQuietestMomentAndTheRestCarriesOn() {
        var window = SpeechWindow(sampleRate: Self.rate)
        let settled = window.append(speech(12) + silence(0.3) + speech(4))
        #expect(settled.map(seconds) == [12])
        let partial = window.takePartial()
        #expect(partial.map(seconds) == 4.3)
    }

    // MARK: Session

    @Test func partialsGrowAndThePauseSettlesThem() async throws {
        let clips = FakeClips()
        let session = try await WindowedStreamingTranscription(clips).open(request)
        var events = session.events.makeAsyncIterator()

        try await session.send(speech(1))
        #expect(try await events.next() == .partial("1.0s"))
        try await session.send(silence(1))
        #expect(try await events.next() == .final("1.7s"))
        #expect(clips.requests.get.allSatisfy { $0 == request })
        await session.close()
        #expect(try await events.next() == nil)
    }

    @Test func aSlowModelSkipsStalePartialsButSettlesEverySegmentInOrder() async throws {
        let clips = FakeClips(delay: .milliseconds(50))
        let session = try await WindowedStreamingTranscription(clips).open(request)
        let audio = speech(3) + silence(1) + speech(1) + silence(1)
        for start in stride(from: 0, to: audio.count, by: 1_600) {
            try await session.send(Array(audio[start..<min(start + 1_600, audio.count)]))
        }

        var received: [StreamingTranscriptEvent] = []
        for try await event in session.events {
            received.append(event)
            if received.filter(\.isFinal).count == 2 { break }
        }
        #expect(received.filter(\.isFinal) == [.final("3.7s"), .final("2.0s")])
        #expect(received.count <= 4, "only the newest partial is decoded while the model is busy")
        await session.close()
    }

    @Test func aDecodingFailureEndsTheStreamWithIt() async throws {
        let clips = FakeClips(failure: .failed("engine error"))
        let session = try await WindowedStreamingTranscription(clips).open(request)
        try await session.send(speech(1))
        await #expect(throws: TranscriptionError.failed("engine error")) {
            for try await _ in session.events {}
        }
    }

    // MARK: Chain

    @Test func captionsFallThroughUnreachableSourcesInOrder() async throws {
        let server = FakeClips(prepareFailure: .unreachable("offline")), mac = FakeClips()
        let chain = StreamingTranscriptionChain([
            .init(.selfHosted, WindowedStreamingTranscription(server)), .init(.local, WindowedStreamingTranscription(mac)),
        ])
        let session = try await chain.open(request)
        try await session.send(speech(1))
        var events = session.events.makeAsyncIterator()
        #expect(try await events.next() == .partial("1.0s"))
        #expect(server.prepared.get == 1 && mac.prepared.get == 1)
        #expect(server.requests.get.isEmpty)
        await session.close()
    }

    @Test func aSourceThatFailsForGoodStopsTheChain() async throws {
        let cloud = FakeClips(prepareFailure: .failed("invalid API key")), mac = FakeClips()
        let chain = StreamingTranscriptionChain([
            .init(.cloud, WindowedStreamingTranscription(cloud)), .init(.local, WindowedStreamingTranscription(mac)),
        ])
        await #expect(throws: TranscriptionError.failed("invalid API key")) { try await chain.open(request) }
        #expect(mac.prepared.get == 0)
    }
}

private extension StreamingTranscriptEvent {
    var isFinal: Bool { if case .final = self { true } else { false } }
}

/// Answers each clip with its length, "1.3s", after an optional delay.
private final class FakeClips: ClipTranscriber, @unchecked Sendable {
    let delay: Duration?
    let failure: TranscriptionError?
    let prepareFailure: TranscriptionError?
    let prepared = Box(0)
    let requests = Box<[StreamingTranscriptionRequest]>([])

    init(delay: Duration? = nil, failure: TranscriptionError? = nil, prepareFailure: TranscriptionError? = nil) {
        self.delay = delay
        self.failure = failure
        self.prepareFailure = prepareFailure
    }

    func prepare() async throws {
        prepared.update { $0 += 1 }
        if let prepareFailure { throw prepareFailure }
    }

    func transcribe(clip samples: [Float], request: StreamingTranscriptionRequest) async throws -> String {
        requests.update { $0.append(request) }
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        let seconds = (Double(samples.count) / Double(request.sampleRate) * 10).rounded() / 10
        return "\(seconds)s"
    }
}
