import AppKit
import MM2TApp
import MM2TCore
import SwiftUI

struct SearchKeycap: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .font(Typo.captionStrong)
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(Palette.tonal, in: RoundedRectangle(cornerRadius: 5))
    }
}

struct SearchPaletteTrigger: View {
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Icon("search", size: 15)
                Text("Search").font(Typo.body)
                Spacer(minLength: 0)
                SearchKeycap(text: "⌘K")
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 12)
            .frame(width: 220, height: 32)
            .background(Palette.field, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("Search meetings, transcripts and people")
    }
}

struct SearchPaletteOverlay: View {
    let app: AppController
    let isOpen: Bool
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if isOpen {
                    Palette.backdrop
                        .contentShape(Rectangle())
                        .onTapGesture(perform: close)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.15)),
                            removal: .opacity.animation(.easeOut(duration: 0.12))))
                        .accessibilityHidden(true)
                    SearchPalette(app: app, maxHeight: geometry.size.height * 0.6, close: close)
                        .frame(width: min(640, max(480, geometry.size.width - 48)))
                        .padding(.top, geometry.size.height * 0.16)
                        .transition(reduce ? .opacity : .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: -8)),
                            removal: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .motion(isOpen ? Motion.reveal : .easeOut(duration: 0.12), value: isOpen)
        }
        .allowsHitTesting(isOpen)
    }
}

private struct SearchPalette: View {
    let maxHeight: CGFloat
    let close: () -> Void
    @State private var model: SearchPaletteModel
    @State private var pointer = NSEvent.mouseLocation
    @State private var repeatingKey = false
    @Namespace private var selectionSpace
    @FocusState private var focused: Bool
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduce

    init(app: AppController, maxHeight: CGFloat, close: @escaping () -> Void) {
        self.maxHeight = maxHeight
        self.close = close
        _model = State(initialValue: SearchPaletteModel(index: app.searchIndex, voiceprints: app.voiceprints))
    }

    private var contentHeight: CGFloat {
        if model.failed || model.rows.isEmpty { return 150 }
        return model.rows.reduce(CGFloat(8)) { height, row in
            height + rowHeight(row) + (heading(for: row) == nil ? 0 : 30)
        }
    }

    var body: some View {
        let height = min(maxHeight, 52 + 4 + 30 + contentHeight + 34)
        VStack(spacing: 0) {
            input
            filters.padding(.top, 4)
            results.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(height: height)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Palette.shadow, radius: 32, y: 14)
        .motion(Motion.reveal, value: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search")
        .accessibilityAddTraits(.isModal)
        .task {
            focused = true
            await model.open()
        }
        .onDisappear { model.close() }
        .onExitCommand(perform: close)
    }

    private var input: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Icon("search", size: 17).foregroundStyle(model.query.isEmpty ? Palette.muted : Palette.orange)
            TextField("Search meetings, transcripts and people", text: $model.query)
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .textFieldStyle(.plain)
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape], phases: [.down, .repeat]) { press in
                    pointer = NSEvent.mouseLocation
                    repeatingKey = press.phase == .repeat
                    switch press.key {
                    case .upArrow: model.move(-1)
                    case .downArrow: model.move(1)
                    case .return: activate()
                    case .escape: close()
                    default: return .ignored
                    }
                    return .handled
                }
            if model.query.isEmpty {
                SearchKeycap(text: "esc")
            } else {
                Button { model.query = ""; focused = true } label: {
                    Icon("x", size: 13).foregroundStyle(Palette.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var filters: some View {
        HStack(spacing: 6) {
            chip(icon: "user", value: model.person.flatMap { model.names[$0] }, placeholder: "Person") {
                if model.person != nil { model.person = nil } else { model.show(.people) }
            }
            chip(icon: "calendar-event", value: model.date.map(Copy.searchDate), placeholder: "Date") {
                if model.date != nil { model.date = nil } else { model.show(.dates) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 30)
    }

    private func chip(icon: String, value: String?, placeholder: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button { action(); focused = true } label: {
            HStack(spacing: 5) {
                Icon(icon, size: 13)
                if let value { Text(verbatim: value).lineLimit(1) } else { Text(placeholder) }
                if value != nil { Icon("x", size: 11) }
            }
            .font(Typo.captionStrong)
            .foregroundStyle(value == nil ? Palette.secondary : Palette.orange)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(value == nil ? Palette.tonal : Palette.orangeSoft, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var results: some View {
        ScrollViewReader { proxy in
            FadingScrollView(ground: Palette.panel) {
                VStack(spacing: 0) {
                    if model.failed {
                        VStack(spacing: 10) {
                            EmptyState(icon: "alert-triangle", title: "Search unavailable")
                            PillButton("Retry") { Task { await model.refresh() }; focused = true }
                        }.frame(height: 140)
                    } else if model.rows.isEmpty {
                        VStack(spacing: 10) {
                            Icon("search", size: 30).foregroundStyle(Palette.muted)
                            Text("No results").foregroundStyle(Palette.secondary)
                            Text("Try fewer words, or clear the filters.").foregroundStyle(Palette.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 140)
                    } else {
                        ForEach(model.rows) { row in
                            if let heading = heading(for: row) {
                                Text(heading)
                                    .font(Typo.captionStrong)
                                    .foregroundStyle(Palette.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 18)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            resultRow(row).id(row.id)
                        }
                    }
                }
                .background {
                    if let selection = model.selection {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Palette.selected)
                            .matchedGeometryEffect(id: selection, in: selectionSpace, isSource: false)
                            .transaction { if reduce || repeatingKey { $0.animation = nil } }
                            .motion(Motion.touch, value: selection)
                    }
                }
                .padding(.top, 8)
                .transaction { $0.animation = nil }
            }
            .onChange(of: model.rows) { _, _ in
                if let id = model.selection { proxy.scrollTo(id) }
            }
            .onChange(of: model.selection) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
                if let row = model.rows.first(where: { $0.id == id }), let window = NSApp.keyWindow {
                    NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                        .announcement: Copy.searchRow(row, locale: locale),
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                    ])
                }
            }
        }
    }

    private func heading(for row: SearchPaletteModel.Row) -> LocalizedStringKey? {
        if model.picker == .people { return row.id == model.rows.first?.id ? "People" : nil }
        if model.picker == .dates { return row.id == model.rows.first?.id ? "Date" : nil }
        guard model.isRecent else { return nil }
        switch row.content {
        case .meeting: return row.id == model.rows.first?.id ? "Recent meetings" : nil
        case .person:
            let firstPerson = model.rows.first { if case .person = $0.content { true } else { false } }
            return row.id == firstPerson?.id ? "People" : nil
        default: return nil
        }
    }

    private func rowHeight(_ row: SearchPaletteModel.Row) -> CGFloat {
        switch row.content { case .hit, .more: 30; default: 38 }
    }

    private func resultRow(_ row: SearchPaletteModel.Row) -> some View {
        Button { activate(row.id) } label: {
            rowContent(row)
                .padding(.horizontal, 10)
                .frame(height: rowHeight(row))
                .frame(maxWidth: .infinity, alignment: .leading)
                .matchedGeometryEffect(id: row.id, in: selectionSpace, isSource: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.horizontal, 8)
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            let location = NSEvent.mouseLocation
            guard location != pointer else { return }
            pointer = location
            repeatingKey = false
            model.select(row.id)
        }
        .accessibilityLabel(Text(verbatim: Copy.searchRow(row, locale: locale)))
        .accessibilityAddTraits(model.selection == row.id ? .isSelected : [])
    }

    @ViewBuilder private func rowContent(_ row: SearchPaletteModel.Row) -> some View {
        switch row.content {
        case .meeting(let meeting):
            HStack(spacing: 8) {
                Icon("file-text", size: 15).foregroundStyle(Palette.secondary)
                Text(verbatim: meeting.title).font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: Copy.searchMeetingDate(meeting.startedAt, locale: locale))
                    .font(Typo.caption).foregroundStyle(Palette.muted).monospacedDigit()
            }
        case .hit(let meeting, let index):
            let hit = meeting.hits[index]
            HStack(spacing: 8) {
                if let kind = Copy.searchKind(hit.kind) {
                    Text(verbatim: kind).font(Typo.caption).foregroundStyle(Palette.muted).fixedSize()
                } else if hit.kind != .title {
                    let name = hit.speaker.flatMap { model.names[$0] }
                    Avatar(name: name ?? "", isNamed: name != nil, size: 16).frame(width: 15)
                }
                SearchSnippet(hit: hit).frame(height: 26)
                if let time = hit.time {
                    Text(verbatim: MeetingPresentation.timestamp(time))
                        .font(Typo.caption).foregroundStyle(Palette.muted).monospacedDigit().fixedSize()
                }
            }
            .padding(.leading, Copy.searchKind(hit.kind) != nil || hit.kind == .title ? 23 : 0)
        case .more(let meeting):
            Text(verbatim: Copy.searchMore(meeting.totalHits - meeting.hits.count))
                .font(Typo.caption).foregroundStyle(Palette.muted).padding(.leading, 23)
        case .person(_, let name):
            HStack(spacing: 8) {
                Avatar(name: name, isNamed: true, size: 24)
                Text(verbatim: name).font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
                Spacer(minLength: 0)
            }
        case .date(let date):
            HStack(spacing: 8) {
                Icon("calendar-event", size: 15).foregroundStyle(Palette.secondary)
                Text(verbatim: Copy.searchDate(date)).font(Typo.body).foregroundStyle(Palette.text)
                Spacer(minLength: 0)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) { SearchKeycap(text: "↑↓"); Text("Navigate") }
            HStack(spacing: 5) { SearchKeycap(text: "↵"); Text("Open") }
            Spacer(minLength: 0)
            HStack(spacing: 5) { SearchKeycap(text: "esc"); Text("Close") }
        }
        .font(Typo.caption)
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(Palette.tonal)
    }

    private func activate(_ id: SearchPaletteModel.Row.ID? = nil) {
        if let destination = model.activate(id) {
            close()
            MainNavigation.shared.open(.meetings, meeting: destination.meeting, utterance: destination.utterance)
        } else { focused = true }
    }
}
