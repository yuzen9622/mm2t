import Foundation
import Testing
@testable import MM2TProviders

@Suite struct StructuredResponseCacheTests {
    private actor Calls {
        var count = 0
        var active = 0
        var peak = 0
        func next() -> String { count += 1; return String(count) }
        func begin() { active += 1; peak = max(peak, active) }
        func end() { active -= 1 }
    }

    private func key(_ input: String, system: String = "system", schema: String = "schema") -> StructuredResponseCache.Key {
        .init(system: system, input: input, schema: schema)
    }

    @Test func exactRequestsReuseResponsesAndEveryPromptComponentMatters() async throws {
        let cache = StructuredResponseCache()
        let calls = Calls()
        let first = try await cache.response(for: key("input")) { await calls.next() }
        #expect(try await cache.response(for: key("input")) { await calls.next() } == first)
        for changed in [key("changed"), key("input", system: "changed"), key("input", schema: "changed")] {
            #expect(try await cache.response(for: changed) { await calls.next() } != first)
        }
        #expect(await calls.count == 4)
    }

    @Test func simultaneousRequestsShareGeneration() async throws {
        let cache = StructuredResponseCache()
        let calls = Calls()
        let request = key("same")
        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await cache.response(for: request) {
                        let value = await calls.next()
                        // Yield while the shared operation is unfinished so other callers can join.
                        for _ in 0..<20 { await Task.yield() }
                        return value
                    }
                }
            }
            var outputs: [String] = []
            for try await output in group { outputs.append(output) }
            return outputs
        }
        #expect(outputs.count == 32)
        #expect(Set(outputs) == ["1"])
        #expect(await calls.count == 1)
    }

    @Test func failedRequestsCanBeRetried() async throws {
        enum Failed: Error { case request }
        let cache = StructuredResponseCache()
        let calls = Calls()
        let request = key("retry")
        await #expect(throws: Failed.self) {
            try await cache.response(for: request) {
                _ = await calls.next()
                throw Failed.request
            }
        }
        #expect(try await cache.response(for: request) { await calls.next() } == "2")
        #expect(try await cache.response(for: request) { await calls.next() } == "2")
        #expect(await calls.count == 2)
    }

    @Test func evictsLeastRecentlyUsedResponsesAtTheEntryLimit() async throws {
        let cache = StructuredResponseCache(maxEntries: 2)
        let calls = Calls()
        _ = try await cache.response(for: key("a")) { await calls.next() }
        _ = try await cache.response(for: key("b")) { await calls.next() }
        #expect(try await cache.response(for: key("a")) { await calls.next() } == "1")
        _ = try await cache.response(for: key("c")) { await calls.next() }
        #expect(try await cache.response(for: key("b")) { await calls.next() } == "4")
    }

    @Test func oversizedResponsesAreNotRetainedAndInflightWorkRemainsBounded() async throws {
        let cache = StructuredResponseCache(maxBytes: 1, maxInFlight: 1)
        let calls = Calls()
        let request = key("large")
        #expect(try await cache.response(for: request) { await calls.next() } == "1")
        #expect(try await cache.response(for: request) { await calls.next() } == "2")
        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                let request = key("\(index)")
                group.addTask {
                    try await cache.response(for: request) {
                        await calls.begin()
                        for _ in 0..<10 { await Task.yield() }
                        let value = await calls.next()
                        await calls.end()
                        return value
                    }
                }
            }
            var outputs: [String] = []
            for try await output in group { outputs.append(output) }
            return outputs
        }
        #expect(outputs.count == 8)
        #expect(await calls.count == 10)
        #expect(await calls.peak == 1)
    }
}
