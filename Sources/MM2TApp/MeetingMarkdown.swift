import AppKit

/// Both the reading page and the Word writer use Foundation's Markdown block and inline intents.
public enum MeetingMarkdown {
    public struct Style {
        public let text, secondary, accent, surface, separator: NSColor
        public let bodySize, titleSize, lineSpacing: CGFloat

        public init(text: NSColor = .labelColor, secondary: NSColor = .secondaryLabelColor,
                    accent: NSColor = .linkColor, surface: NSColor = .quaternaryLabelColor,
                    separator: NSColor = .separatorColor, bodySize: CGFloat = 16,
                    titleSize: CGFloat = 20, lineSpacing: CGFloat = 6) {
            self.text = text
            self.secondary = secondary
            self.accent = accent
            self.surface = surface
            self.separator = separator
            self.bodySize = bodySize
            self.titleSize = titleSize
            self.lineSpacing = lineSpacing
        }
    }

    public static func wordData(_ markdown: String, style: Style = Style()) throws -> Data {
        // Paper uses the light palette even when the app window is in dark mode.
        var output: Result<Data, Error>!
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let document = attributed(markdown, forPrint: true, style: style)
            output = Result {
                try document.data(from: NSRange(location: 0, length: document.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            }
        }
        return try output.get()
    }

    public static func attributed(_ markdown: String, forPrint: Bool = false, style: Style = Style()) -> NSAttributedString {
        render(markdown, forPrint: forPrint, style: style, recordBlock: nil)
    }

    /// Offsets use UTF-16, the coordinate system of NSTextView. Parsing the entire source
    /// preserves reference links, nested list numbering and table layout on either side of an edit.
    public struct EditableBlock {
        public let source: NSRange
        public let display: NSRange
    }

    public struct Layout {
        public let source: String
        public let preview: NSAttributedString
        public let blocks: [EditableBlock]

        /// A rendered run can occur several times in the same paragraph. Its source position
        /// disambiguates repeated words without searching for the first matching character.
        public func caret(at index: Int, in block: EditableBlock) -> Int {
            guard block.display.length > 0 else { return 0 }
            var effective = NSRange()
            let character = max(block.display.location, min(index, NSMaxRange(block.display) - 1))
            if let span = preview.attribute(sourceRangeKey, at: character, effectiveRange: &effective) as? NSValue {
                let range = span.rangeValue
                let position = range.location + min(max(0, index - effective.location), range.length)
                return max(0, min(block.source.length, position - block.source.location))
            }
            return min(max(0, index - block.display.location), block.source.length)
        }
    }

    private static let sourceRangeKey = NSAttributedString.Key("mm2t.markdownSourceRange")

    public static func layout(_ markdown: String, style: Style = Style()) -> Layout {
        let source = markdown as NSString
        var lines = [0]
        while let last = lines.last, last < source.length {
            lines.append(NSMaxRange(source.lineRange(for: NSRange(location: last, length: 0))))
        }
        func lineText(_ line: Int) -> String {
            guard line > 0, line < lines.count else { return "" }
            return source.substring(with: NSRange(location: lines[line - 1], length: lines[line] - lines[line - 1]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var marks: [(id: Int, first: Int, last: Int, display: Int)] = []
        let preview = render(markdown, forPrint: false, style: style) { component, position, offset in
            var first = position?.startLine
            var last = position?.endLine
            if case .thematicBreak = component.kind, first == nil {
                let next = (marks.last?.last ?? 0) + 1
                if next < lines.count {
                    first = (next..<lines.count).first { line in
                        let text = lineText(line).filter { !$0.isWhitespace }
                        return text.count >= 3 && text.first.map { "-*_".contains($0) } == true && Set(text).count == 1
                    }
                    last = first
                }
            }
            guard let first, var last, lines.indices.contains(first - 1) else { return }
            if case .header = component.kind, !lineText(first).drop(while: { $0 == ">" || $0.isWhitespace }).hasPrefix("#") {
                let underline = lineText(last + 1).drop(while: { $0 == ">" || $0.isWhitespace })
                if !underline.isEmpty, underline.allSatisfy({ $0 == "=" }) || underline.allSatisfy({ $0 == "-" }) { last += 1 }
            }
            if case .table = component.kind {
                // A header-only table or a trailing empty row has no run for the last line.
                while last < lines.count - 1 {
                    let row = lineText(last + 1)
                    guard row.contains("|"), row.allSatisfy({ "|:-".contains($0) || $0.isWhitespace }) else { break }
                    last += 1
                }
            }
            if marks.last?.id == component.identity {
                marks[marks.count - 1].last = max(marks[marks.count - 1].last, last)
            } else {
                marks.append((component.identity, first, last, offset))
            }
        }
        let blocks = marks.indices.map { i in
            let mark = marks[i]
            let start = lines[mark.first - 1]
            let next = i + 1 < marks.count ? marks[i + 1].display : preview.length
            var end = lines[min(mark.last, lines.count - 1)]
            while end > start, [10, 13].contains(source.character(at: end - 1)) { end -= 1 }
            return EditableBlock(source: NSRange(location: start, length: end - start),
                                 display: NSRange(location: mark.display, length: next - mark.display))
        }
        if blocks.isEmpty {
            return Layout(source: markdown, preview: preview, blocks: [
                EditableBlock(source: NSRange(location: 0, length: source.length), display: NSRange(location: 0, length: preview.length))
            ])
        }
        return Layout(source: markdown, preview: preview, blocks: blocks)
    }

    private static func render(_ markdown: String, forPrint: Bool, style: Style,
                               recordBlock: ((PresentationIntent.IntentType, AttributedString.MarkdownSourcePosition?, Int) -> Void)?) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(appliesSourcePositionAttributes: recordBlock != nil)
        let parsed = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        let result = NSMutableAttributedString()
        let scale: CGFloat = forPrint ? 0.75 : 1
        var previous: PresentationIntent?
        var lastListItem: Int?
        var block = Block(style: style, scale: scale)
        var table: Table?
        for run in parsed.runs {
            var blockStart = result.length
            if previous != run.presentationIntent || result.length == 0 {
                if result.length > 0 {
                    var separator = result.attributes(at: result.length - 1, effectiveRange: nil)
                    separator.removeValue(forKey: .link)
                    separator.removeValue(forKey: .toolTip)
                    separator.removeValue(forKey: sourceRangeKey)
                    result.append(NSAttributedString(string: "\n", attributes: separator))
                }
                blockStart = result.length
                previous = run.presentationIntent
                block = Block(style: style, scale: scale)
                var depth = 0
                var ordinal: Int?
                var itemID: Int?
                var row = 0, column = 0
                var inTable = false
                for component in run.presentationIntent?.components ?? [] {
                    switch component.kind {
                    case .header(let level):
                        block.paragraph.headerLevel = level
                        block.paragraph.paragraphSpacingBefore = result.length == 0 ? 0 : 14 * scale
                    case .codeBlock: block.code = true
                    case .blockQuote:
                        block.quote = true
                        block.paragraph.headIndent += 16 * scale
                    case .thematicBreak: block.rule = true
                    case .listItem(let index) where itemID == nil:
                        ordinal = index
                        itemID = component.identity
                    case .unorderedList, .orderedList:
                        if depth == 0, itemID != lastListItem {
                            block.prefix = component.kind == .orderedList ? "\(ordinal ?? 1).\t" : "•\t"
                        }
                        depth += 1
                    case .tableCell(let index): column = index
                    case .tableHeaderRow: block.tableHeader = true
                    case .tableRow(let index): row = index
                    case .table(let columns):
                        inTable = true
                        if table?.id != component.identity {
                            table?.finish(in: result)
                            blockStart = result.length
                            table = Table(id: component.identity, columns: columns, style: style, scale: scale)
                        }
                        table?.position(block.paragraph, row: row, column: column, filling: result)
                    default: break
                    }
                }
                if !inTable {
                    table?.finish(in: result)
                    blockStart = result.length
                    table = nil
                }
                lastListItem = itemID
                block.paragraph.headIndent += CGFloat(depth) * 22 * scale
                block.paragraph.firstLineHeadIndent = block.paragraph.headIndent - (block.prefix.isEmpty ? 0 : 22 * scale)
                block.paragraph.tabStops = [NSTextTab(textAlignment: .left, location: block.paragraph.headIndent)]
            }
            if let recordBlock, let components = run.presentationIntent?.components {
                let table = components.first { if case .table = $0.kind { return true }; return false }
                if let component = table ?? components.first {
                    recordBlock(component, run.markdownSourcePosition, blockStart)
                }
            }
            var attributes = block.attributes(run.inlinePresentationIntent ?? [])
            if !block.prefix.isEmpty {
                var marker = attributes
                marker[.foregroundColor] = style.secondary
                result.append(NSAttributedString(string: block.prefix, attributes: marker))
                block.prefix = ""
            }
            if let url = run.link {
                attributes[.link] = url
                attributes[.foregroundColor] = style.accent
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if let title = run.alternateDescription { attributes[.toolTip] = title }
            }
            let inline = run.inlinePresentationIntent ?? []
            let text = inline.contains(.lineBreak) || inline.contains(.softBreak) ? "\n" : String(parsed[run.range].characters)
            if recordBlock != nil, let position = run.markdownSourcePosition,
               let range = Range<String.Index>(position, in: markdown) {
                let span = NSRange(range, in: markdown)
                // Fenced code and escapes may have delimiters inside their source span.
                let literal = markdown[range].range(of: text)
                attributes[sourceRangeKey] = NSValue(range: literal.map { NSRange($0, in: markdown) } ?? span)
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        if let table {
            result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: block.paragraph]))
            table.finish(in: result)
        }
        return result
    }

    private struct Block {
        let style: Style
        let scale: CGFloat
        let paragraph = NSMutableParagraphStyle()
        var prefix = ""
        var code = false, quote = false, rule = false, tableHeader = false

        init(style: Style, scale: CGFloat) {
            self.style = style
            self.scale = scale
            paragraph.lineSpacing = style.lineSpacing * scale
            paragraph.paragraphSpacing = 6 * scale
        }

        func attributes(_ inline: InlinePresentationIntent) -> [NSAttributedString.Key: Any] {
            let level = paragraph.headerLevel
            let headingSizes = [style.titleSize + 4, style.titleSize, style.bodySize + 2,
                                style.bodySize, style.bodySize - 1, style.bodySize - 2]
            let size = (level > 0 ? headingSizes[min(level, 6) - 1] : style.bodySize) * scale
            let isCode = code || inline.contains(.code)
            let weight: NSFont.Weight = inline.contains(.stronglyEmphasized) ? .bold : (level > 0 || tableHeader ? .semibold : .regular)
            var font = isCode ? NSFont.monospacedSystemFont(ofSize: size - scale, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
            if !isCode, level > 0 || tableHeader, let rounded = font.fontDescriptor.withDesign(.rounded) {
                font = NSFont(descriptor: rounded, size: size) ?? font
            }
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: paragraph, .foregroundColor: quote || rule ? style.secondary : style.text,
            ]
            if isCode { attrs[.backgroundColor] = style.surface }
            if inline.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            return attrs
        }
    }

    /// TextKit lays out the native cells. Foundation omits empty cells from its runs,
    /// so fill the gaps before placing the next cell.
    private final class Table {
        let id: Int
        let columns: [PresentationIntent.TableColumn]
        let style: Style
        let scale: CGFloat
        let table = NSTextTable()
        var nextCell = 0

        init(id: Int, columns: [PresentationIntent.TableColumn], style: Style, scale: CGFloat) {
            self.id = id
            self.columns = columns
            self.style = style
            self.scale = scale
            table.numberOfColumns = columns.count
            table.collapsesBorders = true
            table.layoutAlgorithm = .fixedLayoutAlgorithm
            table.setContentWidth(100, type: .percentageValueType)
        }

        func position(_ paragraph: NSMutableParagraphStyle, row: Int, column: Int, filling text: NSMutableAttributedString) {
            guard columns.indices.contains(column) else { return }
            let index = row * columns.count + column
            fill(until: index, in: text)
            configure(paragraph, row: row, column: column)
            nextCell = index + 1
        }

        func finish(in text: NSMutableAttributedString) {
            guard !columns.isEmpty else { return }
            let remaining = (columns.count - nextCell % columns.count) % columns.count
            fill(until: nextCell + remaining, in: text)
        }

        private func fill(until limit: Int, in text: NSMutableAttributedString) {
            while nextCell < limit {
                let paragraph = NSMutableParagraphStyle()
                configure(paragraph, row: nextCell / columns.count, column: nextCell % columns.count)
                text.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
                nextCell += 1
            }
        }

        private func configure(_ paragraph: NSMutableParagraphStyle, row: Int, column: Int) {
            let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            cell.setContentWidth(100 / CGFloat(columns.count), type: .percentageValueType)
            cell.setWidth(6 * scale, type: .absoluteValueType, for: .padding)
            cell.setWidth(0.5 * scale, type: .absoluteValueType, for: .border)
            cell.setBorderColor(style.separator)
            if row == 0 { cell.backgroundColor = style.surface }
            paragraph.textBlocks = [cell]
            paragraph.paragraphSpacing = 0
            switch columns[column].alignment {
            case .left: paragraph.alignment = .left
            case .right: paragraph.alignment = .right
            case .center: paragraph.alignment = .center
            @unknown default: paragraph.alignment = .natural
            }
        }
    }
}
