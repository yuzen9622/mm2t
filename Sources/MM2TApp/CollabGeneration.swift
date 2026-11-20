import MM2TCore

struct CollabGeneration {
    private enum Mode { case command(newID: String, source: CollabSource), update }
    private let mode: Mode
    private let components: [CollabComponent]
    private var kind: CollabComponentKind?
    private var modelID: String?
    private var changed = false
    private var removed = false
    private(set) var target: String?
    private(set) var title: String?
    private(set) var created = false
    private(set) var finished = false
    private(set) var rejected = 0

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

    mutating func accept(_ op: CollabOp) -> CollabOp? {
        if finished { rejected += 1; return nil }
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
            select(existing)
        }
        guard let target, let kind, op.id == modelID, allowed(op, for: kind) else { rejected += 1; return nil }
        switch op {
        case .done:
            finished = true
            return changed && !removed ? op.targeting(target) : nil
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
