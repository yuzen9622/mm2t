import Foundation
import MM2TProviders
import OSLog

actor CollabPendingEnds {
    struct Room: Codable, Hashable, Sendable {
        let apiURL: URL
        let owner: String
        let id: String
    }

    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Collaboration")
    private let file: URL
    private let sleep: @Sendable (Duration) async throws -> Void
    private var inFlight: Set<Room> = []

    init(file: URL, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.file = file
        self.sleep = sleep
    }

    func close(_ room: Room, service: CollabService) async {
        guard inFlight.insert(room).inserted else { return }
        defer { inFlight.remove(room) }
        remember(room, pending: true)
        let delays: [Duration] = [.seconds(2), .seconds(10), .seconds(30)]
        for attempt in 0...delays.count {
            do {
                if attempt > 0 { try await sleep(delays[attempt - 1]) }
                try await service.endRoom(room.id, owner: room.owner)
                remember(room, pending: false)
                return
            } catch {
                if Self.noLongerExists(error) {
                    remember(room, pending: false)
                    return
                }
                guard attempt < delays.count, Self.canRetry(error) else { break }
            }
        }
        if !Task.isCancelled { Self.logger.error("Could not end a collaboration room") }
    }

    func replay(apiURL: URL, owner: String, service: CollabService) async {
        do {
            for room in try read() where room.apiURL == apiURL && room.owner == owner {
                guard !Task.isCancelled else { return }
                await close(room, service: service)
            }
        } catch {
            Self.logger.error("Could not read pending collaboration room closures: \(String(describing: error), privacy: .private)")
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

    private func read() throws -> Set<Room> {
        do { return try JSONDecoder().decode(Set<Room>.self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    private func remember(_ room: Room, pending: Bool) {
        do {
            var rooms = try read()
            if pending {
                guard rooms.insert(room).inserted else { return }
            } else {
                guard rooms.remove(room) != nil else { return }
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(rooms).write(to: file, options: .atomic)
        } catch {
            Self.logger.error("Could not save pending collaboration room closures: \(String(describing: error), privacy: .private)")
        }
    }
}
