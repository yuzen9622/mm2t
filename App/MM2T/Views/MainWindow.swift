import MM2TApp
import MM2TCore
import SwiftUI

enum SidebarItem: Hashable, CaseIterable {
    case home
    case meetings
    case people
    case vocabulary
    case settings

    var icon: String {
        switch self {
        case .home: "home"
        case .meetings: "messages"
        case .people: "users"
        case .vocabulary: "book-2"
        case .settings: "settings"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .meetings: "Meetings"
        case .people: "People"
        case .vocabulary: "Vocabulary"
        case .settings: "Settings"
        }
    }

    /// The places the sidebar lists; settings opens as a dialog from the sidebar's foot instead.
    static let destinations: [SidebarItem] = [.home, .meetings, .people, .vocabulary]
}

/// Where the main window should go next, asked for from outside it, such as the menu bar.
@MainActor @Observable
final class MainNavigation {
    struct Request: Equatable {
        let section: SidebarItem
        var meeting: MeetingID?
    }

    static let shared = MainNavigation()
    var request: Request?
    /// Settings open as a dialog over the main window, on this section.
    var settingsOpen = false
    var settingsSection = SettingsSection.general

    /// Opens the main window on `section`, or on one meeting. `.settings` opens the settings dialog.
    func open(_ section: SidebarItem, meeting: MeetingID? = nil) {
        request = Request(section: section, meeting: meeting)
        WindowOpener.open(WindowID.main)
    }
}

/// The main window's content sits in one centered column that grows with the window up to a
/// reading width, instead of running edge to edge.
enum ContentColumn {
    static let share: CGFloat = 0.6
    /// The narrowest the column gets while there is room: what the window's minimum size leaves.
    static let minimum: CGFloat = 620
    static let maximum: CGFloat = 920

    static func width(window: CGFloat, available: CGFloat) -> CGFloat {
        min(available, max(minimum, min(maximum, window * share)))
    }
}

struct MainWindow: View {
    let app: AppController
    @State private var section = SidebarItem.home
    @State private var meeting: MeetingID?
    /// Whether the last section change went up the sidebar, so the title rolls the way the selection moved.
    @State private var movedUp = false
    @Namespace private var sidebarSpace
    @Environment(\.openURL) private var openURL

    static let sidebarWidth: CGFloat = 220

    var body: some View {
        let navigation = MainNavigation.shared
        Group {
            if app.needsOnboarding, !DebugSnapshot.isRequested, !WindowSharing.allowsCapture {
                SetupGate()
            } else {
            HStack(spacing: 0) {
                sidebar
                GeometryReader { proxy in
                    // A meeting's transcript and its side panels use the whole width.
                    let column = meeting == nil
                        ? ContentColumn.width(window: proxy.size.width + Self.sidebarWidth, available: proxy.size.width)
                        : proxy.size.width
                    content
                        .frame(width: column)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .topLeading) { title }
                        .frame(maxWidth: .infinity)
                }
                .background(Palette.window)
                .clipped()
            }
            .tipLayer()
            .overlay { settings(isOpen: navigation.settingsOpen) }
            }
        }
        .foregroundStyle(Palette.text)
        .font(Typo.body)
        .background(WindowChrome())
        .ignoresSafeArea()
        .frame(minWidth: 820, minHeight: 540)
        .onAppear {
            app.meetings.meLabel = Copy.presentationLabels.me
            app.dashboard.meLabel = Copy.presentationLabels.me
            DebugSnapshot.mainWindowAppeared(select: { show(.meetings, meeting: $0) }, show: { show($0) })
        }
        .onChange(of: MainNavigation.shared.request, initial: true) { _, request in
            guard let request else { return }
            show(request.section, meeting: request.meeting)
            MainNavigation.shared.request = nil
        }
    }

    /// A floating panel on the window's ground, set apart by tone and a soft shadow, never by a line.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text(verbatim: "mm2t").font(Typo.heading)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 18)

            RecordButton(capture: app.capture)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(SidebarItem.destinations, id: \.self) { row($0) }
            }
            // One highlight that travels to the selected row. Drawing it per row made the old one
            // fade out while the new one faded in, which read as a shadow passing rather than a move.
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.selected)
                    .matchedGeometryEffect(id: section, in: sidebarSpace, isSource: false)
            }
            .motion(Motion.select, value: section)

            Spacer(minLength: 12)
            HStack(spacing: 2) {
                IconButton("Settings", icon: "settings") { show(.settings) }
                IconButton("Help", icon: "help-circle") { openURL(AppLinks.help) }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 40)
        .padding(.bottom, 12)
        .frame(width: Self.sidebarWidth - 16)
        .frame(maxHeight: .infinity)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Palette.shadow.opacity(0.6), radius: 10, y: 2)
        .padding(8)
    }

    /// Settings float over the window on a dimmed backdrop, inside the window rather than in a sheet
    /// of their own, so a click on the backdrop closes them and a language change redraws them.
    private func settings(isOpen: Bool) -> some View {
        GeometryReader { proxy in
            ZStack {
                if isOpen {
                    Color.black.opacity(0.28)
                        .contentShape(Rectangle())
                        .onTapGesture { MainNavigation.shared.settingsOpen = false }
                        .transition(.opacity)
                    SettingsDialog(app: app)
                        .frame(width: min(780, proxy.size.width - 48), height: min(580, proxy.size.height - 48))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .motion(Motion.reveal, value: isOpen)
    }

    private func row(_ item: SidebarItem) -> some View {
        SidebarRow(item: item, isSelected: section == item, space: sidebarSpace) { show(item) }
    }

    private func show(_ item: SidebarItem, meeting: MeetingID? = nil) {
        if item == .settings {
            MainNavigation.shared.settingsOpen = true
            return
        }
        let order = SidebarItem.allCases
        movedUp = order.firstIndex(of: item)! < order.firstIndex(of: section)!
        section = item
        self.meeting = meeting
    }

    /// The section's name stays in place and its characters roll to the next name, the way a
    /// changing number does; only the panel under it fades. A meeting's own header replaces it.
    private var title: some View {
        Text(section.title)
            .font(Typo.title)
            .lineLimit(1)
            .contentTransition(.numericText(countsDown: movedUp))
            .motion(Motion.page, value: section)
            .opacity(meeting == nil ? 1 : 0)
            .motion(Motion.page, value: meeting)
            .padding(.horizontal, 24)
            .frame(height: 60)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var content: some View {
        ZStack {
            switch section {
            case .home, .settings:
                HomeView(app: app, open: { show(.meetings, meeting: $0) }).transition(.opacity)
            case .meetings:
                if let meeting {
                    MeetingDetailView(app: app, id: meeting, back: { self.meeting = nil })
                        .id(meeting)
                        .entrance(from: .trailing, distance: 28)
                } else {
                    MeetingListView(app: app, open: { meeting = $0 })
                        .transition(.opacity)
                }
            case .people:
                VoiceprintsView(model: app.people).transition(.opacity)
            case .vocabulary:
                VocabularyView(store: app.settings).transition(.opacity)
            }
        }
        .motion(Motion.page, value: section)
        .motion(Motion.page, value: meeting)
    }
}

/// What the main window shows until setup is finished: nothing of the app, and the way into setup.
struct SetupGate: View {
    var body: some View {
        VStack(spacing: 14) {
            Icon("microphone", size: 34).foregroundStyle(Palette.orange)
            Text("Finish setting up mm2t").font(Typo.title)
            Text("mm2t needs your permissions, your keys and a short reading in your own voice before it can take notes.")
                .foregroundStyle(Palette.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            PillButton("Continue Setup", kind: .primary) { WindowOpener.open(WindowID.onboarding) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.window)
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
            HStack(spacing: 10) {
                Icon(item.icon, size: 16)
                    .foregroundStyle(isSelected ? Palette.orange : Palette.secondary)
                Text(item.title)
                    .font(isSelected ? Typo.bodyStrong : Typo.body)
                    .foregroundStyle(isSelected ? Palette.text : Palette.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                if hovering, !isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.hover)
                }
            }
            .matchedGeometryEffect(id: item, in: space, isSource: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            // An empty unified toolbar makes AppKit set the traffic lights lower and further in, so
            // they sit inside the floating sidebar instead of on its edge, and keeps them there on resize.
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: "main")
                toolbar.showsBaselineSeparator = false
                window.toolbar = toolbar
            }
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor(Palette.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// The row at the top of every screen: its name on the left, its controls on the right. A section's
/// screen passes no title, because `MainWindow` draws the section's name in that spot.
struct ScreenHeader<Trailing: View>: View {
    var title: Text?
    var back: (() -> Void)?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            if let back {
                IconButton("Back", icon: "chevron-left", action: back)
            }
            if let title { title.font(Typo.title).lineLimit(1) }
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

/// Starts a recording from anywhere in the main window; while one runs it says so instead.
private struct RecordButton: View {
    let capture: CaptureController
    @State private var hovering = false

    var body: some View {
        let idle = capture.state == .idle
        Button {
            Task { await capture.startNow(title: String(localized: "Recording")) }
        } label: {
            HStack(spacing: 8) {
                if idle {
                    Icon("microphone", size: 16)
                } else {
                    Circle().fill(.white).frame(width: 7, height: 7)
                }
                Text(idle ? "Start Recording" : "Recording").font(Typo.bodyStrong)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Palette.orange.opacity(hovering && idle ? 0.88 : 1),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(Pressable())
        .disabled(!idle)
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
    }
}
