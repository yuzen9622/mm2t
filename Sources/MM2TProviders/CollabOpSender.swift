import Foundation
import MM2TCore

public actor CollabOpSender {
    private let send: @Sendable ([CollabOp]) async throws -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pending: [CollabOp] = []
    private var pendingBytes = 10
    private var ready: [[CollabOp]] = []
    private var timer: Task<Void, Never>?
    private var timerID = 0
    private var worker: Task<Void, any Error>?
    private var failure: (any Error)?
    private var closed = false

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                send: @escaping @Sendable ([CollabOp]) async throws -> Void) {
        self.sleep = sleep
        self.send = send
    }

    public func append(_ op: CollabOp) throws {
        if let failure { throw failure }
        guard !closed else { throw CancellationError() }
        let bytes = try JSONEncoder().encode(op).count + 1
        guard bytes + 10 <= 256_000 else { throw CollabError.server(status: 400) }
        if pendingBytes + bytes > 256_000 { flush() }
        pending.append(op)
        pendingBytes += bytes
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
    }

    public func cancel() {
        closed = true
        timer?.cancel()
        worker?.cancel()
        pending.removeAll()
        ready.removeAll()
    }

    private func flush() {
        timer?.cancel()
        timer = nil
        guard !pending.isEmpty else { return }
        ready.append(pending)
        pending = []
        pendingBytes = 10
        if worker == nil { worker = Task { try await drain() } }
    }

    private func drain() async throws {
        defer { worker = nil }
        do {
            while !ready.isEmpty {
                let batch = ready.removeFirst()
                for attempt in 0...2 {
                    try Task.checkCancellation()
                    do {
                        try await send(batch)
                        break
                    } catch {
                        if attempt == 2 { throw error }
                    }
                }
            }
        } catch {
            failure = error
            cancel()
            throw error
        }
    }
}
