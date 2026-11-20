import MM2TApp
import MM2TCore
import MM2TProviders
import SwiftUI

struct CollabCapsuleRows: View {
    let session: CollabSession
    @State private var command = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            commandRow
            if let suggestion = session.suggestion, let card = session.card {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Icon(suggestion.kind.icon, size: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: suggestion.title).font(Typo.captionStrong).lineLimit(1)
                            Text(verbatim: suggestion.instruction).font(Typo.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        CapsulePill("Build", filled: true) { session.accept(suggestion: suggestion) }
                        CircleButton("Dismiss", icon: "x", action: session.dismissSuggestion)
                    }
                    TimelineView(.animation) { context in
                        GeometryReader { geometry in
                            Rectangle().fill(.white.opacity(0.35))
                                .frame(width: geometry.size.width * card.progress(at: context.date))
                        }.frame(height: 2)
                    }
                    .accessibilityHidden(true)
                }
                .frame(width: 420)
                .onHover(perform: session.hoverSuggestion)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .motion(Motion.reveal, value: session.commandStatus)
        .motion(Motion.reveal, value: session.suggestion != nil)
        .motion(Motion.reveal, value: session.state)
    }

    @ViewBuilder private var commandRow: some View {
        switch session.state {
        case .confirmingStart:
            HStack(spacing: 10) {
                Text("Start sharing for this meeting?")
                CapsulePill("Start", filled: true, action: session.startSharing).keyboardShortcut(.defaultAction)
                CircleButton("Cancel", icon: "x", action: session.dismissCommand).keyboardShortcut(.cancelAction)
            }
        case .needsSignIn:
            HStack(spacing: 10) {
                Text("Sign in to share")
                CapsulePill("Sign In") {
                    MainNavigation.shared.settingsSection = .collaboration
                    MainNavigation.shared.open(.settings)
                }
                CircleButton("Cancel", icon: "x", action: session.dismissCommand)
            }
        default:
            switch session.commandStatus {
            case .hidden: EmptyView()
            case .input:
                HStack(spacing: 9) {
                    Icon("sparkles", size: 15).foregroundStyle(.white.opacity(0.65))
                    TextField("Ask to build or change something…", text: $command)
                        .textFieldStyle(.plain)
                        .font(Typo.body)
                        .foregroundStyle(.white)
                        .focused($focused)
                        .onAppear { focused = true }
                        .onSubmit {
                            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            session.run(command: command)
                            command = ""
                        }
                        .onExitCommand(perform: session.dismissCommand)
                }
                .padding(.horizontal, 12)
                .frame(width: 420, height: 36)
                .background(.white.opacity(0.12), in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .top)))
            case .building(let title):
                HStack(spacing: 8) {
                    Spinner()
                    if let title { Text(verbatim: title).lineLimit(1) } else { Text("Building…") }
                }.frame(width: 420, height: 36)
            case .completed(let title):
                HStack(spacing: 8) {
                    Icon("circle-check", size: 16).foregroundStyle(Palette.success)
                    if let title { Text(verbatim: title).lineLimit(1) } else { Text("Done") }
                }.frame(width: 420, height: 36)
            case .failed(let error):
                HStack(spacing: 8) {
                    Icon("alert-triangle", size: 16).foregroundStyle(Palette.danger)
                    Text(verbatim: error.message).lineLimit(1)
                    Spacer(minLength: 0)
                    CapsulePill("Retry", action: session.retry)
                    CircleButton("Close", icon: "x", action: session.dismissCommand)
                }.frame(width: 420, height: 36)
            }
        }
    }
}

struct CollabCopyLink: View {
    let url: URL
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        CircleButton("Copy Link", icon: copied ? "check" : "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            copied = true
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { copied = false }
            }
        }
        .onDisappear { reset?.cancel() }
    }
}

struct CollabAccountSettings: View {
    let account: CollabAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let user = account.user {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: user.name)
                        Text(verbatim: user.email).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    PillButton("Sign Out") { Task { await account.signOut() } }
                } else {
                    PillButton("Sign in with Google") { Task { await account.signIn(.google) } }
                    PillButton("Sign in with Apple") { Task { await account.signIn(.apple) } }
                    Spacer()
                }
            }
            .disabled(account.busy)
            if let error = account.error {
                Text(verbatim: error.collabMessage).font(Typo.caption).foregroundStyle(Palette.danger)
            }
        }
    }
}

private extension CollabComponentKind {
    var icon: String {
        switch self {
        case .whiteboard: "chalkboard"
        case .poll: "chart-bar"
        case .gantt: "timeline"
        case .actions: "checklist"
        case .document: "file-text"
        case .experimental: "flask"
        }
    }
}

private extension CollabSession.Failure {
    var message: String {
        switch self {
        case .service(let error): error.collabMessage
        case .modelNotConfigured: String(localized: "Set up a language model in Settings.")
        case .generation: String(localized: "Couldn’t finish building the component.")
        }
    }
}

private extension CollabError {
    var collabMessage: String {
        switch self {
        case .notSignedIn: String(localized: "Sign in to share")
        case .quotaExceeded(let used, let limit): String(localized: "Room limit reached (\(used)/\(limit)).")
        case .roomEnded: String(localized: "This room has ended.")
        case .credentialCleanup: String(localized: "Couldn’t remove the saved collaboration sign-in.")
        case .unreachable: String(localized: "Can’t connect to the collaboration service.")
        case .invalidBatch, .server: String(localized: "The collaboration service couldn’t complete the request.")
        }
    }
}
