import SwiftUI

struct PlaybackGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Palette.card, in: shape)
        } else if #available(macOS 26, *) {
            content.background(Palette.card.opacity(0.45), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay { shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
        }
    }
}
