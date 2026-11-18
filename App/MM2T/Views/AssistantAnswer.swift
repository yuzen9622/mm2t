import AppKit
import MM2TApp
import SwiftUI

/// The assistant's answer as formatted text. One text view lays out the whole answer, so a
/// streamed update costs a single layout pass instead of a redraw of every run each frame.
struct AssistantAnswer: View {
    let turn: AssistantTurn
    let openSource: (AssistantSource) -> Void
    @State private var hovered: AnswerHover?

    var body: some View {
        let document = AssistantMarkdown.blocks(turn.answer.text, known: Set(turn.sources.map(\.id)))
        AssistantRichText(document: document, hovered: $hovered) { id in
            if let source = turn.sources.first(where: { $0.id == id }) { openSource(source) }
        }
        .overlay(alignment: .topLeading) {
            if let hovered, let source = turn.sources.first(where: { $0.id == hovered.citation }) {
                // Placed by layout (padding), not `offset`, so the tooltip anchors to where the marker is.
                Color.clear.frame(width: hovered.rect.width, height: hovered.rect.height)
                    .tip(verbatim: Copy.assistantSource(source), show: true)
                    .padding(.leading, hovered.rect.minX).padding(.top, hovered.rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: turn.answer.text) { hovered = nil }
    }
}

struct AnswerHover: Equatable {
    let citation: String
    let rect: CGRect
}

private struct AssistantRichText: NSViewRepresentable {
    let document: AssistantMarkdown.BlockDocument
    @Binding var hovered: AnswerHover?
    let open: (String) -> Void

    func makeNSView(context: Context) -> AnswerTextView {
        let view = AnswerTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.linkTextAttributes = [:]
        return view
    }

    func updateNSView(_ view: AnswerTextView, context: Context) {
        view.onHover = { hover in if hovered != hover { hovered = hover } }
        view.onOpen = open
        if view.rendered != document {
            view.rendered = document
            view.textStorage?.setAttributedString(AnswerStyle.attributed(document))
            view.invalidateIntrinsicContentSize()
            view.window?.invalidateCursorRects(for: view)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: AnswerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(22, ceil(layout.usedRect(for: container).height)))
    }
}

/// A text view that knows which source marker is under the pointer, and opens it on a click.
final class AnswerTextView: NSTextView {
    var rendered: AssistantMarkdown.BlockDocument?
    var onHover: ((AnswerHover?) -> Void)?
    var onOpen: ((String) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(citation(at: convert(event.locationInWindow, from: nil))?.hover)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        // The text moves under a still pointer, so the marker under it changes without a mouse event.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            self.onHover?(self.bounds.contains(point) ? self.citation(at: point)?.hover : nil)
        }
    }
    override func mouseDown(with event: NSEvent) {
        if let found = citation(at: convert(event.locationInWindow, from: nil)) { onOpen?(found.id); return }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return }
        storage.enumerateAttribute(.citation, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            layout.enumerateEnclosingRects(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                self.addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    private func citation(at point: NSPoint) -> (id: String, hover: AnswerHover)? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        var range = NSRange()
        guard let id = storage.attribute(.citation, at: index, effectiveRange: &range) as? String else { return nil }
        var found: CGRect?
        layout.enumerateEnclosingRects(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, stop in
            if rect.contains(point) { found = rect; stop.pointee = true }
        }
        guard let rect = found else { return nil }
        return (id, AnswerHover(citation: id, rect: rect))
    }
}

extension NSAttributedString.Key {
    /// The id of the source a marker stands for. Not `.link`, which would add the URL as a tooltip.
    static let citation = NSAttributedString.Key("mm2t.citation")
}

private enum AnswerStyle {
    static let size: CGFloat = 16
    static let spacing = Typo.readingLineSpacing

    static func attributed(_ document: AssistantMarkdown.BlockDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(render(block, first: index == 0))
        }
        return result
    }

    private static func render(_ block: AssistantMarkdown.Block, first: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = spacing
        paragraph.paragraphSpacingBefore = first ? 0 : 10
        var prefix = ""
        var baseSize = size
        var weight = NSFont.Weight.regular
        switch block.kind {
        case .paragraph: break
        case .heading(let level):
            baseSize = [24, 20, 18, 17, 16, 16][min(level, 6) - 1]
            weight = .semibold
            paragraph.paragraphSpacingBefore = first ? 0 : 18
        case .bullet(let depth):
            prefix = "•\t"
            indent(paragraph, depth: depth)
            paragraph.paragraphSpacingBefore = first ? 0 : 4
        case .ordered(let number, let depth):
            prefix = "\(number).\t"
            indent(paragraph, depth: depth)
            paragraph.paragraphSpacingBefore = first ? 0 : 4
        case .quote:
            paragraph.firstLineHeadIndent = 14
            paragraph.headIndent = 14
        case .code:
            paragraph.firstLineHeadIndent = 10
            paragraph.headIndent = 10
            paragraph.tailIndent = -10
        case .rule:
            return NSAttributedString(string: "\u{2014}\u{2014}\u{2014}", attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(Palette.muted), .paragraphStyle: paragraph,
            ])
        }
        let text = NSMutableAttributedString()
        let color = block.kind == .quote ? NSColor(Palette.secondary) : NSColor(Palette.text)
        if !prefix.isEmpty {
            text.append(NSAttributedString(string: prefix, attributes: [
                .font: NSFont.systemFont(ofSize: baseSize), .foregroundColor: NSColor(Palette.secondary), .paragraphStyle: paragraph,
            ]))
        }
        for span in block.spans {
            var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph, .foregroundColor: color]
            if let citation = span.citation {
                let badge = NSTextAttachment()
                let image = badgeImage(span.text)
                badge.image = image
                badge.bounds = CGRect(x: 0, y: -4.5, width: image.size.width, height: image.size.height)
                var marked: [NSAttributedString.Key: Any] = [.citation: citation, .paragraphStyle: paragraph]
                let part = NSMutableAttributedString(string: "\u{2009}", attributes: [.paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: baseSize)])
                marked[.font] = NSFont.systemFont(ofSize: baseSize)
                let attachment = NSMutableAttributedString(attachment: badge)
                attachment.addAttributes(marked, range: NSRange(location: 0, length: attachment.length))
                part.append(attachment)
                part.append(NSAttributedString(string: "\u{2009}", attributes: [.paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: baseSize)]))
                text.append(part)
                continue
            }
            attributes[.font] = font(span, size: baseSize, weight: weight)
            if span.code {
                attributes[.backgroundColor] = NSColor(Palette.tonal)
            }
            if let link = span.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor(Palette.orange)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            text.append(NSAttributedString(string: span.text, attributes: attributes))
        }
        return text
    }

    /// A rounded square in the brand orange holding the source's number, centred.
    private static func badgeImage(_ number: String) -> NSImage {
        let size = NSSize(width: number.count > 1 ? 24 : 19, height: 19)
        return NSImage(size: size, flipped: false) { rect in
            let orange = NSColor(Palette.orange)
            orange.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: orange,
            ]
            let label = NSAttributedString(string: number, attributes: attributes)
            let box = label.size()
            label.draw(at: NSPoint(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2))
            return true
        }
    }

    private static func indent(_ paragraph: NSMutableParagraphStyle, depth: Int) {
        let base = CGFloat(depth) * 20
        paragraph.firstLineHeadIndent = base
        paragraph.headIndent = base + 20
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: base + 20)]
        paragraph.defaultTabInterval = 20
    }

    private static func font(_ span: AssistantMarkdown.Span, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if span.code { return .monospacedSystemFont(ofSize: size - 2, weight: .regular) }
        var font = NSFont.systemFont(ofSize: size, weight: span.bold ? .bold : weight)
        if span.italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return font
    }
}

struct CitationRegion: Equatable, Identifiable {
    let citation: String
    let rect: CGRect
    var id: String { "\(citation)-\(rect.minX)-\(rect.minY)" }
}

/// How far a streamed run has settled (its blur) and, in an answer, the citation it is.
/// The caption bar draws its arriving words with the same attribute and renderer.
@available(macOS 15, *)
struct AssistantTextAttribute: TextAttribute {
    let blur: Double
    let citation: String?
}

@available(macOS 15, *)
struct AssistantTextRenderer: TextRenderer {
    @Binding var regions: [CitationRegion]
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var found: [CitationRegion] = []
        for line in layout {
            for run in line {
                var drawing = context
                let attribute = run[AssistantTextAttribute.self]
                if let citation = attribute?.citation {
                    let rect = run.typographicBounds.rect
                    let background = CGRect(x: rect.minX, y: rect.midY - 9, width: rect.width, height: 18)
                    drawing.fill(Path(roundedRect: background, cornerRadius: 5), with: .color(Palette.tonal))
                    found.append(.init(citation: citation, rect: background))
                }
                if let blur = attribute?.blur, blur > 0 { drawing.addFilter(.blur(radius: blur)) }
                drawing.draw(run)
            }
        }
        if regions != found {
            let updated = found
            DispatchQueue.main.async { regions = updated }
        }
    }
}
