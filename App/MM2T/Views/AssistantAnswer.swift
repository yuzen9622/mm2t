import AppKit
import MM2TApp
import SwiftUI

struct AssistantAnswer: View {
    let turn: AssistantTurn
    let settledOffset: Int
    let openSource: (AssistantSource) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var regions: [CitationRegion] = []
    @State private var hovering: String?
    @State private var settling = false

    var body: some View {
        let last = turn.answer.batches.last?.arrived ?? .distantPast
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduce || !settling)) { timeline in
            answer(at: timeline.date)
                .font(Typo.reading)
                .lineSpacing(Typo.readingLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .topLeading) {
                    ForEach(regions) { region in
                        if let source = turn.sources.first(where: { $0.id == region.citation }) {
                            Button { open(source) } label: {
                                if #available(macOS 15, *) { Color.clear.contentShape(Rectangle()) }
                                else {
                                    Text(verbatim: "\((turn.document.citationIDs.firstIndex(of: source.id) ?? 0) + 1)")
                                        .font(Typo.captionStrong).foregroundStyle(Palette.secondary)
                                        .frame(maxWidth: .infinity, minHeight: 18)
                                        .background(Palette.tonal, in: RoundedRectangle(cornerRadius: 5))
                                }
                            }
                                .buttonStyle(.plain).focusEffectDisabled()
                                .frame(width: region.rect.width, height: max(18, region.rect.height))
                                .position(x: region.rect.midX, y: region.rect.midY)
                                .onHover { hovering = $0 ? region.citation : nil }
                                .tip(verbatim: Copy.assistantSource(source), show: hovering == region.citation)
                                .accessibilityLabel(Copy.assistantSource(source))
                        }
                    }
                }
        }
        .task(id: last) {
            settling = !reduce && turn.answer.text.count > settledOffset && Date().timeIntervalSince(last) < 0.3
            if settling {
                do { try await Task.sleep(for: .milliseconds(310)) } catch { return }
                settling = false
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let source = turn.sources.first(where: { $0.id == url.host }) else { return .discarded }
            open(source)
            return .handled
        })
    }

    @ViewBuilder private func answer(at date: Date) -> some View {
        if #available(macOS 15, *) {
            text(at: date).textRenderer(AssistantTextRenderer(regions: $regions))
        } else { AssistantLegacyText(turn: turn, settledOffset: settledOffset, date: date, reduce: reduce, regions: $regions) }
    }

    private func text(at date: Date) -> Text {
        var result = Text(verbatim: "")
        let document = turn.document
        struct Fragment {
            var text: String
            let bold: Bool
            let citation: String?
            let arrival: Date
        }
        var fragments: [Fragment] = []
        for run in document.runs {
            let arrival = run.offset < settledOffset ? Date.distantPast
                : turn.answer.batches.first { run.offset < $0.endOffset }?.arrived ?? .distantPast
            if let last = fragments.last, last.arrival == arrival, last.bold == run.bold,
               last.citation == nil, run.citation == nil {
                fragments[fragments.count - 1].text += run.text
            } else { fragments.append(.init(text: run.text, bold: run.bold, citation: run.citation, arrival: arrival)) }
        }
        for run in fragments {
            let progress = reduce ? 1 : min(1, max(0, date.timeIntervalSince(run.arrival) / 0.3))
            var attributed = AttributedString(run.citation == nil ? run.text : " \(run.text) ")
            attributed.foregroundColor = (run.citation == nil ? Palette.text : Palette.secondary).opacity(progress)
            if run.bold { attributed.font = .system(size: 16, weight: .bold) }
            if let citation = run.citation {
                attributed.font = Typo.captionStrong
                attributed.link = URL(string: "mm2t-citation://\(citation)")
                if #unavailable(macOS 15) { attributed.backgroundColor = Palette.tonal }
            }
            var part = Text(attributed)
            if #available(macOS 15, *) {
                part = part.customAttribute(AssistantTextAttribute(blur: reduce ? 0 : 4 * (1 - progress), citation: run.citation))
            }
            result = result + part
        }
        return result
    }
    private func open(_ source: AssistantSource) {
        openSource(source)
    }
}

private struct AssistantLegacyText: NSViewRepresentable {
    let turn: AssistantTurn
    let settledOffset: Int
    let date: Date
    let reduce: Bool
    @Binding var regions: [CitationRegion]

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        let text = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Typo.readingLineSpacing
        for run in turn.document.runs {
            let arrival = run.offset < settledOffset ? Date.distantPast
                : turn.answer.batches.first { run.offset < $0.endOffset }?.arrived ?? .distantPast
            let progress = reduce ? 1 : min(1, max(0, date.timeIntervalSince(arrival) / 0.3))
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: run.citation == nil ? 16 : 12, weight: run.bold ? .bold : .regular),
                .foregroundColor: NSColor(Palette.text).withAlphaComponent(progress),
                .paragraphStyle: paragraph,
            ]
            if let citation = run.citation {
                attributes[.link] = URL(string: "mm2t-citation://\(citation)")
                attributes[.foregroundColor] = NSColor.clear
            }
            text.append(NSAttributedString(string: run.citation == nil ? run.text : " \(run.text) ", attributes: attributes))
        }
        view.linkTextAttributes = [:]
        view.textStorage?.setAttributedString(text)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        var found: [CitationRegion] = []
        view.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: view.textStorage?.length ?? 0)) { value, range, _ in
            guard let url = value as? URL, let citation = url.host else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            found.append(.init(citation: citation, rect: rect))
        }
        if found != regions {
            let updated = found
            DispatchQueue.main.async { regions = updated }
        }
        return CGSize(width: width, height: max(22, ceil(layout.usedRect(for: container).height)))
    }
}

private struct CitationRegion: Equatable, Identifiable {
    let citation: String
    let rect: CGRect
    var id: String { "\(citation)-\(rect.minX)-\(rect.minY)" }
}

@available(macOS 15, *)
private struct AssistantTextAttribute: TextAttribute {
    let blur: Double
    let citation: String?
}

@available(macOS 15, *)
private struct AssistantTextRenderer: TextRenderer {
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
