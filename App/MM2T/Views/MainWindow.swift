import MM2TApp
import MM2TCore
import SwiftUI

enum SidebarItem: Hashable, CaseIterable {
    case meetings
    case people
    case vocabulary
    case settings

    var icon: String {
        switch self {
        case .meetings: "messages"
        case .people: "users"
        case .vocabulary: "book-2"
        case .settings: "settings"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .meetings: "Meetings"
        case .people: "People"
        case .vocabulary: "Vocabulary"
        case .settings: "Settings"
        }
    }
}

struct MainWindow: View {
    let app: AppController
    @State private var section = SidebarItem.meetings
    @State private var meeting: MeetingID?
    @Namespace private var sidebarSpace

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Palette.border)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.window)
                .clipped()
        }
        .foregroundStyle(Palette.text)
        .font(Typo.body)
        .background(WindowChrome())
        .ignoresSafeArea()
        .frame(minWidth: 820, minHeight: 540)
        .onAppear {
            app.meetings.meLabel = Copy.presentationLabels.me
            DebugSnapshot.mainWindowAppeared(select: { section = .meetings; meeting = $0 })
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach([SidebarItem.meetings, .people, .vocabulary], id: \.self) { row($0) }
            Spacer()
            row(.settings)
        }
        // One highlight that travels to the selected row. Drawing it per row made the old one
        // fade out while the new one faded in, which read as a shadow passing rather than a move.
        .background {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Palette.orangeSoft)
                .matchedGeometryEffect(id: section, in: sidebarSpace, isSource: false)
        }
        .motion(Motion.select, value: section)
        .padding(.horizontal, 10)
        .padding(.top, 52)
        .padding(.bottom, 12)
        .frame(width: 176)
        .background(Palette.sidebar)
    }

    private func row(_ item: SidebarItem) -> some View {
        SidebarRow(item: item, isSelected: section == item, space: sidebarSpace) {
            section = item
            if item != .meetings { meeting = nil }
        }
    }

    @ViewBuilder private var content: some View {
        ZStack {
            switch section {
            case .meetings:
                if let meeting {
                    MeetingDetailView(app: app, id: meeting, back: { self.meeting = nil })
                        .id(meeting)
                        .entrance(from: .trailing, distance: 28)
                } else {
                    MeetingListView(app: app, open: { meeting = $0 })
                        .entrance(from: .leading, distance: 28)
                }
            case .people:
                VoiceprintsView(model: app.people).entrance()
            case .vocabulary:
                VocabularyView(store: app.settings).entrance()
            case .settings:
                SettingsView(app: app).entrance()
            }
        }
        .motion(Motion.page, value: section)
        .motion(Motion.page, value: meeting)
    }
}

struct SidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let space: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Icon(item.icon, size: 17)
                Text(item.title).font(isSelected ? Typo.bodyStrong : Typo.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Palette.orange : Palette.secondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                if hovering, !isSelected {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.hover)
                }
            }
            .matchedGeometryEffect(id: item, in: space, isSource: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
    }
}

/// Lets the content run under the title bar so the sidebar reaches the top, and makes the empty
/// background drag the window.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(Palette.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// The row at the top of every screen: its name on the left, its controls on the right.
struct ScreenHeader<Trailing: View>: View {
    let title: Text
    var back: (() -> Void)?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            if let back {
                IconButton("Back", icon: "chevron-left", action: back)
            }
            title.font(Typo.title).lineLimit(1)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
    }
}

/// What a screen shows when it has nothing yet.
struct EmptyState: View {
    let icon: String
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            Icon(icon, size: 30).foregroundStyle(Palette.muted)
            Text(title).foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
