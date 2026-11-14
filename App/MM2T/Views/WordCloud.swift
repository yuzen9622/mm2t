import AppKit
import MM2TApp
import SwiftUI

struct WordCloud: View {
    let terms: [TermRow]
    let revealed: Bool

    var body: some View {
        GeometryReader { geometry in
            let words = placedWords(in: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(words) { word in
                    CloudWord(word: word)
                        .modifier(Reveal(revealed: revealed, delay: Double(word.rank) * 0.03, scale: 0.5))
                        .position(x: word.frame.midX, y: word.frame.midY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
    }

    private func placedWords(in size: CGSize) -> [PlacedWord] {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let peak = Double(max(terms.map(\.count).max() ?? 1, 1))
        var placed: [PlacedWord] = []
        for (rank, term) in terms.enumerated() {
            let weight = (Double(term.count) / peak).squareRoot()
            let base = NSFont.systemFont(ofSize: 12 + 40 * weight, weight: weight > 0.5 ? .semibold : .medium)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
            let measured = (term.term as NSString).size(withAttributes: [.font: font])
            let textSize = CGSize(width: ceil(measured.width), height: ceil(measured.height))
            let prefersUpright = rank > 0 && term.seed % 3 == 0
            for upright in prefersUpright ? [true, false] : [false] {
                let wordSize = upright ? CGSize(width: textSize.height, height: textSize.width) : textSize
                guard let frame = WordCloudPacking.place(wordSize, in: bounds, occupied: placed.map(\.frame)) else { continue }
                placed.append(PlacedWord(term: term, rank: rank, font: font, weight: weight,
                                         upright: upright, textSize: textSize, frame: frame))
                break
            }
        }
        return placed
    }

    static let tints: [Color] = [
        Color(hex: 0xF0700F), Color(hex: 0x2F9E8F), Color(hex: 0x5B7FD6), Color(hex: 0x9A6AC8),
        Color(hex: 0x8C9A3B), Color(hex: 0xC4574E), Color(hex: 0xC7922E), Color(hex: 0x4A9BC0),
    ]
}

private struct PlacedWord: Identifiable {
    let term: TermRow
    let rank: Int
    let font: NSFont
    let weight: Double
    let upright: Bool
    let textSize: CGSize
    let frame: CGRect
    var id: String { term.term }
}

private struct CloudWord: View {
    let word: PlacedWord
    @State private var hovering = false

    var body: some View {
        let tint = word.rank == 0 ? Palette.orange : WordCloud.tints[word.term.seed % WordCloud.tints.count]
        Text(verbatim: word.term.term)
            .font(Font(word.font))
            .foregroundStyle(tint.opacity(0.55 + 0.45 * word.weight))
            .lineLimit(1)
            .fixedSize()
            .frame(width: word.textSize.width, height: word.textSize.height)
            .rotationEffect(.degrees(word.upright ? -90 : 0))
            .frame(width: word.frame.width, height: word.frame.height)
            .scaleEffect(hovering ? 1.04 : 1)
            .motion(Motion.touch, value: hovering)
            .onHover { hovering = $0 }
            .tip("Said ^[\(word.term.count) time](inflect: true)", show: hovering)
            .accessibilityLabel(Text("\(word.term.term), said ^[\(word.term.count) time](inflect: true)"))
    }
}

private extension TermRow {
    var seed: Int { term.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } }
}

enum WordCloudPacking {
    static func place(_ size: CGSize, in bounds: CGRect, occupied: [CGRect]) -> CGRect? {
        guard size.width <= bounds.width, size.height <= bounds.height else { return nil }
        let aspect = bounds.width / bounds.height
        let limit = hypot(bounds.height / 2, bounds.height / 2)
        var angle: CGFloat = 0
        while angle * 3 / (2 * .pi) <= limit {
            let radius = angle * 3 / (2 * .pi)
            let candidate = CGRect(x: bounds.midX + aspect * radius * cos(angle) - size.width / 2,
                                   y: bounds.midY + radius * sin(angle) - size.height / 2,
                                   width: size.width, height: size.height)
            if bounds.contains(candidate),
               !occupied.contains(where: { $0.insetBy(dx: -4, dy: -3).intersects(candidate) }) {
                return candidate
            }
            angle += 0.15
        }
        return nil
    }
}
