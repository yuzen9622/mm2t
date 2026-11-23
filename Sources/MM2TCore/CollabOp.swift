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

private struct CollabJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

public struct CollabComponent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: CollabComponentKind
    public let title: String
    public let source: CollabSource
    public let building: Bool
    public let updatedAt: String
    public let fields: [String: CollabJSON]
    public let itemsByWireID: [CollabOp.Collection: [Data: [String: CollabJSON]]]

    private static let exactItemKeys = CodingUserInfoKey(rawValue: "CollabComponent.exactItemKeys")!

    public static func snapshotDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[exactItemKeys] = true
        decoder.keyDecodingStrategy = .custom { path in
            let key = path[path.count - 1]
            guard path.count == 4, path[0].stringValue == "components",
                  CollabOp.Collection(rawValue: path[2].stringValue) != nil else { return key }
            return CollabJSONKey(stringValue: Data(key.stringValue.utf8).base64EncodedString())
        }
        return decoder
    }

    private struct ItemMap: Decodable {
        let items: [Data: [String: CollabJSON]]

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CollabJSONKey.self)
            let escaped = decoder.userInfo[CollabComponent.exactItemKeys] as? Bool == true
            var items: [Data: [String: CollabJSON]] = [:]
            for key in c.allKeys {
                let id = escaped ? Data(base64Encoded: key.stringValue) : Data(key.stringValue.utf8)
                if let id { items[id] = try c.decode([String: CollabJSON].self, forKey: key) }
            }
            self.items = items
        }
    }

    public init(from decoder: any Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: CollabJSON].self)
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(CollabComponentKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        source = try c.decode(CollabSource.self, forKey: .source)
        building = try c.decode(Bool.self, forKey: .building)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        let raw = try decoder.container(keyedBy: CollabJSONKey.self)
        var items: [CollabOp.Collection: [Data: [String: CollabJSON]]] = [:]
        for key in raw.allKeys {
            if let collection = CollabOp.Collection(rawValue: key.stringValue) {
                items[collection] = try raw.decode(ItemMap.self, forKey: key).items
            }
        }
        itemsByWireID = items
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

        public func validates(_ item: [String: CollabJSON], partial: Bool = false) -> Bool {
            typealias Check = (CollabJSON) -> Bool
            func string(_ value: CollabJSON) -> Bool { if case .string = value { true } else { false } }
            func identifier(_ value: CollabJSON) -> Bool { if case .string(let id) = value { !id.isEmpty } else { false } }
            func choice(_ choices: [String]) -> Check {
                { if case .string(let value) = $0 { choices.contains(value) } else { false } }
            }
            func date(_ value: CollabJSON) -> Bool {
                guard case .string(let value) = value,
                      let match = value.wholeMatch(of: /([0-9]{4})-([0-9]{2})-([0-9]{2})/),
                      let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
                      (1...12).contains(month) else { return false }
                let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
                let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
                return (1...days[month - 1]).contains(day)
            }
            let required: [String: Check]
            let optional: [String: Check]
            switch self {
            case .nodes:
                required = ["label": string, "shape": choice(["box", "ellipse", "diamond", "note"])]
                optional = ["group": string]
            case .edges:
                required = ["from": identifier, "to": identifier]
                optional = ["label": string]
            case .options:
                required = ["label": string]
                optional = [:]
            case .tasks:
                required = ["name": string, "start": date, "end": date, "dependsOn": {
                    guard case .array(let values) = $0 else { return false }
                    return values.allSatisfy(identifier)
                }, "progress": { if case .number(let value) = $0 { (0...1).contains(value) } else { false } }]
                optional = ["owner": string]
            case .rows:
                required = ["task": string, "status": choice(["open", "done"])]
                optional = ["owner": string, "due": date]
            }
            guard let id = item["id"], identifier(id), partial || required.keys.allSatisfy({ item[$0] != nil }) else { return false }
            return item.allSatisfy { key, value in key == "id" || (required[key] ?? optional[key])?(value) == true }
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
    private enum Tag: String, Codable {
        case create, set, upsertItem, removeItem, appendText, replaceText, done, remove

        var payloadKeys: [Key] {
            switch self {
            case .create: [.kind, .title, .source]
            case .set: [.field, .value]
            case .upsertItem: [.collection, .item]
            case .removeItem: [.collection, .itemId]
            case .appendText, .replaceText: [.field, .text]
            case .done, .remove: []
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let id = try c.decode(String.self, forKey: .id)
        let tag = try c.decode(Tag.self, forKey: .op)
        let allowed = Set(([.op, .id] + tag.payloadKeys).map(\.rawValue))
        let raw = try decoder.container(keyedBy: CollabJSONKey.self)
        if let extra = raw.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
            throw DecodingError.dataCorruptedError(forKey: extra, in: raw, debugDescription: "Unexpected collaboration operation key")
        }
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
            guard collection.validates(item, partial: true) else { throw invalid(.item) }
            self = .upsertItem(id: id, collection: collection, item: item)
        case .removeItem:
            let itemID = try c.decode(String.self, forKey: .itemId)
            guard !itemID.isEmpty else { throw invalid(.itemId) }
            self = try .removeItem(id: id, collection: c.decode(Collection.self, forKey: .collection), itemId: itemID)
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
    private static let maxLineBytes = 512 * 1024
    private var pending = Data()
    private var discardingLine = false
    public private(set) var rejectedLines = 0

    public init() {}

    public struct ParsedOp: Sendable {
        public let op: CollabOp
        public let precedingRejectedLines: Int
    }

    public mutating func feed(_ fragment: String) -> [CollabOp] {
        feedWithRejections(fragment).map(\.op)
    }

    public mutating func feedWithRejections(_ fragment: String) -> [ParsedOp] {
        var result: [ParsedOp] = []
        for byte in fragment.utf8 {
            if byte == 10 {
                if let op = finishWithRejections() { result.append(op) }
            } else if !discardingLine {
                if pending.count == Self.maxLineBytes {
                    pending.removeAll(keepingCapacity: true)
                    discardingLine = true
                    rejectedLines += 1
                } else {
                    pending.append(byte)
                }
            }
        }
        return result
    }

    public mutating func finish() -> [CollabOp] {
        finishWithRejections().map { [$0.op] } ?? []
    }

    public mutating func finishWithRejections() -> ParsedOp? {
        defer {
            pending.removeAll(keepingCapacity: true)
            discardingLine = false
        }
        guard !discardingLine, !pending.isEmpty else { return nil }
        guard let op = parse(String(decoding: pending, as: UTF8.self)) else { return nil }
        return ParsedOp(op: op, precedingRejectedLines: rejectedLines)
    }

    private mutating func parse(_ line: String) -> CollabOp? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "```", text != "```json" else { return nil }
        if let op = try? JSONDecoder().decode(CollabOp.self, from: Data(text.utf8)) { return op }
        rejectedLines += 1
        return nil
    }
}
