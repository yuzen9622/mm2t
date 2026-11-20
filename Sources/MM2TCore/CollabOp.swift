import Foundation

public enum CollabComponentKind: String, Codable, Sendable, CaseIterable {
    case whiteboard, poll, gantt, actions, document, experimental

    public var updatesLive: Bool { self != .poll && self != .experimental }
}

public enum CollabSource: String, Codable, Sendable { case command, suggestion }

public indirect enum CollabJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([Self]), object([String: Self])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String: Self].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

public struct CollabComponent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: CollabComponentKind
    public let title: String
    public let source: CollabSource
    public let building: Bool
    public let updatedAt: String
    public let fields: [String: CollabJSON]

    public init(from decoder: any Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: CollabJSON].self)
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(CollabComponentKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        source = try c.decode(CollabSource.self, forKey: .source)
        building = try c.decode(Bool.self, forKey: .building)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(fields)
    }

    private enum Key: String, CodingKey { case id, kind, title, source, building, updatedAt }
}

public enum CollabOp: Codable, Equatable, Sendable {
    public enum Field: String, Codable, Sendable { case title, question, multiple, closed }
    public enum TextField: String, Codable, Sendable { case markdown, html }
    public enum Collection: String, Codable, Sendable {
        case nodes, edges, options, tasks, rows

        fileprivate func validates(_ item: [String: CollabJSON]) -> Bool {
            func check(_ field: String, _ valid: (CollabJSON) -> Bool) -> Bool { item[field].map(valid) ?? true }
            func string(_ field: String) -> Bool { check(field) { if case .string = $0 { true } else { false } } }
            func choice(_ field: String, _ choices: [String]) -> Bool {
                check(field) { if case .string(let value) = $0 { choices.contains(value) } else { false } }
            }
            func date(_ field: String) -> Bool {
                check(field) { if case .string(let value) = $0 { value.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil } else { false } }
            }
            guard case .string(let id) = item["id"], !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            switch self {
            case .nodes: return string("label") && string("group") && choice("shape", ["box", "ellipse", "diamond", "note"])
            case .edges: return string("from") && string("to") && string("label")
            case .options: return string("label")
            case .tasks:
                return string("name") && string("owner") && date("start") && date("end") && check("dependsOn") {
                    guard case .array(let values) = $0 else { return false }
                    return values.allSatisfy { if case .string = $0 { true } else { false } }
                } && check("progress") { if case .number(let value) = $0 { (0...1).contains(value) } else { false } }
            case .rows: return string("task") && string("owner") && date("due") && choice("status", ["open", "done"])
            }
        }
    }

    case create(id: String, kind: CollabComponentKind, title: String, source: CollabSource)
    case set(id: String, field: Field, value: CollabJSON)
    case upsertItem(id: String, collection: Collection, item: [String: CollabJSON])
    case removeItem(id: String, collection: Collection, itemId: String)
    case appendText(id: String, field: TextField, text: String)
    case replaceText(id: String, field: TextField, text: String)
    case done(id: String)
    case remove(id: String)

    public var id: String {
        switch self {
        case .create(let id, _, _, _), .set(let id, _, _), .upsertItem(let id, _, _), .removeItem(let id, _, _),
             .appendText(let id, _, _), .replaceText(let id, _, _), .done(let id), .remove(let id): id
        }
    }

    public func targeting(_ id: String) -> Self {
        switch self {
        case .create(_, let k, let t, let s): .create(id: id, kind: k, title: t, source: s)
        case .set(_, let f, let v): .set(id: id, field: f, value: v)
        case .upsertItem(_, let c, let i): .upsertItem(id: id, collection: c, item: i)
        case .removeItem(_, let c, let i): .removeItem(id: id, collection: c, itemId: i)
        case .appendText(_, let f, let t): .appendText(id: id, field: f, text: t)
        case .replaceText(_, let f, let t): .replaceText(id: id, field: f, text: t)
        case .done: .done(id: id)
        case .remove: .remove(id: id)
        }
    }

    private enum Key: String, CodingKey { case op, id, kind, title, source, field, value, collection, item, itemId, text }
    private enum Tag: String, Codable { case create, set, upsertItem, removeItem, appendText, replaceText, done, remove }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let id = try c.decode(String.self, forKey: .id)
        let tag = try c.decode(Tag.self, forKey: .op)
        func invalid(_ key: Key) -> DecodingError { .dataCorruptedError(forKey: key, in: c, debugDescription: "Invalid collaboration operation") }
        guard id.wholeMatch(of: /[a-z0-9-]{1,40}/) != nil else { throw invalid(.id) }
        switch tag {
        case .create:
            self = try .create(id: id, kind: c.decode(CollabComponentKind.self, forKey: .kind),
                               title: c.decode(String.self, forKey: .title), source: c.decode(CollabSource.self, forKey: .source))
        case .set:
            let field = try c.decode(Field.self, forKey: .field)
            let value = try c.decode(CollabJSON.self, forKey: .value)
            switch (field, value) {
            case (.title, .string), (.question, .string), (.multiple, .bool), (.closed, .bool): break
            default: throw invalid(.value)
            }
            self = .set(id: id, field: field, value: value)
        case .upsertItem:
            let collection = try c.decode(Collection.self, forKey: .collection)
            let item = try c.decode([String: CollabJSON].self, forKey: .item)
            guard collection.validates(item) else { throw invalid(.item) }
            self = .upsertItem(id: id, collection: collection, item: item)
        case .removeItem:
            self = try .removeItem(id: id, collection: c.decode(Collection.self, forKey: .collection), itemId: c.decode(String.self, forKey: .itemId))
        case .appendText, .replaceText:
            let field = try c.decode(TextField.self, forKey: .field)
            let text = try c.decode(String.self, forKey: .text)
            self = tag == .appendText ? .appendText(id: id, field: field, text: text) : .replaceText(id: id, field: field, text: text)
        case .done: self = .done(id: id)
        case .remove: self = .remove(id: id)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id)
        let tag: Tag
        switch self {
        case .create(_, let kind, let title, let source):
            tag = .create
            try c.encode(kind, forKey: .kind)
            try c.encode(title, forKey: .title)
            try c.encode(source, forKey: .source)
        case .set(_, let field, let value):
            tag = .set
            try c.encode(field, forKey: .field)
            try c.encode(value, forKey: .value)
        case .upsertItem(_, let collection, let item):
            tag = .upsertItem
            try c.encode(collection, forKey: .collection)
            try c.encode(item, forKey: .item)
        case .removeItem(_, let collection, let itemID):
            tag = .removeItem
            try c.encode(collection, forKey: .collection)
            try c.encode(itemID, forKey: .itemId)
        case .appendText(_, let field, let text), .replaceText(_, let field, let text):
            if case .appendText = self { tag = .appendText } else { tag = .replaceText }
            try c.encode(field, forKey: .field)
            try c.encode(text, forKey: .text)
        case .done: tag = .done
        case .remove: tag = .remove
        }
        try c.encode(tag, forKey: .op)
    }
}

public struct CollabOpStreamParser: Sendable {
    private var pending = ""
    public private(set) var rejectedLines = 0

    public init() {}

    public mutating func feed(_ fragment: String) -> [CollabOp] {
        pending += fragment
        let lines = pending.components(separatedBy: "\n")
        pending = lines.last ?? ""
        return lines.dropLast().compactMap { parse($0) }
    }

    public mutating func finish() -> [CollabOp] {
        let line = pending
        pending = ""
        return parse(line).map { [$0] } ?? []
    }

    private mutating func parse(_ line: String) -> CollabOp? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "```", text != "```json" else { return nil }
        if let op = try? JSONDecoder().decode(CollabOp.self, from: Data(text.utf8)) { return op }
        rejectedLines += 1
        return nil
    }
}
