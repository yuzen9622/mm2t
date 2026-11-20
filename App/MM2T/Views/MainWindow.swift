import MM2TApp
import MM2TCore
import SwiftUI

enum SidebarItem: Hashable, CaseIterable {
    case home
    case people
    case vocabulary
    case meetings
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
        case .meetings: "Unfiled"
        case .people: "People"
        case .vocabulary: "Vocabulary"
        case .settings: "Settings"
        }
    }

    /// The places the sidebar lists; settings opens as a dialog from the sidebar's foot instead.
    static let destinations: [SidebarItem] = [.home, .people, .vocabulary]
}

/// Where the main window should go next, asked for from outside it, such as the menu bar.
@MainActor @Observable
final class MainNavigation {
    struct Request: Equatable {
        let section: SidebarItem
        var meeting: MeetingID?
        var utterance: UtteranceID?
    }

    static let shared = MainNavigation()
    var request: Request?
    /// Settings open as a dialog over the main window, on this section.
    var settingsOpen = false
    var searchOpen = false
    var assistantQuestion: String?
    var settingsSection = SettingsSection.general
    /// The live page covers the window's content while a recording runs; closing it returns to
    /// the page underneath.
    var liveOpen = false
    /// The live page is showing in the key window, so the caption bar steps aside.
    var liveFrontmost = false

    /// Opens the main window on `section`, or on one meeting. `.settings` opens the settings dialog.
    func open(_ section: SidebarItem, meeting: MeetingID? = nil, utterance: UtteranceID? = nil) {
        request = Request(section: section, meeting: meeting, utterance: utterance)
        WindowOpener.open(WindowID.main)
    }

    /// Opens the main window on the recording in progress.
    func openLive() {
        liveOpen = true
        WindowOpener.open(WindowID.main)
    }

    /// Asked for from anywhere: the main window shows setup again. `MainWindow` takes the request.
    var setupRequested = false

    func openSetup() {
        setupRequested = true
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
    @State private var foldersExpanded = true
    @State private var filingDrag = FilingDragState()
    @State private var addingFolder = false
    @State private var editingFolder: MeetingFolders.Folder?
    @State private var expandedFolderIDs: Set<UUID?> = []
    @State private var assistant: AssistantModel
    @State private var section = SidebarItem.home
    @State private var meeting: MeetingID?
    @State private var utterance: UtteranceID?
    @State private var todoKey: String?
    @State private var destinationID = UUID()
    @State private var vocabularyEditor: VocabularyView.Editor?
    /// Whether the last section change went up the sidebar, so the title rolls the way the selection moved.
    @State private var movedUp = false
    @Namespace private var sidebarSpace
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// Setup or the app, or the window on its way from one to the other.
    @State private var stage: WindowStage
    /// During a change of stage, whether the arriving side has started to show.
    @State private var arriving = false

    static let sidebarWidth: CGFloat = 220
    static let setupSize = CGSize(width: 600, height: 580)
    static let appMinimum = CGSize(width: 820, height: 540)

    init(app: AppController) {
        self.app = app
        _assistant = State(initialValue: app.makeAssistant())
        _stage = State(initialValue: app.showsSetup ? .setup : .app)
    }

    var body: some View {
        let navigation = MainNavigation.shared
        ZStack {
            // While the frame changes, the ground shows alone: nothing of the app is drawn squashed.
            Palette.window
            if stage == .setup || (stage == .toSetup && arriving) {
                OnboardingView(app: app)
                    .transition(arrival)
            }
            if stage == .app || (stage == .toApp && arriving) {
                appContent
                    // Laid out at the app's size even while the window is still smaller, and clipped.
                    .frame(minWidth: Self.appMinimum.width, minHeight: Self.appMinimum.height)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .transition(arrival)
            }
        }
        .foregroundStyle(Palette.text)
        .font(Typo.body)
        .background(WindowChrome(close: windowClosed, shouldClose: shouldClose, layout: stage.layout, settled: settled))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            assistant.close()
        }
        .ignoresSafeArea()
        // The window takes its limits from these: fixed while setup shows, the app's minimum
        // after, and loose while the frame animates between them.
        .frame(minWidth: stage == .app ? Self.appMinimum.width : Self.setupSize.width,
               maxWidth: stage == .setup ? Self.setupSize.width : .infinity,
               minHeight: stage == .app ? Self.appMinimum.height : Self.setupSize.height,
               maxHeight: stage == .setup ? Self.setupSize.height : .infinity)
        .task(id: app.shouldPrepareBreeze, priority: .utility) { await app.preparePreferredBreeze() }
        .onChange(of: app.showsSetup) { _, setup in travel(toSetup: setup) }
        .onChange(of: navigation.setupRequested, initial: true) {
            guard navigation.setupRequested else { return }
            navigation.setupRequested = false
            navigation.searchOpen = false
            navigation.settingsOpen = false
            app.openSetup()
        }
        .onAppear {
            app.meetings.meLabel = Copy.presentationLabels.me
            app.dashboard.meLabel = Copy.presentationLabels.me
        }
        .onChange(of: MainNavigation.shared.assistantQuestion, initial: true) {
            guard let question = MainNavigation.shared.assistantQuestion else { return }
            MainNavigation.shared.assistantQuestion = nil
            assistant.handoff(question)
            show(.meetings)
        }
        .onChange(of: app.capture.state.isCapturing) { _, capturing in
            if capturing { showSavedMeeting = false }
            else {
                showSavedMeeting = navigation.liveOpen
                navigation.liveOpen = false
            }
        }
        .onChange(of: app.capture.lastSavedMeeting) { _, id in
            if showSavedMeeting, let id {
                showSavedMeeting = false
                show(.meetings, meeting: id)
            }
        }
        .onChange(of: MainNavigation.shared.request, initial: true) { _, request in
            guard let request else { return }
            show(request.section, meeting: request.meeting, utterance: request.utterance)
            MainNavigation.shared.request = nil
        }
    }

    /// The side arriving rises 6 pt as it fades in; the side leaving only fades. Reduce Motion: fades.
    private var arrival: AnyTransition {
        .asymmetric(insertion: reduce ? .opacity : .opacity.combined(with: .offset(y: 6)), removal: .opacity)
    }

    /// Setup fades out (0.15 s) as the frame starts to change; the other side fades in over the
    /// last 0.25 s of the frame's 0.45 s. Reduce Motion: the frame jumps and the two cross-fade.
    private func travel(toSetup: Bool) {
        let target: WindowStage = toSetup ? .toSetup : .toApp
        guard stage != (toSetup ? .setup : .app), stage != target else { return }
        arriving = false
        withAnimation(.easeOut(duration: 0.15)) { stage = target }
        let delay = reduce ? 0 : Motion.windowDuration - 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard stage == target else { return }
            withAnimation(.easeOut(duration: 0.25)) { arriving = true }
        }
    }

    /// The frame reached `layout`; the window takes that side's limits from here.
    private func settled(_ layout: WindowLayout) {
        switch (stage, layout) {
        case (.toApp, .app): stage = .app
        case (.toSetup, .compact): stage = .setup
        default: break
        }
    }

    private func windowClosed() {
        assistant.close()
    }

    /// The close button (and ⌘W) on setup opened again from the finished app leaves setup instead,
    /// growing back into the app; anywhere else it closes the window. Ignored while the frame moves.
    private func shouldClose() -> Bool {
        switch stage {
        case .toApp, .toSetup: return false
        case .setup where app.canCloseSetup:
            app.closeSetup()
            return false
        case .setup, .app: return true
        }
    }

    @ViewBuilder private var appContent: some View {
        let navigation = MainNavigation.shared
        Group {
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
                        .overlay(alignment: .topLeading) { title.opacity(showsLive ? 0 : 1) }
                        .overlay {
                            if showsLive {
                                LivePage(app: app, collapse: { navigation.liveOpen = false })
                                    .entrance(from: .bottom, distance: 12)
                            }
                        }
                        .motion(Motion.page, value: showsLive)
                        .frame(maxWidth: .infinity)
                }
                .background(Palette.window)
                .clipped()
            }
            .coordinateSpace(name: "meeting-filing")
            .onPreferenceChange(FilingBounds.self) { filingDrag.bounds = $0 }
            .overlay(alignment: .topLeading) {
                if let item = filingDrag.item {
                    HStack(spacing: 6) { Icon("file-text", size: 14).foregroundStyle(Palette.orange); Text(verbatim: item.title).lineLimit(1).font(Typo.captionStrong) }
                        .padding(.horizontal, 10).frame(height: 28).background(Palette.panel, in: Capsule()).shadow(color: Palette.shadow, radius: 6, y: 2)
                        .fixedSize().offset(x: filingDrag.location.x + 8, y: filingDrag.location.y + 8).allowsHitTesting(false)
                }
            }
            .environment(filingDrag)
            .dropdownLayer()
            .tipLayer()
            .disabled(vocabularyEditor != nil)
            .accessibilityHidden(vocabularyEditor != nil)
            .overlay { vocabularyDialog }
            .sheet(isPresented: $addingFolder) {
                FolderNameDialog(save: { name in
                    if let id = app.folders.create(name) { selectFolder(id); addingFolder = false }
                }, dismiss: { addingFolder = false })
            }
            .sheet(item: $editingFolder) { folder in
                FolderNameDialog(folder: folder, validate: { app.folders.canRename(folder.id, to: $0) }, save: { name in
                    if app.folders.rename(folder.id, to: name) { editingFolder = nil }
                }, dismiss: { editingFolder = nil })
            }
            .overlay { settings(isOpen: navigation.settingsOpen) }
        }
        .disabled(navigation.searchOpen)
        .accessibilityHidden(navigation.searchOpen)
        .overlay {
            SearchPaletteOverlay(app: app, isOpen: navigation.searchOpen) {
                navigation.searchOpen = false
            }
        }
    }

    /// The live page shows only while a recording runs.
    @State private var showSavedMeeting = false

    private var showsLive: Bool { MainNavigation.shared.liveOpen && app.capture.state.isCapturing }

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

            RecordButton(capture: app.capture, openLive: { MainNavigation.shared.openLive() })
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(SidebarItem.destinations, id: \.self) { item in
                    SidebarRow(item: item, isSelected: section == item, space: sidebarSpace) { show(item) }
                }
            }
            // One highlight that travels to the selected row. Drawing it per row made the old one
            // fade out while the new one faded in, which read as a shadow passing rather than a move.
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(section == .meetings ? .clear : Palette.selected)
                    .matchedGeometryEffect(id: section, in: sidebarSpace, isSource: false)
            }
            .motion(Motion.select, value: section)

            folderSection
            Spacer(minLength: 12)
            if let update = app.voiceprintUpdate {
                VoiceprintUpdateStatus(update: update)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
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
        // Lists open from settings rows are drawn here, outside the dialog's clip and scroll view.
        .dropdownLayer()
        .motion(Motion.reveal, value: isOpen)
        .onChange(of: isOpen) { if !isOpen { DropdownState.shared.open = nil } }
    }

    private var vocabularyDialog: some View {
        ZStack {
            if let editor = vocabularyEditor {
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture { vocabularyEditor = nil }
                    .transition(.opacity)
                VocabularyEditor(store: app.settings, term: editor.term) { vocabularyEditor = nil }
                    .background(Palette.window)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
                    .padding(24)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .motion(Motion.reveal, value: vocabularyEditor != nil)
    }

    private func selectFolder(_ id: UUID?, expand: Bool = true) {
        if expand { foldersExpanded = true; expandedFolderIDs.insert(id) }
        DropdownState.shared.open = nil
        assistant.isActive = false
        app.folders.selected = id
        show(.meetings)
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Button { foldersExpanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Icon("chevron-right", size: 11).rotationEffect(.degrees(foldersExpanded ? 90 : 0))
                        Text("My Folders").font(Typo.captionStrong)
                    }.foregroundStyle(Palette.secondary).padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
                }.buttonStyle(Pressable())
                Spacer()
                IconButton("New Folder", icon: "plus") { addingFolder = true }
            }
            if foldersExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        folderBranch(nil)
                        ForEach(app.folders.folders) { folder in folderBranch(folder) }
                    }
                }.entrance(from: .top, distance: 6)
            }
        }.padding(.top, 12)
        .motion(Motion.reveal, value: foldersExpanded)
        .motion(Motion.reveal, value: expandedFolderIDs)
    }

    @ViewBuilder private func folderBranch(_ folder: MeetingFolders.Folder?) -> some View {
        let id = folder?.id
        let expanded = expandedFolderIDs.contains(id)
        let selected = section == .meetings && app.folders.selected == id
        let target = FilingTarget.folder(id)
        FolderSidebarRow(name: folder?.name ?? String(localized: "Unfiled"), icon: "folder", expanded: expanded,
            selected: selected, accepting: filingDrag.hovered == target, received: filingDrag.received == target) {
                if expanded && selected && meeting == nil { expandedFolderIDs.remove(id) }
                else { expandedFolderIDs.insert(id) }
                selectFolder(id, expand: false)
            }
            .filingTarget(target)
            .contextMenu {
                if let folder {
                    Button("Edit Folder") { editingFolder = folder }
                    Divider()
                    Button("Delete Folder", role: .destructive) { expandedFolderIDs.remove(id); app.folders.delete(folder.id) }
                }
            }
        if expanded {
            VStack(spacing: 1) {
                ForEach(app.meetings.rows.filter { app.folders.folder(of: $0.id) == id }) { row in
                    FolderSidebarRow(name: row.title, icon: "file-text", selected: meeting == row.id) {
                        app.folders.selected = id; show(.meetings, meeting: row.id)
                    }
                }
            }.padding(.leading, 20).entrance(from: .top, distance: 5)
        }
    }

    private func show(_ item: SidebarItem, meeting: MeetingID? = nil, utterance: UtteranceID? = nil, todoKey: String? = nil) {
        if item == .settings {
            MainNavigation.shared.settingsOpen = true
            return
        }
        MainNavigation.shared.liveOpen = false
        if meeting != nil {
            MainNavigation.shared.settingsOpen = false
            vocabularyEditor = nil
        }
        let order = SidebarItem.allCases
        movedUp = order.firstIndex(of: item)! < order.firstIndex(of: section)!
        section = item
        self.meeting = meeting
        self.utterance = utterance
        self.todoKey = todoKey
        destinationID = UUID()
    }

    /// The section's name stays in place and its characters roll to the next name, the way a
    /// changing number does; only the panel under it fades. A meeting's own header replaces it.
    @ViewBuilder private var title: some View {
        if section == .meetings && meeting == nil {
            Dropdown<UUID?>(label: "Folders", options: [DropdownOption(id: nil, title: String(localized: "Unfiled"))] + app.folders.folders.map { DropdownOption(id: $0.id, title: $0.name) }, selection: Binding(get: { app.folders.selected }, set: { selectFolder($0) }))
                .padding(.leading, 24).frame(height: 60)
        } else { sectionTitle }
    }

    private var sectionTitle: some View {
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
                HomeView(app: app, open: { show(.meetings, meeting: $0, todoKey: $1) }).transition(.opacity)
            case .meetings:
                if let meeting {
                    MeetingDetailView(app: app, id: meeting, utterance: utterance, todoKey: todoKey, back: { self.meeting = nil })
                        .id(destinationID)
                        .entrance(from: .trailing, distance: 28)
                } else {
                    MeetingListView(app: app, assistant: assistant, open: { show(.meetings, meeting: $0) })
                        .transition(.opacity)
                }
            case .people:
                VoiceprintsView(model: app.people).transition(.opacity)
            case .vocabulary:
                VocabularyView(store: app.settings, editor: $vocabularyEditor).transition(.opacity)
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

/// What the main window shows: setup in a compact window, or the app, or the frame on its way
/// from one to the other.
enum WindowStage: Equatable {
    case setup
    case toApp
    case app
    case toSetup

    var layout: WindowLayout {
        switch self {
        case .setup, .toSetup: .compact
        case .app, .toApp: .app
        }
    }
}

/// The main window's frame: compact and centred for setup, or the app's own frame.
enum WindowLayout: Equatable {
    case compact
    case app
}

/// Lets the content run under the title bar so the sidebar reaches the top, makes the empty
/// background drag the window, and sizes the window for setup or the app.
struct WindowChrome: NSViewRepresentable {
    let close: () -> Void
    /// Asked before the window closes; false keeps it open.
    let shouldClose: () -> Bool
    let layout: WindowLayout
    /// Called once the frame has reached a new layout.
    let settled: (WindowLayout) -> Void

    func makeNSView(context: Context) -> WindowHost {
        let view = WindowHost()
        view.close = close
        view.shouldClose = shouldClose
        view.settled = settled
        view.animates = !context.environment.accessibilityReduceMotion
        view.request(layout)
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

    func updateNSView(_ view: WindowHost, context: Context) {
        view.close = close
        view.shouldClose = shouldClose
        view.settled = settled
        view.animates = !context.environment.accessibilityReduceMotion
        view.request(layout)
    }

    final class WindowHost: NSView {
        var close: () -> Void = {}
        var shouldClose: () -> Bool = { true }
        var settled: (WindowLayout) -> Void = { _ in }
        var animates = true
        private var wanted = WindowLayout.app
        private var applied: WindowLayout?
        private var resizing = false

        /// The app's frame is kept here, never through AppKit's frame autosave, so the compact
        /// setup frame can never be saved as the app's.
        private static let frameKey = "MainWindowFrame"

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            window.setFrameAutosaveName("")
            interceptClose(window)
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: window)
            center.addObserver(self, selector: #selector(frameChanged), name: NSWindow.didEndLiveResizeNotification, object: window)
            center.addObserver(self, selector: #selector(frameChanged), name: NSWindow.didMoveNotification, object: window)
            // Before the window first shows: a launch into setup opens compact, with no app-sized frame first.
            applied = nil
            apply()
        }

        @objc private func windowClosed() {
            saveAppFrame()
            close()
        }

        @objc private func frameChanged() { saveAppFrame() }

        func request(_ layout: WindowLayout) {
            wanted = layout
            if let window { interceptClose(window) }
            apply()
        }

        private var interceptor: CloseInterceptor?

        /// Puts `CloseInterceptor` in front of the window's delegate, which SwiftUI owns, once,
        /// and again should SwiftUI replace its delegate.
        private func interceptClose(_ window: NSWindow) {
            guard !(window.delegate is CloseInterceptor) else { return }
            let interceptor = CloseInterceptor(original: window.delegate) { [weak self] in self?.shouldClose() ?? true }
            self.interceptor = interceptor
            window.delegate = interceptor
        }

        private func apply() {
            guard let window, applied != wanted else { return }
            saveAppFrame()
            let first = applied == nil
            applied = wanted
            let layout = wanted
            switch layout {
            case .compact:
                move(window, to: compactFrame(window), animated: !first)
            case .app:
                if first {
                    // A window opened on the app keeps the frame it was given, or the one saved.
                    if let saved = savedAppFrame() { window.setFrame(saved, display: true) }
                    saveAppFrame()
                    DispatchQueue.main.async { self.settled(layout) }
                } else {
                    move(window, to: savedAppFrame() ?? defaultAppFrame(window), animated: true)
                }
            }
        }

        private func move(_ window: NSWindow, to frame: NSRect, animated: Bool) {
            let layout = wanted
            guard animated, animates else {
                window.setFrame(frame, display: true)
                DispatchQueue.main.async { self.settled(layout) }
                return
            }
            resizing = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.windowDuration
                context.timingFunction = Motion.windowCurve
                context.allowsImplicitAnimation = true
                window.animator().setFrame(frame, display: true)
            } completionHandler: {
                MainActor.assumeIsolated {
                    self.resizing = false
                    self.settled(layout)
                }
            }
        }

        private func saveAppFrame() {
            guard let window, applied == .app, !resizing, window.isVisible else { return }
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
        }

        /// The saved frame, if it still lands on a screen and fits the app.
        private func savedAppFrame() -> NSRect? {
            guard let text = UserDefaults.standard.string(forKey: Self.frameKey) else { return nil }
            let frame = NSRectFromString(text)
            guard frame.width >= MainWindow.appMinimum.width, frame.height >= MainWindow.appMinimum.height,
                  NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
            return frame
        }

        private func compactFrame(_ window: NSWindow) -> NSRect {
            centred(window, size: MainWindow.setupSize)
        }

        private func defaultAppFrame(_ window: NSWindow) -> NSRect {
            centred(window, size: CGSize(width: 980, height: 680))
        }

        /// A frame of `size`, centred on the window's screen. The content runs under the hidden
        /// title bar, so the frame and the content are the same size.
        private func centred(_ window: NSWindow, size: CGSize) -> NSRect {
            let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            return NSRect(x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2).rounded(),
                          width: size.width, height: size.height)
        }
    }
}

/// Answers `windowShouldClose` first and hands every other delegate message to the delegate it
/// replaced (SwiftUI's), untouched: `responds(to:)` and `forwardingTarget(for:)` pass them on.
final class CloseInterceptor: NSObject, NSWindowDelegate {
    /// Held strongly: the window only holds its delegate weakly.
    private let original: (any NSWindowDelegate)?
    private let allow: () -> Bool

    init(original: (any NSWindowDelegate)?, allow: @escaping () -> Bool) {
        self.original = original
        self.allow = allow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard allow() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
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
        // On macOS 26 a scroll view below stretches up under the header; drawn above it, the
        // header gets its own view and keeps its clicks.
        .zIndex(1)
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
/// While one runs it opens the live page.
private struct RecordButton: View {
    let capture: CaptureController
    let openLive: () -> Void
    @State private var hovering = false

    var body: some View {
        let idle = capture.state == .idle
        Button {
            if capture.state.isCapturing { openLive() } else { Task { await capture.startNow(title: String(localized: "Recording")) } }
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
        .disabled(!idle && !capture.state.isCapturing)
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
    }
}

/// After an update to the voiceprint model: fetching it, then rebuilding voices meeting by meeting.
private struct VoiceprintUpdateStatus: View {
    let update: VoiceprintUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch update {
            case .fetchingModel:
                Text("Downloading voiceprint model").font(Typo.caption).foregroundStyle(Palette.secondary)
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            case .rebuilding(let done, let total):
                Text("Updating voiceprints \(done)/\(total)").font(Typo.caption).foregroundStyle(Palette.secondary)
                    .monospacedDigit()
                ProgressLine(fraction: total == 0 ? 0 : Double(done) / Double(total))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
