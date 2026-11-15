import Foundation
import MM2TCore
import OSLog

public actor SearchIndexSync {
    private let library: MeetingLibrary
    private let index: MeetingIndex
    private let voiceprints: VoiceprintStore
    private var worker: Task<Void, Never>?
    private var continuation: AsyncStream<MeetingID>.Continuation?
    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Search")

    public init(library: MeetingLibrary, index: MeetingIndex, voiceprints: VoiceprintStore) {
        self.library = library
        self.index = index
        self.voiceprints = voiceprints
    }

    deinit { continuation?.finish(); worker?.cancel() }

    public func start() async {
        guard continuation == nil else { return }
        let (stream, continuation) = AsyncStream<MeetingID>.makeStream()
        self.continuation = continuation
        await library.observe { id in continuation.yield(id) }
        do {
            try await index.reconcile(from: library.indexRecords(), user: voiceprints.user()?.id)
        } catch { Self.logger.error("Search reconciliation failed: \(String(describing: error), privacy: .public)") }
        worker = Task { [library, index, voiceprints] in
            for await id in stream {
                guard !Task.isCancelled else { return }
                do {
                    if let record = try await library.indexRecord(id) {
                        try await index.update(record.meeting, modified: record.modified, user: voiceprints.user()?.id)
                    } else { try await index.remove(id) }
                } catch { Self.logger.error("Search update failed: \(String(describing: error), privacy: .public)") }
            }
        }
    }
}
