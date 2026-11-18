import Foundation

extension AssistantMarkdown {
    /// One styled stretch of text inside a block.
    public struct Span: Equatable {
        public var text: String
        public var bold = false
        public var italic = false
        public var code = false
        public var link: URL?
        /// The cited source's id; `text` is then its 1-based number.
        public var citation: String?
    }

    public struct Block: Equatable {
        public enum Kind: Equatable {
            case paragraph
            case heading(Int)
            case bullet(depth: Int)
            case ordered(number: Int, depth: Int)
            case quote
            case code
            case rule
        }
        public var kind: Kind
        public var spans: [Span]
        public var plainText: String { spans.map(\.text).joined() }
    }

    public struct BlockDocument: Equatable {
        public var blocks: [Block]
        public var citationIDs: [String]
    }

    /// Parses the answer's Markdown (headings, lists, quotes, fenced code, bold, italic, inline
    /// code, links) and its `[mN]` source markers. An unfinished construct at the end of a
    /// streaming answer renders as far as it has arrived instead of showing its raw markers.
    public static func blocks(_ input: String, known: Set<String>) -> BlockDocument {
        var citations: [String] = []
        var blocks: [Block] = []
        var inCode = false
        var codeLines: [String] = []
        var paragraph: [Span] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(Block(kind: .paragraph, spans: paragraph)); paragraph = [] }
        }
        func flushCode() {
            blocks.append(Block(kind: .code, spans: [Span(text: codeLines.joined(separator: "\n"), code: true)]))
            codeLines = []
        }
        func inline(_ text: String) -> [Span] {
            inlineSpans(text, known: known, citations: &citations)
        }

        for raw in input.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode { flushCode(); inCode = false }
                else { flushParagraph(); inCode = true }
                continue
            }
            if inCode { codeLines.append(line); continue }
            if trimmed.isEmpty { flushParagraph(); continue }
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }),
               Set(trimmed).count == 1 {
                flushParagraph()
                blocks.append(Block(kind: .rule, spans: []))
                continue
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if let heading = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(Block(kind: .heading(heading.level), spans: inline(heading.text)))
            } else if let bullet = bulletText(trimmed) {
                flushParagraph()
                blocks.append(Block(kind: .bullet(depth: min(3, indent / 2)), spans: inline(bullet)))
            } else if let item = orderedItem(trimmed) {
                flushParagraph()
                blocks.append(Block(kind: .ordered(number: item.number, depth: min(3, indent / 2)), spans: inline(item.text)))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                let body = trimmed.dropFirst().drop { $0 == " " }
                blocks.append(Block(kind: .quote, spans: inline(String(body))))
            } else {
                if !paragraph.isEmpty { paragraph.append(Span(text: "\n")) }
                paragraph += inline(trimmed)
            }
        }
        if inCode { flushCode() }
        flushParagraph()
        return BlockDocument(blocks: blocks, citationIDs: citations)
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func bulletText(_ line: String) -> String? {
        guard let first = line.first, "-*+•".contains(first), line.dropFirst().first == " " else { return nil }
        return String(line.dropFirst(2))
    }

    private static func orderedItem(_ line: String) -> (number: Int, text: String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return (number, String(rest.dropFirst(2)))
    }

    private static func inlineSpans(_ input: String, known: Set<String>, citations: inout [String]) -> [Span] {
        let characters = Array(input)
        var spans: [Span] = []
        var buffer = ""
        var bold = false, italic = false, code = false
        func flush() {
            guard !buffer.isEmpty else { return }
            spans.append(Span(text: buffer, bold: bold, italic: italic, code: code))
            buffer = ""
        }
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if char == "`" { flush(); code.toggle(); index += 1; continue }
            if code { buffer.append(char); index += 1; continue }
            if char == "*" || char == "_" {
                let double = index + 1 < characters.count && characters[index + 1] == char
                if double { flush(); bold.toggle(); index += 2; continue }
                // A lone underscore inside a word (snake_case) is text, not emphasis.
                let wordInternal = char == "_" && index > 0 && index + 1 < characters.count
                    && characters[index - 1].isLetter && characters[index + 1].isLetter
                let spaced = index + 1 < characters.count && characters[index + 1] == " "
                if !wordInternal && !spaced { flush(); italic.toggle(); index += 1; continue }
            }
            if char == "[" {
                if index + 1 < characters.count, characters[index + 1] == "m" {
                    // A source marker is `[m` + digits/dots/`u` + `]`; a marker still arriving at the end is held back.
                    var end = index + 2
                    while end < characters.count, characters[end].isASCII,
                          characters[end].isNumber || characters[end] == "." || characters[end] == "u" { end += 1 }
                    if end == characters.count { break }
                    if characters[end] == "]", end > index + 2 {
                        let id = String(characters[(index + 1)..<end])
                        if known.contains(id) {
                            flush()
                            if !citations.contains(id) { citations.append(id) }
                            spans.append(Span(text: "\(citations.firstIndex(of: id)! + 1)", bold: bold, citation: id))
                        }
                        index = end + 1
                        continue
                    }
                }
                if let close = characters[(index + 1)...].firstIndex(of: "]"), close + 1 < characters.count,
                   characters[close + 1] == "(", let end = characters[(close + 2)...].firstIndex(of: ")"),
                   let url = URL(string: String(characters[(close + 2)..<end])), url.scheme == "http" || url.scheme == "https" {
                    flush()
                    spans.append(Span(text: String(characters[(index + 1)..<close]), bold: bold, italic: italic, link: url))
                    index = end + 1
                    continue
                }
            }
            buffer.append(char)
            index += 1
        }
        flush()
        return spans
    }
}
