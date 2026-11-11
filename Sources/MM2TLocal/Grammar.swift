import Foundation
import MM2TProviders

/// llama.cpp GBNF for the JSON-schema subset `LLMPrompts` uses: objects whose properties are all
/// required and appear in schema order, arrays, strings, string enums and nullable strings.
/// Constraining decoding to it is what keeps a small on-device model's answer parseable.
enum Grammar {
    struct Unsupported: Error, CustomStringConvertible {
        let description: String
    }

    static func gbnf(for schema: JSON) throws -> String {
        var builder = Builder()
        let root = try builder.rule(for: schema)
        return (["root ::= ws \(root) ws"] + builder.rules + Self.shared).joined(separator: "\n")
    }

    private static let shared = [
        #"ws ::= [ \t\n]{0,20}"#,
        #"string ::= "\"" char* "\"""#,
        #"char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4})"#,
        #"null ::= "null""#,
    ]

    private struct Builder {
        var rules: [String] = []

        mutating func rule(for schema: JSON) throws -> String {
            guard case .dict(let pairs) = schema else { throw Unsupported(description: "schema is not an object") }
            let fields = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
            if case .list(let values)? = fields["enum"] {
                let literals = try values.map { value -> String in
                    guard case .text(let text) = value else { throw Unsupported(description: "non-string enum") }
                    return Grammar.literal(Grammar.jsonString(text))
                }
                return define("(" + literals.joined(separator: " | ") + ")")
            }
            switch fields["type"] {
            case .text("string")?:
                return "string"
            case .list(let types)?:
                let names = types.compactMap { if case .text(let name) = $0 { name } else { nil } }
                guard Set(names) == ["string", "null"] else { throw Unsupported(description: "union \(names)") }
                return define("(string | null)")
            case .text("array")?:
                guard let items = fields["items"] else { throw Unsupported(description: "array without items") }
                let item = try rule(for: items)
                return define(#""[" ws ("# + item + #" (ws "," ws "# + item + #")*)? ws "]""#)
            case .text("object")?:
                guard case .dict(let properties)? = fields["properties"] else { throw Unsupported(description: "object without properties") }
                var members: [String] = []
                for (name, value) in properties {
                    members.append(Grammar.literal(Grammar.jsonString(name)) + #" ws ":" ws "# + (try rule(for: value)))
                }
                return define(#""{" ws "# + members.joined(separator: #" ws "," ws "#) + #" ws "}""#)
            default:
                throw Unsupported(description: "type \(String(describing: fields["type"]))")
            }
        }

        private mutating func define(_ body: String) -> String {
            let name = "r\(rules.count)"
            rules.append("\(name) ::= \(body)")
            return name
        }
    }

    /// The JSON encoding of `text`, quotes included.
    static func jsonString(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// A GBNF literal matching exactly `text`.
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
