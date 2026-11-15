import MM2TCore
import SwiftUI

private struct PersonArtwork {
    let seed: UInt64

    init(id: PersonID) {
        var uuid = id.rawValue.uuid
        var hash = withUnsafeBytes(of: &uuid) { bytes in
            bytes.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }
        hash = (hash ^ (hash >> 30)) &* 0xBF58476D1CE4E5B9
        hash = (hash ^ (hash >> 27)) &* 0x94D049BB133111EB
        seed = hash ^ (hash >> 31)
    }

    var phase: Double { Double(seed >> 32) / Double(UInt32.max) * 2 * .pi }
    var lobes: Double { Double(2 + (seed >> 16) % 4) }
    var stretch: Double { 0.7 + Double((seed >> 8) % 100) / 200 }

    func color(in scheme: ColorScheme) -> Color {
        let colors: [(UInt32, UInt32)] = [
            (0x537EAA, 0x8BB4DC), (0x458777, 0x85C1AD), (0xB57A4A, 0xDCA97E),
            (0x82709B, 0xB4A0CD), (0xA26678, 0xD39CAC), (0x637F8C, 0x9CBAC8)
        ]
        let pair = colors[Int(seed % UInt64(colors.count))]
        return Color(hex: scheme == .dark ? pair.1 : pair.0)
    }
}

struct PersonSigil: View {
    let id: PersonID
    var size: CGFloat = 48
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let artwork = PersonArtwork(id: id)
        Canvas { context, bounds in
            let scale = min(bounds.width, bounds.height) / 200
            let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            let phase = artwork.phase
            let color = artwork.color(in: scheme)
            let count = size < 60 ? 48 : 100
            for index in 0..<count {
                let angle = Double(index) / Double(count) * 2 * .pi
                let pulse = (sin(angle * artwork.lobes + phase) + cos(angle * 7 - phase * 0.4)
                             + sin(angle * 11 + phase * 0.2) + 3) / 6
                let inner = 48 + 6 * sin(angle * 2 + phase)
                let outer = inner + 8 + 46 * pow(pulse, 1.7)
                var line = Path()
                line.move(to: CGPoint(x: center.x + cos(angle) * inner * scale,
                                      y: center.y + sin(angle) * inner * scale))
                line.addLine(to: CGPoint(x: center.x + cos(angle) * outer * scale,
                                        y: center.y + sin(angle) * outer * scale))
                context.stroke(line, with: .color(color.opacity(0.45 + 0.55 * pulse)),
                               style: StrokeStyle(lineWidth: max(0.8, 1.9 * scale), lineCap: .round))
            }
            let radius = 44 * scale
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2)),
                           with: .color(color.opacity(0.15)), lineWidth: 0.5)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct PersonWatermark: View {
    let id: PersonID
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let artwork = PersonArtwork(id: id)
        Canvas { context, bounds in
            let phase = artwork.phase
            let center = CGPoint(x: bounds.width - 54, y: bounds.height * 0.7)
            for ring in 0..<15 {
                let base = Double(18 + ring * 6)
                var path = Path()
                for step in 0...180 {
                    let angle = Double(step) / 180 * 2 * .pi
                    let radius = base * (1 + 0.16 * sin(artwork.lobes * angle + phase)
                                         + 0.09 * cos(2 * angle - phase * 0.7))
                    let x = radius * cos(angle) * artwork.stretch
                    let y = radius * sin(angle)
                    let point = CGPoint(x: center.x + x * cos(phase) - y * sin(phase),
                                        y: center.y + x * sin(phase) + y * cos(phase))
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
                context.stroke(path, with: .color(artwork.color(in: scheme)),
                               style: StrokeStyle(lineWidth: ring.isMultiple(of: 4) ? 2 : 1.5,
                                                  lineCap: .round, lineJoin: .round))
            }
        }
        .opacity(scheme == .dark ? 0.08 : 0.07)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                     .init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .clipped()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
