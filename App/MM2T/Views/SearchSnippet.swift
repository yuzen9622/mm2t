import MM2TCore
import SwiftUI

struct SearchSnippet: View {
    let hit: MeetingHits.Hit

    private struct Part {
        var text: String
        let matched: Bool
    }

    private var parts: [Part] {
        var parts: [Part] = []
        var start = hit.snippet.startIndex
        for range in hit.matchedRanges {
            if start < range.lowerBound { parts.append(Part(text: String(hit.snippet[start..<range.lowerBound]), matched: false)) }
            parts.append(Part(text: String(hit.snippet[range]), matched: true))
            start = range.upperBound
        }
        if start < hit.snippet.endIndex { parts.append(Part(text: String(hit.snippet[start...]), matched: false)) }
        return parts
    }

    var body: some View {
        Canvas { context, size in
            func resolve(_ part: Part) -> GraphicsContext.ResolvedText {
                context.resolve(Text(verbatim: String(part.text.map { $0.isNewline || $0 == "\t" ? " " : $0 }))
                    .font(part.matched ? Typo.bodyStrong : Typo.body)
                    .foregroundStyle(part.matched ? Palette.text : Palette.secondary))
            }
            func width(_ part: Part) -> CGFloat {
                resolve(part).measure(in: CGSize(width: .infinity, height: size.height)).width
            }
            let ellipsis = Part(text: "…", matched: false)
            let ellipsisWidth = width(ellipsis)
            var visible = parts
            if visible.count > 1, !visible[0].matched, visible[1].matched {
                let matchWidth = min(width(visible[1]), max(0, size.width - ellipsisWidth))
                while visible[0].text.count > 1, width(visible[0]) + matchWidth + ellipsisWidth > size.width {
                    visible[0].text.removeFirst()
                    if visible[0].text.first != "…" { visible[0].text = "…" + visible[0].text.dropFirst() }
                }
            }
            var x: CGFloat = 0
            for (index, part) in visible.enumerated() {
                var part = part
                let available = max(0, size.width - x)
                let remainingWidth = visible[index...].reduce(CGFloat.zero) { $0 + width($1) }
                let truncated = remainingWidth > available
                let allowance = max(0, available - (truncated ? ellipsisWidth : 0))
                if width(part) > allowance {
                    while !part.text.isEmpty, width(part) > allowance { part.text.removeLast() }
                    if !part.text.isEmpty { draw(part, at: x, width: width(part), context: context, size: size, resolved: resolve(part)) }
                    context.draw(resolve(ellipsis), at: CGPoint(x: x + width(part), y: size.height / 2), anchor: .leading)
                    break
                }
                let length = width(part)
                draw(part, at: x, width: length, context: context, size: size, resolved: resolve(part))
                x += length
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ part: Part, at x: CGFloat, width: CGFloat, context: GraphicsContext,
                      size: CGSize, resolved: GraphicsContext.ResolvedText) {
        if part.matched {
            let height = resolved.measure(in: CGSize(width: .infinity, height: size.height)).height
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Palette.orangeSoft))
        }
        context.draw(resolved, at: CGPoint(x: x, y: size.height / 2), anchor: .leading)
    }
}
