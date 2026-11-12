import SwiftUI

/// A vertical scroll view whose content fades out at an edge only while there is more to scroll
/// that way: at rest at the top there is no fade above, at the end none below. The fade is a mask
/// on the content itself, so it dissolves into whatever ground is behind it without a tint of its own.
struct FadingScrollView<Content: View>: View {
    var fade: CGFloat = 28
    @ViewBuilder let content: Content
    @State private var contentFrame = CGRect.zero
    @State private var viewport: CGFloat = 0
    @State private var space = UUID()

    private var moreAbove: Bool { contentFrame.minY < -0.5 }
    private var moreBelow: Bool { contentFrame.maxY > viewport + 0.5 }

    var body: some View {
        ScrollView {
            content.background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ContentFrameKey.self, value: proxy.frame(in: .named(space)))
                }
            }
        }
        .coordinateSpace(name: space)
        .onPreferenceChange(ContentFrameKey.self) { contentFrame = $0 }
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { viewport = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in viewport = height }
            }
        }
        .mask {
            VStack(spacing: 0) {
                edge(faded: moreAbove, from: .bottom, to: .top)
                Rectangle()
                edge(faded: moreBelow, from: .top, to: .bottom)
            }
        }
        .motion(Motion.reveal, value: moreAbove)
        .motion(Motion.reveal, value: moreBelow)
    }

    private func edge(faded: Bool, from start: UnitPoint, to end: UnitPoint) -> some View {
        LinearGradient(colors: [.black, .black.opacity(faded ? 0 : 1)], startPoint: start, endPoint: end)
            .frame(height: fade)
    }
}

private struct ContentFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
