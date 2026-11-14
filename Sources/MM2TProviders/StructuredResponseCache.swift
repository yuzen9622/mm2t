import Foundation
import OSLog

/// Shared by copies of one provider, so recording checkpoints and final processing reuse the
/// same validated requests. Nothing is persisted or shared with another provider instance.
actor StructuredResponseCache {
    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Processing")
    struct Key: Hashable, Sendable {
        let system: String
        let input: String
        let schema: String

        var byteCount: Int { system.utf8.count + input.utf8.count + schema.utf8.count }
    }

    private struct Entry {
        let response: String
        let byteCount: Int
        var lastUsed: UInt64
    }

    private struct Pending {
        let id = UUID()
        let task: Task<String, any Error>
    }

    private let maxEntries: Int
    private let maxBytes: Int
    private let maxInFlight: Int
    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: Pending] = [:]
    private var byteCount = 0
    private var clock: UInt64 = 0

    init(maxEntries: Int = 128, maxBytes: Int = 8 * 1_024 * 1_024, maxInFlight: Int = 24) {
        precondition(maxEntries > 0 && maxBytes > 0 && maxInFlight > 0)
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
        self.maxInFlight = maxInFlight
    }

    /// `generate` must validate the response before returning. A failure is never memoized.
    func response(for key: Key, generate: @escaping @Sendable () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        // Bound unfinished work as well as completed responses. A second caller for the same
        // request shares its task; cancelling one caller does not cancel work another needs.
        let pending: Pending
        while true {
            if var cached = entries[key] {
                clock &+= 1
                cached.lastUsed = clock
                entries[key] = cached
                return cached.response
            }
            if let existing = inFlight[key] {
                pending = existing
                break
            }
            if inFlight.count < maxInFlight {
                pending = Pending(task: Task { try await generate() })
                inFlight[key] = pending
                break
            }
            guard let other = inFlight.first else { continue }
            _ = try? await finish(other.value, for: other.key)
            try Task.checkCancellation()
        }
        let response = try await finish(pending, for: key)
        try Task.checkCancellation()
        return response
    }

    private func finish(_ pending: Pending, for key: Key) async throws -> String {
        do {
            let response = try await pending.task.value
            if inFlight[key]?.id == pending.id {
                inFlight[key] = nil
                insert(response, for: key)
            }
            return response
        } catch {
            if inFlight[key]?.id == pending.id {
                inFlight[key] = nil
                if let provider = error as? ProviderError {
                    Self.logger.notice("event=llm_request_failed service=\(String(describing: provider.service), privacy: .public) kind=\(String(describing: provider.kind), privacy: .public)")
                } else {
                    Self.logger.notice("event=llm_request_failed error_type=\(String(reflecting: type(of: error)), privacy: .public)")
                }
            }
            throw error
        }
    }

    private func insert(_ response: String, for key: Key) {
        let size = key.byteCount + response.utf8.count
        guard size <= maxBytes else { return }
        while entries.count >= maxEntries || byteCount + size > maxBytes {
            guard let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { break }
            entries[oldest.key] = nil
            byteCount -= oldest.value.byteCount
        }
        clock &+= 1
        entries[key] = Entry(response: response, byteCount: size, lastUsed: clock)
        byteCount += size
    }
}
