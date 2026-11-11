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
                    Panel(title: "API keys") {
                        CredentialFieldView(field: setup.field(.elevenLabsAPIKey), setup: setup)
                        CredentialFieldView(field: setup.field(.geminiAPIKey), setup: setup)
                        Text("Use a Gemini key from a paid plan. On the free tier, Google may use what you send to improve its products.")
                            .font(Typo.caption).foregroundStyle(Palette.secondary)
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
                PillButton("Later") { dismiss() }
                PillButton("Done", kind: .primary) {
                    app.settings.settings.hasCompletedOnboarding = true
                    Task { await app.queue.retryAfterSetup() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!setup.issues.isEmpty)
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
                EmptyView()
            } else {
                PillButton("Open System Settings") { SetupModel.openSettings(pane) }
            }
        }
        .motion(Motion.reveal, value: state)
    }
}
