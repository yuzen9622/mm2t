import MM2TApp
import MM2TSystem
import SwiftUI

/// First-run setup (stories 12, 13, 56-58), also opened whenever a meeting waits on setup.
struct OnboardingView: View {
    let app: AppController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let setup = app.setup
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Panel(title: "Permissions") {
                        PermissionRows(setup: setup)
                    }
                    Panel(title: "Speaker separation") {
                        ModelDownloadView(setup: setup)
                    }
                    Panel(title: "Your voice") {
                        VoiceEnrollmentView(model: app.enrollment, modelReady: setup.models == .downloaded)
                    }
                    Panel(title: "API keys") {
                        CredentialFieldView(field: setup.field(.elevenLabsAPIKey), setup: setup)
                        CredentialFieldView(field: setup.field(.geminiAPIKey), setup: setup)
                    }
                    if !setup.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(setup.issues, id: \.self) { IssueRow(issue: $0) }
                        }
                        .padding(.leading, 4)
                    }
                }
                .padding(24)
                .motion(Motion.reveal, value: setup.issues)
            }
            HStack {
                Spacer()
                PillButton("Done", kind: .primary) {
                    app.completeOnboarding()
                    Task { await app.queue.retryAfterSetup() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!setup.issues.isEmpty || !app.enrollment.hasVoice)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Palette.window)
        }
        .foregroundStyle(Palette.text)
        .font(Typo.body)
        .background(Palette.window)
        // The window takes its size from this view. A scroll view offers no height of its own, so
        // without a fixed one the window resizes forever.
        .frame(width: 560, height: 640)
        .onAppear { setup.refresh() }
        .task { await app.enrollment.refresh() }
    }
}

/// The passage the user reads once so mm2t knows their voice, and how the reading went.
struct VoiceEnrollmentView: View {
    let model: VoiceEnrollmentModel
    /// The speaker model turns the reading into a voiceprint, so it has to be on disk first.
    let modelReady: Bool

    static let passage = String(localized: "Today I am setting up my meeting notes. Whenever we meet in the same room, this is how the app will know which voice is mine.")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read this aloud at your normal speaking voice. mm2t keeps a voiceprint of it on this Mac, so a meeting recorded in the room shows which speaker is you.")
                .font(Typo.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: Self.passage)
                .font(Typo.heading)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            HStack(spacing: 12) {
                switch model.state {
                case .recording:
                    PillButton("Done Reading", icon: "player-stop", kind: .primary) {
                        Task { await model.finish(passage: Self.passage, name: Copy.presentationLabels.me) }
                    }
                    ProgressLine(fraction: model.level).frame(maxWidth: 160)
                case .checking:
                    Text("Checking…").foregroundStyle(Palette.secondary)
                case .enrolled:
                    Icon("circle-check", size: 18).foregroundStyle(Palette.success)
                    Text("mm2t knows your voice")
                    Spacer()
                    PillButton("Read Again", icon: "refresh") {
                        model.retry()
                        Task { await model.start() }
                    }
                case .idle, .rejected:
                    PillButton("Start Reading", icon: "microphone", kind: .primary) {
                        model.retry()
                        Task { await model.start() }
                    }
                    .disabled(!modelReady)
                    if !modelReady {
                        Text("Download the speaker separation model first.").font(Typo.caption).foregroundStyle(Palette.secondary)
                    }
                }
            }
            if case .rejected(let problem) = model.state {
                HStack(spacing: 8) {
                    Icon("alert-triangle", size: 15).foregroundStyle(Palette.orange)
                    Text(Copy.enrollment(problem)).fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        }
        .motion(Motion.reveal, value: model.state)
    }
}

/// The permission list, shared by first-run setup and the settings page. macOS sends no
/// notification when a switch is flipped in System Settings, so it re-reads them while on screen.
struct PermissionRows: View {
    let setup: SetupModel

    var body: some View {
        Group {
        PermissionRow(title: "Microphone", purpose: "Records your side of the meeting.",
                      state: setup.microphone, pane: .microphone) {
            Task { await setup.requestMicrophone() }
        }
        PermissionRow(title: "System audio recording",
                      purpose: "Records only the meeting app's sound. macOS asks the first time you record.",
                      state: setup.systemAudio, pane: .systemAudio, request: nil)
        PermissionRow(title: "Accessibility", purpose: "Reads the meeting window's title to detect browser meetings.",
                      state: setup.accessibility, pane: .accessibility) {
            setup.requestAccessibility()
        }
        if setup.accessibility == .denied {
            // macOS ties the switch to the build that was added. A build signed differently shows
            // the old switch as on while the running app is still refused.
            Text("Already switched on? The switch may belong to an older build of mm2t. Select mm2t in the list, remove it with the − button, then add it again.")
                .font(Typo.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(setup.automation.keys.sorted(), id: \.self) { browser in
            PermissionRow(title: "Automation: \(browser)", purpose: "Reads the open tab's address to tell which meeting it is.",
                          state: setup.automation[browser] ?? .unknown, pane: .automation) {
                Task { await setup.requestAutomation(of: browser) }
            }
        }
        if setup.automation.isEmpty {
            Text("Open your browser to grant it. It lets mm2t read the open tab's address.")
                .font(Typo.caption).foregroundStyle(Palette.secondary)
        }
        }
        .task {
            while !Task.isCancelled {
                setup.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct PermissionRow: View {
    let title: LocalizedStringKey
    let purpose: LocalizedStringKey
    let state: PermissionState
    let pane: SettingsPane
    let request: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.bodyStrong)
                Text(purpose).font(Typo.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if state == .granted {
                Icon("circle-check", size: 18).foregroundStyle(Palette.success)
                    .transition(.scale.combined(with: .opacity))
            } else if state == .notDetermined, let request {
                PillButton("Allow…", kind: .primary, action: request)
            } else if state == .notDetermined {
                // macOS asks for this one itself, the first time it is used.
                Text(Copy.permissionState(state)).font(Typo.caption).foregroundStyle(Palette.secondary)
            } else {
                PillButton("Open System Settings") { SetupModel.openSettings(pane) }
            }
        }
        .motion(Motion.reveal, value: state)
    }
}
