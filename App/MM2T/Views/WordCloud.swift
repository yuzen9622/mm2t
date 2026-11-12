import MM2TApp
import SwiftUI

/// The user's terms as a word cloud: the more often a term came up, the bigger it is. The most used
/// sits in the middle and the rest pack around it along a spiral, some of them turned upright.
struct WordCloud: View {
    /// Most used first, as the dashboard lists them.
    let terms: [TermRow]
    let revealed: Bool

    var body: some View {
        let peak = Double(terms.map(\.count).max() ?? 1)
        WordCloudLayout {
            ForEach(Array(terms.enumerated()), id: \.element.id) { index, term in
                word(term, rank: index, peak: peak)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func word(_ term: TermRow, rank: Int, peak: Double) -> some View {
        let weight = (Double(term.count) / peak).squareRoot()
        let tint = rank == 0 ? Palette.orange : Self.tints[term.seed % Self.tints.count]
        return CloudWord(term: term, weight: weight, isUpright: rank > 0 && term.seed % 3 == 0, tint: tint)
            .modifier(Reveal(revealed: revealed, delay: Double(rank) * 0.03, scale: 0.5))
    }

    /// Mid-tone hues that read on both the light and the dark card.
    static let tints: [Color] = [
        Color(hex: 0xF0700F), Color(hex: 0x2F9E8F), Color(hex: 0x5B7FD6), Color(hex: 0x9A6AC8),
        Color(hex: 0x8C9A3B), Color(hex: 0xC4574E), Color(hex: 0xC7922E), Color(hex: 0x4A9BC0),
    ]
}

private struct CloudWord: View {
    let term: TermRow
    /// 0...1 of the most used term.
    let weight: Double
    let isUpright: Bool
    let tint: Color
    @State private var hovering = false

    var body: some View {
        Upright(isOn: isUpright) {
            Text(verbatim: term.term)
                .font(.system(size: 12 + 40 * weight, weight: weight > 0.5 ? .semibold : .medium, design: .rounded))
                .foregroundStyle(tint.opacity(0.55 + 0.45 * weight))
                .lineLimit(1)
                .fixedSize()
                .rotationEffect(.degrees(isUpright ? -90 : 0))
        }
        .scaleEffect(hovering ? 1.08 : 1)
        .motion(Motion.touch, value: hovering)
        .onHover { hovering = $0 }
        .tip("Said \(term.count) times", show: hovering)
        .accessibilityLabel(Text("\(term.term), said \(term.count) times"))
    }
}

private extension TermRow {
    /// Stable across launches, unlike `hashValue`, so a word keeps its colour and direction.
    var seed: Int { term.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } }
}

/// Gives its one child, already turned a quarter, the turned size in the layout.
private struct Upright: Layout {
    let isOn: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return isOn ? CGSize(width: size.height, height: size.width) : size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }
}

/// Places its children, largest first, at the first spot along an outward spiral from the centre
/// where they overlap nothing already placed. The spiral is wider than tall, so the cloud fills a
/// card's width before it grows downward.
struct WordCloudLayout: Layout {
    var gap: CGFloat = 4

    struct Cache {
        var width: CGFloat = -1
        var rects: [CGRect] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 360
        let rects = layout(subviews, width: width, cache: &cache)
        guard let top = rects.map(\.minY).min(), let bottom = rects.map(\.maxY).max() else { return CGSize(width: width, height: 0) }
        return CGSize(width: width, height: bottom - top)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let rects = layout(subviews, width: bounds.width, cache: &cache)
        guard let top = rects.map(\.minY).min(), let bottom = rects.map(\.maxY).max() else { return }
        let dy = bounds.minY - top + (bounds.height - (bottom - top)) / 2
        for (subview, rect) in zip(subviews, rects) {
            subview.place(at: CGPoint(x: bounds.minX + rect.minX, y: rect.minY + dy), proposal: ProposedViewSize(rect.size))
        }
    }

    /// Rects relative to a centre at (width / 2, 0); only `width` bounds them.
    private func layout(_ subviews: Subviews, width: CGFloat, cache: inout Cache) -> [CGRect] {
        if cache.width == width, cache.rects.count == subviews.count { return cache.rects }
        var placed: [CGRect] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            var spot = CGRect(x: (width - size.width) / 2, y: -size.height / 2, width: size.width, height: size.height)
            var angle: CGFloat = 0
            // About 30 turns at 6 pt per turn: far enough for any card, cheap enough to run per resize.
            while angle < 190 {
                let radius = 6 * angle / (2 * .pi)
                let candidate = CGRect(x: width / 2 + 1.7 * radius * cos(angle) - size.width / 2,
                                       y: radius * sin(angle) - size.height / 2,
                                       width: size.width, height: size.height)
                if candidate.minX >= 0, candidate.maxX <= width,
                   !placed.contains(where: { $0.insetBy(dx: -gap, dy: -gap / 2).intersects(candidate) }) {
                    spot = candidate
                    break
                }
                angle += 0.12
            }
            placed.append(spot)
        }
        cache.width = width
        cache.rects = placed
        return placed
    }
}
