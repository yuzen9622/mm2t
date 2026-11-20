import Foundation
import MM2TCore
import MM2TProviders
import Testing

struct CollabOpSenderTests {
    @Test func timerStartsAtFirstOperationAndReleasesPartialBatch() async throws {
        let (timerStarted, started) = AsyncStream.makeStream(of: Duration.self, bufferingPolicy: .bufferingNewest(1))
        let (timerTicks, tick) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let batches = Batches()
        let sender = CollabOpSender(sleep: { duration in
            started.yield(duration)
            for await _ in timerTicks { return }
            throw CancellationError()
        }, send: { await batches.record($0) })
        try await sender.append(.done(id: "first"))
        var times = timerStarted.makeAsyncIterator()
        #expect(await times.next() == .milliseconds(150))
        try await sender.append(.done(id: "second"))
        #expect(await batches.calls.isEmpty)
        tick.yield(())
        for _ in 0..<200 where await batches.calls.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await batches.calls == [["first", "second"]])
        try await sender.finish()
        tick.finish()
        started.finish()
    }

    @Test func sizeFlushesImmediatelyAndRequestsAreSequentialDespiteRetry() async throws {
        let recorder = Batches(failures: 2)
        let sender = CollabOpSender(sleep: { _ in try await Task.sleep(for: .seconds(30)) }, send: { try await recorder.send($0) })
        let ids = (0..<45).map { "row-\($0)" }
        for id in ids { try await sender.append(.done(id: id)) }
        for _ in 0..<200 where await recorder.calls.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await recorder.calls.first == Array(ids[..<20]))
        try await sender.finish()
        #expect(await recorder.calls == Array(repeating: Array(ids[..<20]), count: 3) + [Array(ids[20..<40]), Array(ids[40...])])
        #expect(await recorder.peakInFlight == 1)
    }

    @Test func thirdFailureIsReportedAndDependentBatchIsNotSent() async throws {
        let recorder = Batches(failures: 3)
        let sender = CollabOpSender(sleep: { _ in try await Task.sleep(for: .seconds(30)) }, send: { try await recorder.send($0) })
        let ids = (0..<21).map { "row-\($0)" }
        for id in ids { try await sender.append(.done(id: id)) }
        await #expect(throws: CollabError.unreachable) { try await sender.finish() }
        #expect(await recorder.calls == Array(repeating: Array(ids[..<20]), count: 3))
    }

    @Test func serverByteLimitAlsoSplitsBatches() async throws {
        let recorder = Batches()
        let sender = CollabOpSender(sleep: { _ in try await Task.sleep(for: .seconds(30)) }, send: { await recorder.record($0) })
        for id in ["a", "b"] {
            try await sender.append(.appendText(id: id, field: .markdown, text: String(repeating: "頁", count: 50_000)))
        }
        try await sender.finish()
        #expect(await recorder.calls == [["a"], ["b"]])
    }

    private actor Batches {
        var calls: [[String]] = []
        var inFlight = 0
        var peakInFlight = 0
        var failures: Int
        init(failures: Int = 0) { self.failures = failures }
        func record(_ ops: [CollabOp]) { calls.append(ops.map(\.id)) }
        func send(_ ops: [CollabOp]) async throws {
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            defer { inFlight -= 1 }
            record(ops)
            try await Task.sleep(for: .milliseconds(3))
            if failures > 0 { failures -= 1; throw CollabError.unreachable }
        }
    }
}
