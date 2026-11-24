import AppKit
import SwiftUI

/// One choice of a `Dropdown`.
struct DropdownOption<ID: Hashable>: Identifiable {
    let id: ID
    /// A flag or other emoji before the title; read by nobody, the title says it all.
    var leading: String?
    let title: String
    var detail: String?

    var trailing: String?

    var selectedTitle: String { [title, detail].compactMap { $0 }.joined(separator: ", ") }
    var accessibleTitle: String { [selectedTitle, trailing].compactMap { $0 }.joined(separator: ", ") }
}

/// A choice drawn in the window instead of a system menu: the selected option and a chevron,
/// which open a list under it. The list is drawn by the nearest `dropdownLayer()`, so no card,
/// scroll view or clip around the trigger cuts it off. One list is open at a time.
struct Dropdown<ID: Hashable>: View {
    enum Trigger: Equatable {
        case selection, recordingChevron
    }

    /// What the trigger is, for accessibility.
    let label: LocalizedStringKey
    let options: [DropdownOption<ID>]
    @Binding var selection: ID
    var placeholder = ""
    var showsSelectedLeading = true
    var trigger: Trigger = .selection
    @State private var id = UUID()
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    private var isOpen: Bool { DropdownState.shared.open == id }
    private var selected: DropdownOption<ID>? { options.first { $0.id == selection } }

    var body: some View {
        styledTrigger
            .onHover { hovering = $0 && enabled }
            .motion(Motion.touch, value: hovering)
            .modifier(RecordingChevronHelp(label: label, applies: trigger == .recordingChevron))
            .accessibilityLabel(label)
            .accessibilityValue(Text(verbatim: selected?.selectedTitle ?? placeholder))
            .anchorPreference(key: DropdownKey.self, value: .bounds) { anchor in
                isOpen ? DropdownRequest(id: id, anchor: anchor, idealHeight: CGFloat(options.count * 30 + 12),
                                         dismissesOnScroll: trigger == .selection, list: { AnyView(list(maxHeight: $0)) }) : nil
            }
            .onDisappear { if isOpen { DropdownState.shared.open = nil } }
            .onChange(of: enabled) { if !enabled, isOpen { DropdownState.shared.open = nil } }
    }

    @ViewBuilder
    private var styledTrigger: some View {
        switch trigger {
        case .selection:
            triggerButton
                .buttonStyle(Pressable())
                .focusEffectDisabled()
                .opacity(enabled ? 1 : 0.5)
        case .recordingChevron:
            triggerButton
                .buttonStyle(SegmentPress(hovering: hovering || isOpen))
                .focusEffectDisabled()
        }
    }

    private var triggerButton: some View {
        Button { DropdownState.shared.open = isOpen ? nil : id } label: {
            switch trigger {
            case .selection:
                HStack(spacing: 6) {
                    if showsSelectedLeading, let leading = selected?.leading { Text(verbatim: leading) }
                    Text(verbatim: selected?.title ?? placeholder)
                    if let detail = selected?.detail {
                        Text(verbatim: detail).font(Typo.caption).foregroundStyle(Palette.secondary)
                    }
                    Icon("chevron-down", size: 12).foregroundStyle(Palette.secondary)
                }
                .font(Typo.body)
                .lineLimit(1)
                // The hover tint reaches past the text without moving it.
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(hovering || isOpen ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
                .contentShape(Rectangle())
            case .recordingChevron:
                Icon("chevron-down", size: 12)
                    .foregroundStyle(.white)
                    .frame(width: 32)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
        }
    }

    private func list(maxHeight: CGFloat) -> some View {
        DropdownList(options: options, selection: selection, maxHeight: maxHeight) { choice in
            selection = choice
            DropdownState.shared.open = nil
        }
    }
}

private struct RecordingChevronHelp: ViewModifier {
    let label: LocalizedStringKey
    let applies: Bool

    func body(content: Content) -> some View {
        if applies { content.help(label) } else { content }
    }
}

/// Which dropdown is open, so opening one closes any other and its host can close it.
@MainActor @Observable
final class DropdownState {
    static let shared = DropdownState()
    var open: UUID?
}

struct DropdownRequest {
    let id: UUID
    let anchor: Anchor<CGRect>
    let idealHeight: CGFloat
    let dismissesOnScroll: Bool
    let list: (CGFloat) -> AnyView
}

struct DropdownKey: PreferenceKey {
    static var defaultValue: DropdownRequest? { nil }
    static func reduce(value: inout DropdownRequest?, nextValue: () -> DropdownRequest?) {
        value = nextValue() ?? value
    }
}

/// The open list's rows: a check on the selected one, then its flag and title.
private struct DropdownList<ID: Hashable>: View {
    let options: [DropdownOption<ID>]
    let selection: ID
    let maxHeight: CGFloat
    let choose: (ID) -> Void
    @State private var highlight: ID?
    @FocusState private var focused: Bool

    private var reservesLeading: Bool { options.contains { $0.leading != nil } }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                rows
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(maxHeight, CGFloat(options.count * 30 + 12)))
            .onChange(of: highlight) { if let highlight { reader.scrollTo(highlight) } }
        }
        .frame(minWidth: 180)
        .fixedSize(horizontal: true, vertical: false)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Palette.shadow, radius: 32, y: 14)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            highlight = options.first { $0.id == selection }?.id ?? options.first?.id
            focused = true
        }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) { chooseHighlight() }
        .onKeyPress(.space) { chooseHighlight() }
        .onKeyPress(.escape) {
            DropdownState.shared.open = nil
            return .handled
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(options) { option in
                Button { choose(option.id) } label: {
                    HStack(spacing: 0) {
                        Icon("check", size: 14)
                            .foregroundStyle(Palette.orange)
                            .opacity(option.id == selection ? 1 : 0)
                        Spacer().frame(width: 8)
                        if reservesLeading {
                            Text(verbatim: option.leading ?? "").frame(width: 20, alignment: .leading)
                            Spacer().frame(width: 6)
                        }
                        Text(verbatim: option.title).foregroundStyle(Palette.text).lineLimit(1)
                        if let detail = option.detail {
                            Text(verbatim: detail).font(Typo.caption).foregroundStyle(Palette.secondary)
                                .padding(.leading, 6)
                        }
                        Spacer(minLength: option.trailing == nil ? 0 : 12)
                        if let trailing = option.trailing {
                            Text(verbatim: trailing).font(Typo.caption).foregroundStyle(Palette.secondary)
                        }
                    }
                    .font(Typo.body)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(highlight == option.id ? Palette.selected : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .id(option.id)
                .onHover { if $0 { highlight = option.id } }
                .accessibilityLabel(Text(verbatim: option.accessibleTitle))
                .accessibilityAddTraits(option.id == selection ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let ids = options.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let index = highlight.flatMap(ids.firstIndex) ?? 0
        highlight = ids[min(max(index + step, 0), ids.count - 1)]
        return .handled
    }

    private func chooseHighlight() -> KeyPress.Result {
        if let highlight { choose(highlight) }
        return .handled
    }
}

/// Draws the open dropdown above the views inside this layer. Apply at the root of a surface
/// whose content is clipped or scrolls.
private struct DropdownLayer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// Kept between the list and the layer's edge.
    private static let margin: CGFloat = 8

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(DropdownKey.self) { request in
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: proxy.size.width, height: proxy.size.height)
                    if let request {
                        DismissCatcher(dismissesOnScroll: request.dismissesOnScroll) { DropdownState.shared.open = nil }
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        list(request, rect: proxy[request.anchor], bounds: proxy.size)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
    }

    private func list(_ request: DropdownRequest, rect: CGRect, bounds: CGSize) -> some View {
        // Its top-trailing corner 6 pt under the trigger's bottom-trailing one, or above the
        // trigger when there is no room below.
        let below = max(0, bounds.height - Self.margin - rect.maxY - 6)
        let above = max(0, rect.minY - 6 - Self.margin)
        let upward = request.idealHeight > below && above > below
        let anchor: UnitPoint = upward ? .bottomTrailing : .topTrailing
        return request.list(upward ? above : below)
            .alignmentGuide(.leading) { d in d.width - rect.maxX }
            .alignmentGuide(.top) { d in upward ? d.height - (rect.minY - 6) : -(rect.maxY + 6) }
            .id(request.id)
            .transition(.asymmetric(
                insertion: (reduce ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: anchor)))
                    .animation(reduce ? .easeOut(duration: 0.12) : Motion.reveal),
                removal: .opacity.animation(.easeOut(duration: 0.12))))
    }
}

/// Covers the layer while a list is open and consumes outside clicks and scrolls.
private struct DismissCatcher: NSViewRepresentable {
    let dismissesOnScroll: Bool
    let dismiss: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.dismiss = dismiss
        view.dismissesOnScroll = dismissesOnScroll
    }

    final class CatcherView: NSView {
        var dismiss: () -> Void = {}
        var dismissesOnScroll = false
        override func mouseDown(with event: NSEvent) { dismiss() }
        override func rightMouseDown(with event: NSEvent) { dismiss() }
        override func otherMouseDown(with event: NSEvent) { dismiss() }
        override func scrollWheel(with event: NSEvent) { if dismissesOnScroll { dismiss() } }
    }
}

extension View {
    func dropdownLayer() -> some View { modifier(DropdownLayer()) }
}
