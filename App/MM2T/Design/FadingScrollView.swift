import SwiftUI

/// A vertical scroll view whose content fades out at an edge only while there is more to scroll
/// that way: at rest at the top there is no fade above, at the end none below. The fade dissolves
/// into the ground behind it without a tint of its own.
struct FadingScrollView<Content: View>: View {
    var fade: CGFloat = 28
    /// The solid colour the scroll view sits on, when it has one. The fade is then that colour laid
    /// over the edge, which costs nothing while scrolling; a mask redraws the whole view off screen
    /// on every frame, so it is kept for grounds that are not one flat colour.
    var ground: Color?
    @ViewBuilder let content: Content
    @State private var edges = ScrollEdges()

    var body: some View {
        if let ground {
            ScrollView { content }
                .modifier(ScrollEdgeReader(edges: $edges))
                // On macOS 26 a scroll view draws its content past its top edge, under the header.
                .clipped()
                .overlay(alignment: .top) { cover(ground, shown: edges.moreAbove, from: .top, to: .bottom) }
                .overlay(alignment: .bottom) { cover(ground, shown: edges.moreBelow, from: .bottom, to: .top) }
                .motion(Motion.reveal, value: edges)
        } else {
            ScrollView { content }
                .modifier(ScrollEdgeReader(edges: $edges))
                .mask {
                    VStack(spacing: 0) {
                        edge(faded: edges.moreAbove, from: .bottom, to: .top)
                        Rectangle()
                        edge(faded: edges.moreBelow, from: .top, to: .bottom)
                    }
                }
                .motion(Motion.reveal, value: edges)
        }
    }

    private func cover(_ ground: Color, shown: Bool, from start: UnitPoint, to end: UnitPoint) -> some View {
        LinearGradient(colors: [ground, ground.opacity(0)], startPoint: start, endPoint: end)
            .frame(height: fade)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func edge(faded: Bool, from start: UnitPoint, to end: UnitPoint) -> some View {
        LinearGradient(colors: [.black, .black.opacity(faded ? 0 : 1)], startPoint: start, endPoint: end)
            .frame(height: fade)
    }
}

/// Whether a scroll view has content past its top and past its bottom.
struct ScrollEdges: Equatable {
    var moreAbove = false
    var moreBelow = false
}

/// Reads the scroll position. Before macOS 15 there is no way to read it, and the edges never fade.
private struct ScrollEdgeReader: ViewModifier {
    @Binding var edges: ScrollEdges

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                let top = geometry.contentOffset.y + geometry.contentInsets.top
                let bottom = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
                return ScrollEdges(moreAbove: top > 0.5, moreBelow: bottom < geometry.contentSize.height - 0.5)
            } action: { _, new in
                edges = new
            }
        } else {
            content
        }
    }
}
