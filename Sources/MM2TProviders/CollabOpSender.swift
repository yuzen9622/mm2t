import Foundation
import MM2TCore

public actor CollabOpSender {
    private let send: @Sendable (CollabOpBatch) async throws -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pending: [CollabOp] = []
    private var pendingBytes = CollabOpSender.envelopeBytes
    private var ready: [CollabOpBatch] = []
    private var timer: Task<Void, Never>?
    private var timerID = 0
    private var worker: Task<Void, any Error>?
    private var failure: (any Error)?
    private var closed = false
    package private(set) var isSealed = false
    private static let envelopeBytes = #"{"batchId":"00000000-0000-0000-0000-000000000000","ops":[]}"#.utf8.count

    public static func fits(_ op: CollabOp) throws -> Bool {
        try bytes(of: op) + envelopeBytes <= CollabOpBatch.byteLimit
    }

    private static func bytes(of op: CollabOp) throws -> Int {
        try JSONEncoder().encode(op).count
    }

    private static func split(_ op: CollabOp) throws -> [CollabOp] {
        guard case .appendText(let id, let field, let text) = op else { return [] }
        let characters = Array(text)
        var start = 0
        var parts: [CollabOp] = []
        func part(endingAt end: Int) -> CollabOp {
            .appendText(id: id, field: field, text: String(characters[start..<end]))
        }
        while start < characters.count {
            var low = start
            var high = characters.count
            while low < high {
                let middle = low + (high - low + 1) / 2
                if try fits(part(endingAt: middle)) { low = middle }
                else { high = middle - 1 }
            }
            guard low > start else { return [] }
            if field == .markdown, low < characters.count,
               let line = characters[(start + (low - start) / 2)..<low].lastIndex(where: \.isNewline) {
                low = line + 1
            }
            parts.append(part(endingAt: low))
            start = low
        }
        return parts
    }

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                send: @escaping @Sendable (CollabOpBatch) async throws -> Void) {
        self.sleep = sleep
        self.send = send
    }

    @discardableResult
    public func append(_ op: CollabOp) throws -> Bool {
        if let failure { throw failure }
        guard !closed else { throw CancellationError() }
        let parts = try Self.fits(op) ? [op] : Self.split(op)
        for part in parts { try enqueue(part) }
        return !parts.isEmpty
    }

    private func enqueue(_ op: CollabOp) throws {
        let bytes = try Self.bytes(of: op)
        if pendingBytes + bytes + (pending.isEmpty ? 0 : 1) > CollabOpBatch.byteLimit { flush() }
        pendingBytes += bytes + (pending.isEmpty ? 0 : 1)
        pending.append(op)
        if pending.count == 20 { flush() }
        else if timer == nil {
            timerID += 1
            let id = timerID
            timer = Task {
                do { try await sleep(.milliseconds(150)) } catch { return }
                if id == timerID, !Task.isCancelled { flush() }
            }
        }
    }

    public func finish() async throws {
        closed = true
        flush()
        try await worker?.value
        if let failure { throw failure }
        if isSealed { throw CancellationError() }
    }

    public func close() async {
        discardQueued()
        _ = await worker?.result
    }

    private func discardQueued() {
        closed = true
        isSealed = true
        timer?.cancel()
        timer = nil
        pending.removeAll()
        ready.removeAll()
    }

    private func flush() {
        timer?.cancel()
        timer = nil
        guard !pending.isEmpty else { return }
        ready.append(CollabOpBatch(pending))
        pending = []
        pendingBytes = Self.envelopeBytes
        if worker == nil { worker = Task { try await drain() } }
    }

    private func drain() async throws {
        defer { worker = nil }
        do {
            while !ready.isEmpty {
                let batch = ready.removeFirst()
                for attempt in 0...2 {
                    guard !isSealed else { return }
                    do {
                        try await send(batch)
                        break
                    } catch {
                        switch error as? CollabError {
                        case .unreachable, .server(status: 429), .server(status: 500...599): break
                        default: throw error
                        }
                        if isSealed { return }
                        if attempt == 2 { throw error }
                    }
                }
            }
        } catch {
            failure = error
            discardQueued()
            throw error
        }
    }
}
