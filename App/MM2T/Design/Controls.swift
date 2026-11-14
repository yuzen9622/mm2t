import SwiftUI

/// Every tappable thing presses the same way: a small squeeze that springs back.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .motion(Motion.touch, value: configuration.isPressed)
    }
}

/// The app's one button shape. `primary` is the single orange action of a screen.
struct PillButton: View {
    enum Kind { case primary, ghost, danger }

    let title: LocalizedStringKey
    var icon: String?
    var kind = Kind.ghost
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    init(_ title: LocalizedStringKey, icon: String? = nil, kind: Kind = .ghost, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.action = action
    }

    var body: some View {
        Button(action: action) { PillLabel(title: title, icon: icon, kind: kind, hovering: hovering) }
            .buttonStyle(Pressable())
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .motion(Motion.touch, value: hovering)
    }
}

/// The pill's drawing, shared with menus that need the same look.
struct PillLabel: View {
    let title: LocalizedStringKey
    var icon: String?
    var kind = PillButton.Kind.ghost
    var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Icon(icon, size: 15) }
            Text(title).font(Typo.captionStrong)
        }
        .foregroundStyle(kind == .primary ? .white : kind == .danger ? Palette.danger : Palette.text)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(background, in: Capsule())
        .contentShape(Capsule())
    }

    private var background: Color {
        switch kind {
        case .primary: Palette.orange.opacity(hovering ? 0.88 : 1)
        case .ghost, .danger: hovering ? Palette.selected : Palette.tonal
        }
    }
}

/// A round icon-only button with a tooltip naming it.
struct IconButton: View {
    let title: LocalizedStringKey
    let icon: String
    var isOn = false
    let action: () -> Void
    @State private var hovering = false

    init(_ title: LocalizedStringKey, icon: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 17)
                .foregroundStyle(isOn ? Palette.orange : Palette.text)
                .frame(width: 32, height: 32)
                .background(isOn ? Palette.orangeSoft : hovering ? Palette.hover : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .tip(title, show: hovering)
        .accessibilityLabel(title)
    }
}

/// The surface every list item and panel sits on. `lifts` is for cards that open something.
struct CardModifier: ViewModifier {
    var lifts = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .shadow(color: Palette.shadow.opacity(lifts && hovering ? 1 : 0.6), radius: lifts && hovering ? 14 : 6, y: lifts && hovering ? 6 : 2)
            .offset(y: lifts && hovering ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .onHover { hovering = $0 }
            .motion(Motion.touch, value: hovering)
    }
}

extension View {
    func card(lifts: Bool = false) -> some View { modifier(CardModifier(lifts: lifts)) }
}

struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Icon("search", size: 15).foregroundStyle(focused ? Palette.orange : Palette.muted)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Icon("x", size: 13).foregroundStyle(Palette.secondary) }
                    .buttonStyle(Pressable())
                    .accessibilityLabel("Clear search")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(focused ? Palette.selected : Palette.field, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .motion(Motion.touch, value: focused)
        .motion(Motion.reveal, value: text.isEmpty)
    }
}

/// A single-line input in the app's field shape.
struct FieldBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .textFieldStyle(.plain)
            .font(Typo.body)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// Options in a track with one highlight that slides to the selection.
struct Segmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(title(option))
                        .font(selection == option ? Typo.captionStrong : Typo.caption)
                        .foregroundStyle(selection == option ? Palette.text : Palette.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .matchedGeometryEffect(id: option, in: space, isSource: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.card)
                .matchedGeometryEffect(id: selection, in: space, isSource: false)
        }
        .motion(Motion.select, value: selection)
        .padding(3)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// On/off as a sliding knob in the brand color.
struct SwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Capsule()
                .fill(configuration.isOn ? Palette.orange : Palette.field)
                .frame(width: 36, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                }
                .motion(Motion.select, value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
        }
        .opacity(enabled ? 1 : 0.45)
    }
}

struct ProgressLine: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(Palette.field)
                .overlay(alignment: .leading) {
                    Capsule().fill(Palette.orange).frame(width: max(4, proxy.size.width * fraction))
                }
        }
        .frame(height: 4)
        .motion(Motion.page, value: fraction)
    }
}

/// A tooltip that wants to show, reported up to the nearest `tipLayer()`.
struct TipRequest: Identifiable {
    let id: UUID
    let anchor: Anchor<CGRect>
    let text: Text
}

private struct TipKey: PreferenceKey {
    static let defaultValue: [TipRequest] = []
    static func reduce(value: inout [TipRequest], nextValue: () -> [TipRequest]) { value += nextValue() }
}

/// A small label naming what the pointer is over. The control only reports where it is; the label
/// is drawn by the `tipLayer()` at the root of its window, so neighbouring views, cards and scroll
/// views can neither cover nor clip it.
struct TipModifier: ViewModifier {
    let text: Text
    let show: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        let shown = show || SnapshotStage.shared.tip == text
        return content.anchorPreference(key: TipKey.self, value: .bounds) { shown ? [TipRequest(id: id, anchor: $0, text: text)] : [] }
    }
}

/// Draws every tooltip of the views inside it, above all of them. Apply once at the root of each
/// window (and of any sheet or popover) that shows tooltips. A label sits above its control,
/// centered, and moves below or lines up with an edge when the layer has no room there;
/// `prefersBelow` puts labels under their controls wherever there is room.
struct TipLayer: ViewModifier {
    var prefersBelow = false

    /// The label's height plus the gap to the control, and the widest half-label the app shows.
    private static let clearance: CGFloat = 36
    private static let reach: CGFloat = 64

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TipKey.self) { tips in
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    // Pins the stack's origin to the layer's, which the labels' guides count from.
                    Color.clear.frame(width: proxy.size.width, height: proxy.size.height)
                    ForEach(tips) { tip in label(tip, rect: proxy[tip.anchor], bounds: proxy.size) }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .motion(Motion.reveal, value: tips.map(\.id))
            }
            .allowsHitTesting(false)
        }
    }

    private func label(_ tip: TipRequest, rect: CGRect, bounds: CGSize) -> some View {
        let roomAbove = rect.minY >= Self.clearance
        let roomBelow = rect.maxY + Self.clearance <= bounds.height
        let below = prefersBelow ? roomBelow || !roomAbove : !roomAbove
        let horizontal: HorizontalAlignment = rect.midX < Self.reach ? .leading
            : rect.midX > bounds.width - Self.reach ? .trailing : .center
        return tip.text
            .font(Typo.captionStrong)
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(hex: 0x1B1B1D), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            .offset(y: below ? 30 : -30)
            // A frame the control's size with the label hanging out of it: the label keeps its own
            // width, so aligning to an edge makes it grow away from the layer's border.
            .frame(width: rect.width, height: rect.height, alignment: Alignment(horizontal: horizontal, vertical: below ? .bottom : .top))
            // Laid out over the control, not moved there by `position` or `offset`: those leave the
            // view's frame elsewhere (the whole layer, or its corner), and the transition would grow
            // the label out of that point instead of out of its control.
            .alignmentGuide(.leading) { _ in -rect.minX }
            .alignmentGuide(.top) { _ in -rect.minY }
            .transition(.scale(scale: 0.85, anchor: below ? .bottom : .top).combined(with: .opacity))
    }
}

extension View {
    func tip(_ title: LocalizedStringKey, show: Bool) -> some View { modifier(TipModifier(text: Text(title), show: show)) }
    func tip(verbatim name: String, show: Bool) -> some View { modifier(TipModifier(text: Text(verbatim: name), show: show)) }
    func tipLayer(prefersBelow: Bool = false) -> some View { modifier(TipLayer(prefersBelow: prefersBelow)) }
}

/// A speaker as a circled initial; orange once named, gray while still a letter code.
struct Avatar: View {
    let name: String
    let isNamed: Bool
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            Circle().fill(Palette.card)
            Circle().fill(isNamed ? Palette.orangeSoft : Palette.field)
            Text(String(name.prefix(1)))
                .font(.system(size: size * 0.44, weight: .medium, design: .rounded))
                .foregroundStyle(isNamed ? Palette.orange : Palette.secondary)
        }
        .frame(width: size, height: size)
            .accessibilityLabel(name)
    }
}

/// Overlapping avatars that spread apart under the pointer; the one being pointed at grows and
/// shows the person's name.
struct AvatarStack: View {
    struct Person: Identifiable, Hashable {
        let id: String
        let name: String
        let isNamed: Bool
    }

    let people: [Person]
    @State private var expanded = false
    @State private var focus: String?

    var body: some View {
        HStack(spacing: expanded ? 5 : -7) {
            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                Avatar(name: person.name, isNamed: person.isNamed)
                    .overlay(Circle().strokeBorder(Palette.card, lineWidth: 2))
                    .scaleEffect(focus == person.id ? 1.14 : 1)
                    .zIndex(focus == person.id ? 2 : Double(people.count - index) / 100)
                    .tip(verbatim: person.name, show: focus == person.id)
                    .onHover { inside in
                        if inside { focus = person.id } else if focus == person.id { focus = nil }
                    }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { expanded = $0 }
        .motion(Motion.select, value: expanded)
        .motion(Motion.touch, value: focus)
    }
}

/// A named group of rows on a card, used by settings-like screens.
struct Panel<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typo.captionStrong).foregroundStyle(Palette.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) { content }.card()
        }
    }
}
