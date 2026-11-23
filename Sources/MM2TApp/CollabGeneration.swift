import Foundation
import MM2TCore
import MM2TProviders
import OSLog

struct CollabGeneration: Sendable {
    private enum Mode: Sendable { case command(newID: String, source: CollabSource), update }
    private let mode: Mode
    private let components: [CollabComponent]
    private var kind: CollabComponentKind?
    private var modelID: String?
    private var items: [CollabOp.Collection: [Data: [String: CollabJSON]]] = [:]
    private var changed = false
    private(set) var removed = false
    private(set) var target: String?
    private(set) var title: String?
    private(set) var created = false
    private(set) var finished = false
    private(set) var rejected = 0
    var needsCleanup: Bool { changed }

    init(components: [CollabComponent], newID: String, source: CollabSource, retrying: CollabComponent? = nil) {
        self.components = components
        mode = .command(newID: newID, source: source)
        if let retrying { select(retrying) }
    }

    init(updating component: CollabComponent) {
        mode = .update
        components = []
        select(component)
    }

    mutating func accept(_ op: CollabOp) throws -> CollabOp? {
        if finished { rejected += 1; return nil }
        let wireOp: CollabOp
        if case .create(_, let kind, let title, _) = op, case .command(let newID, let source) = mode {
            wireOp = .create(id: newID, kind: kind, title: title, source: source)
        } else {
            wireOp = op.targeting(target ?? op.id)
        }
        if case .appendText = op { return route(op) }
        guard try CollabOpSender.fits(wireOp) else {
            rejected += 1
            return nil
        }
        return route(op)
    }

    private mutating func route(_ op: CollabOp) -> CollabOp? {
        if case .create(let id, let kind, let title, _) = op {
            guard target == nil, case .command(let newID, let source) = mode, !title.isEmpty else { rejected += 1; return nil }
            modelID = id
            target = newID
            self.kind = kind
            self.title = title
            changed = true
            created = true
            return .create(id: newID, kind: kind, title: title, source: source)
        }
        if target == nil, case .command(_, .command) = mode, let existing = components.first(where: { $0.id == op.id }),
           allowed(op, for: existing.kind) {
            var candidate = self
            candidate.select(existing)
            let approved = candidate.route(op)
            guard candidate.rejected == rejected else { rejected += 1; return nil }
            self = candidate
            return approved
        }
        guard let target, let kind, op.id == modelID, allowed(op, for: kind) else { rejected += 1; return nil }
        switch op {
        case .done:
            finished = true
            return changed && !removed ? op.targeting(target) : nil
        case .upsertItem(_, let collection, let fields):
            guard case .string(let itemID) = fields["id"] else { rejected += 1; return nil }
            let key = Data(itemID.utf8)
            let merged = (items[collection]?[key] ?? [:]).merging(fields) { _, patch in patch }
            guard collection.validates(merged) else { rejected += 1; return nil }
            items[collection, default: [:]][key] = merged
        case .removeItem(_, let collection, let itemID):
            items[collection]?.removeValue(forKey: Data(itemID.utf8))
        case .remove:
            removed = true
        case .set(_, .title, .string(let title)):
            self.title = title
        default: break
        }
        changed = true
        return op.targeting(target)
    }

    private mutating func select(_ component: CollabComponent) {
        modelID = component.id
        target = component.id
        kind = component.kind
        title = component.title
        items = component.itemsByWireID
    }

    private func allowed(_ op: CollabOp, for kind: CollabComponentKind) -> Bool {
        if removed { if case .done = op { return true }; return false }
        switch op {
        case .create: return false
        case .remove:
            if case .command(let newID, .command) = mode { return target != newID }
            return false
        case .done: return true
        case .set(_, let field, _): return field == .title || kind == .poll
        case .upsertItem(_, let collection, _), .removeItem(_, let collection, _):
            switch (kind, collection) {
            case (.whiteboard, .nodes), (.whiteboard, .edges), (.poll, .options), (.gantt, .tasks), (.actions, .rows): return true
            default: return false
            }
        case .appendText(_, let field, _):
            if case .update = mode { return false }
            return Self.allows(field, for: kind)
        case .replaceText(_, let field, _): return Self.allows(field, for: kind)
        }
    }

    private static func allows(_ field: CollabOp.TextField, for kind: CollabComponentKind) -> Bool {
        (kind == .document && field == .markdown) || (kind == .experimental && field == .html)
    }
}

actor CollabModelWork {
    enum Failure: Error { case modelNotConfigured, invalidOutput }

    private struct SuggestionResponse: Decodable {
        let suggestion: CollabSuggestion?
        private enum Key: String, CodingKey { case suggest }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            suggestion = try c.decode(Bool.self, forKey: .suggest) ? CollabSuggestion(from: decoder) : nil
        }
    }

    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Collaboration")
    private let makeLLM: @Sendable () throws -> LLMBuild
    private(set) var generation: CollabGeneration?

    init(makeLLM: @escaping @Sendable () throws -> LLMBuild) {
        self.makeLLM = makeLLM
    }

    static func promptFields(_ component: CollabComponent) -> [String: CollabJSON] {
        var fields = component.fields.filter { !["votes", "elements", "createdAt", "updatedAt", "rev", "building"].contains($0.key) }
        for (collection, items) in component.itemsByWireID {
            fields[collection.rawValue] = .array(items.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map { .object($0.value) })
        }
        return fields
    }

    private func provider() async throws -> any LLMProvider {
        try Task.checkCancellation()
        guard case .ready(let provider) = try makeLLM() else { throw Failure.modelNotConfigured }
        return await provider.forGeneration()
    }

    func suggestion(input: @Sendable () -> [String: CollabJSON]) async throws -> CollabSuggestion? {
        let provider = try await provider()
        let payload = try CollabPrompts.input(input())
        try Task.checkCancellation()
        var answer = ""
        for try await fragment in provider.streamText(system: CollabPrompts.suggestion, input: payload) {
            try Task.checkCancellation()
            answer += fragment
        }
        return try JSONDecoder().decode(SuggestionResponse.self, from: Data(answer.utf8)).suggestion
    }

    func stream(system: String, route makeRoute: @Sendable () -> CollabGeneration,
                input: @Sendable () -> [String: CollabJSON], sender: CollabOpSender,
                onTitle: @MainActor @Sendable (String?) -> Void) async throws -> CollabGeneration {
        var route = makeRoute()
        var parser = CollabOpStreamParser()
        var oversized = 0
        var rejectedBeforeDone = 0
        defer {
            generation = route
            let discarded = parser.rejectedLines + route.rejected + oversized
            if discarded > 0 { Self.logger.notice("Discarded collaboration op lines: \(discarded, privacy: .public)") }
        }
        let provider = try await provider()
        let payload = try CollabPrompts.input(input())
        try Task.checkCancellation()
        var previousTitle: String?
        var fragments = provider.streamText(system: system, input: payload).makeAsyncIterator()
        while true {
            try Task.checkCancellation()
            let fragment = try await fragments.next()
            let ops = fragment.map { parser.feedWithRejections($0) } ?? (parser.finishWithRejections().map { [$0] } ?? [])
            for parsed in ops {
                try Task.checkCancellation()
                let op = parsed.op
                let wasFinished = route.finished
                let beforeAppend: CollabGeneration? = if case .appendText = op, !wasFinished { route } else { nil }
                if let approved = try route.accept(op), try await !sender.append(approved) {
                    if let beforeAppend { route = beforeAppend }
                    oversized += 1
                }
                if !wasFinished, route.finished {
                    rejectedBeforeDone = parsed.precedingRejectedLines + route.rejected + oversized
                }
                if route.title != previousTitle {
                    previousTitle = route.title
                    await onTitle(route.title)
                }
            }
            if fragment == nil { break }
        }
        guard route.finished, route.needsCleanup || rejectedBeforeDone == 0 else {
            throw Failure.invalidOutput
        }
        try Task.checkCancellation()
        try await sender.finish()
        try Task.checkCancellation()
        return route
    }
}
