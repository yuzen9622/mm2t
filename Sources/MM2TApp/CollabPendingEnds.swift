import Foundation
import MM2TProviders
import OSLog

@MainActor
final class CollabPendingEnds {
    struct Room: Codable, Hashable, Sendable {
        let apiURL: URL
        let owner: String
        let id: String
    }

    nonisolated private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Collaboration")
    private let store: FileStore
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pending: Set<Room> = []
    private var unpersisted: Set<Room> = []
    var hasUnpersistedClosures: Bool { !unpersisted.isEmpty }
    var unpersistedRoomIDs: Set<String> { Set(unpersisted.map(\.id)) }
    private var draining: Set<Room> = []
    private var inFlight: Set<Room> = []

    nonisolated static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    init(file: URL, sleep: @escaping @Sendable (Duration) async throws -> Void,
         write: @escaping @Sendable (Data, URL) throws -> Void = CollabPendingEnds.writeAtomically) {
        store = FileStore(file: file, write: write)
        self.sleep = sleep
    }

    func reserve(_ room: Room) {
        draining.insert(room)
        pending.insert(room)
    }

    func record(_ room: Room) async throws {
        unpersisted.insert(room)
        let saved = try await store.persist(adding: room)
        unpersisted.subtract(saved)
    }

    func retryUnpersistedClosures() async throws {
        guard hasUnpersistedClosures else { return }
        let saved = try await store.persist()
        unpersisted.subtract(saved)
    }

    func close(_ room: Room, service: CollabService) async throws {
        draining.remove(room)
        guard inFlight.insert(room).inserted else { return }
        defer { inFlight.remove(room) }
        let delays: [Duration] = [.seconds(2), .seconds(10), .seconds(30)]
        for attempt in 0...delays.count {
            do {
                if attempt > 0 { try await sleep(delays[attempt - 1]) }
                try await service.endRoom(room.id, owner: room.owner)
            } catch {
                if !Self.noLongerExists(error) {
                    guard attempt < delays.count, Self.canRetry(error) else { throw error }
                    continue
                }
            }
            pending.remove(room)
            unpersisted.remove(room)
            let saved = try await store.persist(removing: room)
            unpersisted.subtract(saved)
            return
        }
    }

    func replay(apiURL: URL, owner: String, service: CollabService) async {
        let stored: Set<Room>
        do { stored = try await store.read() }
        catch {
            stored = []
            Self.logger.error("Could not read pending collaboration room closures: \(String(describing: error), privacy: .private)")
        }
        for room in stored.union(pending) where room.apiURL == apiURL && room.owner == owner {
            guard !Task.isCancelled else { return }
            guard !draining.contains(room) else { continue }
            do { try await close(room, service: service) }
            catch { Self.logger.error("Could not end a collaboration room: \(String(describing: error), privacy: .private)") }
        }
    }

    private static func noLongerExists(_ error: any Error) -> Bool {
        switch error as? CollabError {
        case .roomEnded, .server(status: 404), .server(status: 410): true
        default: false
        }
    }

    private static func canRetry(_ error: any Error) -> Bool {
        switch error as? CollabError {
        case .unreachable: true
        case .server(let status): (500...599).contains(status)
        default: false
        }
    }

    private actor FileStore {
        let file: URL
        private let write: @Sendable (Data, URL) throws -> Void
        private var unwritten: Set<Room> = []

        init(file: URL, write: @escaping @Sendable (Data, URL) throws -> Void) {
            self.file = file
            self.write = write
        }

        func read() throws -> Set<Room> {
            do { return try JSONDecoder().decode(Set<Room>.self, from: Data(contentsOf: file)) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        }

        func persist(adding added: Room? = nil, removing removed: Room? = nil) throws -> Set<Room> {
            if let added { unwritten.insert(added) }
            if let removed { unwritten.remove(removed) }
            do {
                let stored = try read()
                var rooms = stored.union(unwritten)
                if let removed { rooms.remove(removed) }
                if rooms != stored {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try write(JSONEncoder().encode(rooms), file)
                }
                let saved = unwritten
                unwritten.removeAll()
                return saved
            } catch {
                CollabPendingEnds.logger.error("Could not save pending collaboration room closures: \(String(describing: error), privacy: .private)")
                throw CollabError.pendingEndPersistence
            }
        }
    }
}
