import MM2TApp
import MM2TProviders
import MM2TSystem
import SwiftUI

/// First-run setup (stories 12, 13, 56-58), also opened whenever a meeting waits on setup: five
/// screens, one thing each. Order, gating and re-entry live in `OnboardingFlow`.
struct OnboardingView: View {
    let app: AppController
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// False until the flow has reopened at its first incomplete screen, so opening never travels.
    @State private var ready = false
    /// The screen being left. It stays drawn, as the same view, while it fades out and the next arrives.
    @State private var outgoing: Outgoing?

    private struct Outgoing: Equatable {
        let step: OnboardingStep
        let forward: Bool
        var gone = false
    }

    /// The indicator's top, the title's distance below it, and the buttons' distance from the bottom.
    private static let indicatorTop: CGFloat = 28
    private static let titleGap: CGFloat = 36
    private static let footerBottom: CGFloat = 28

    var body: some View {
        let flow = app.onboarding
        ZStack(alignment: .top) {
            if ready {
                ForEach(pages, id: \.self) { step in
                    let leaving = outgoing?.step == step ? outgoing : nil
                    StepPage(app: app, step: step, forward: leaving?.forward ?? flow.forward)
                        .opacity(leaving?.gone == true ? 0 : 1)
                        .offset(x: reduce || leaving?.gone != true ? 0 : leaving?.forward == true ? -16 : 16)
                        .allowsHitTesting(leaving == nil)
                        .accessibilityHidden(leaving != nil)
                }
            }
        }
        .padding(.top, Self.indicatorTop + 6 + Self.titleGap)
        .padding(.bottom, Self.footerBottom + 30 + 24)
        .frame(width: 600, height: 580)
        .overlay(alignment: .top) {
            StepIndicator(current: flow.step).padding(.top, Self.indicatorTop)
        }
        .overlay(alignment: .bottom) { footer(flow) }
        .foregroundStyle(Palette.text)
        .font(Typo.body)
        // The window takes its size from this view; it stays this size on every screen.
        .frame(width: 600, height: 580)
        .background(Palette.window)
        .dropdownLayer()
        .onAppear { app.setup.refresh() }
        // The last screen's fields write settings; what is still missing follows them.
        .onChange(of: app.settings.settings) { app.setup.recheck() }
        .task {
            await app.enrollment.refresh()
            flow.reopen()
            ready = true
            if flow.step >= .models { startDownloads() }
        }
    }

    /// The screen on its way out, if any, under the current one.
    private var pages: [OnboardingStep] {
        let current = app.onboarding.step
        guard let leaving = outgoing?.step, leaving != current else { return [current] }
        return [leaving, current]
    }

    // MARK: Footer

    private func footer(_ flow: OnboardingFlow) -> some View {
        let primaryKind: PillButton.Kind = flow.step == .voice && !flow.canContinue ? .ghost : .primary
        return HStack(spacing: 10) {
            if flow.canGoBack {
                PillButton("Back", minWidth: 112) { travel(flow.back) }
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
            Group {
                switch flow.primary {
                case .continue: PillButton("Continue", kind: primaryKind, minWidth: 112, action: primary)
                case .start: PillButton("Start Using mm2t", kind: primaryKind, minWidth: 112, action: primary)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!flow.canContinue)
            .motion(Motion.touch, value: flow.canContinue)
            .motion(Motion.touch, value: primaryKind == .primary)
        }
        .motion(Motion.select, value: flow.canGoBack)
        .motion(Motion.select, value: flow.primary)
        .padding(.bottom, Self.footerBottom)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            // Under the buttons, inside the bottom margin.
            Group {
                switch flow.note {
                case .chooseSpeechModel:
                    Text("Choose a transcription model to continue.")
                case .needsMicrophone:
                    Text("Allow microphone access to continue.")
                case .finishingDownloads(let fraction):
                    Text("Finishing model downloads… \(Int(fraction * 100))%").monospacedDigit()
                case .downloadFailed:
                    Text("A model couldn't download. Go back to retry it.")
                case .modelsNotDownloaded:
                    Text("Starting model downloads…")
                case .issue(.missingSelfHostedURL):
                    Text("Enter your transcription server's URL.")
                case .issue(.missingLLMEndpoint):
                    Text("Enter the language model server's URL and model name.")
                case .issue(let issue):
                    Text(Copy.issue(issue))
                case .needsVoice, nil:
                    EmptyView()
                }
            }
            .font(Typo.caption)
            .foregroundStyle(Palette.secondary)
            .lineLimit(1)
            .padding(.bottom, 8)
            .transition(.opacity)
        }
        .motion(Motion.reveal, value: flow.note == nil)
    }

    private func primary() {
        let flow = app.onboarding
        guard flow.canContinue else { return }
        switch flow.primary {
        case .continue: travel { flow.advance() }
        case .start: finish()
        }
    }

    /// The main window then grows from setup into the app.
    private func finish() {
        app.completeOnboarding()
        Task { await app.queue.retryAfterSetup() }
    }

    // MARK: Travel

    /// Moves the flow and sends the screen it left out: first marked as leaving at full opacity in
    /// the same update the new screen arrives in, then faded and moved in the next one.
    private func travel(_ move: () -> Void) {
        let flow = app.onboarding
        let old = flow.step
        move()
        guard flow.step != old else { return }
        let leaving = Outgoing(step: old, forward: flow.forward)
        outgoing = leaving
        DispatchQueue.main.async {
            guard outgoing == leaving else { return }
            withAnimation(.easeOut(duration: reduce ? 0.12 : 0.14)) {
                outgoing?.gone = true
            } completion: {
                if outgoing?.step == old { outgoing = nil }
            }
        }
        if flow.step >= .models { startDownloads() }
    }

    /// Runs past this view: the downloads carry on while the user moves through the other screens.
    private func startDownloads() {
        let flow = app.onboarding
        Task { await flow.startDownloads() }
    }
}

// MARK: Step indicator

/// Five marks, top centre. The current one is an orange capsule that travels between marks.
private struct StepIndicator: View {
    let current: OnboardingStep
    @Namespace private var space
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step < current ? Palette.orange.opacity(0.45) : Palette.muted.opacity(0.5))
                    .frame(width: step == current ? 18 : 6, height: 6)
                    .matchedGeometryEffect(id: step, in: space, isSource: true)
            }
        }
        .overlay {
            Capsule()
                .fill(Palette.orange)
                .matchedGeometryEffect(id: current, in: space, isSource: false)
        }
        // Under Reduce Motion the capsule jumps.
        .animation(reduce ? nil : Motion.select, value: current)
        .accessibilityElement()
        .accessibilityLabel("Setup progress")
        .accessibilityValue(Text("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count)"))
    }
}

// MARK: Arrival

/// Whether a screen's parts have arrived, and from which side they come.
struct Arrival: Equatable {
    var shown: Bool
    var forward: Bool
}

private struct ArrivalKey: EnvironmentKey {
    static let defaultValue = Arrival(shown: true, forward: true)
}

extension EnvironmentValues {
    var arrival: Arrival {
        get { self[ArrivalKey.self] }
        set { self[ArrivalKey.self] = newValue }
    }
}

/// One part of a screen arriving: from 24 pt toward the side of travel, at opacity 0, 40 ms after
/// the part before it. Reduce Motion makes it a plain fade, all parts together.
private struct Arrives: ViewModifier {
    let order: Int
    @Environment(\.arrival) private var arrival
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .opacity(arrival.shown ? 1 : 0)
            .offset(x: arrival.shown || reduce ? 0 : arrival.forward ? 24 : -24)
            .animation(reduce ? .easeOut(duration: 0.12) : Motion.page.delay(min(Double(order) * 0.04, 0.24)),
                       value: arrival.shown)
    }
}

extension View {
    /// `order` 0 is the title, 1 the sub, then each row.
    fileprivate func arrives(_ order: Int) -> some View { modifier(Arrives(order: order)) }

    /// A row of a setup screen: a card-toned rounded rectangle, no border.
    fileprivate func setupRow() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

// MARK: Screens

/// One screen: title, sub and rows, which arrive staggered when it first appears.
private struct StepPage: View {
    let app: AppController
    let step: OnboardingStep
    /// The direction of travel this screen arrived with.
    let forward: Bool
    @State private var shown = false

    /// Room for a row's 24 pt travel without the scroll view clipping it.
    private static let travel: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .usage: Text("How do you want to use mm2t?")
                case .permissions: Text("Let mm2t hear your meetings.")
                case .models: Text("Download the models this Mac needs.")
                case .voice: Text("Teach mm2t your voice.")
                case .services:
                    if app.onboarding.choice == .ownServer { Text("Connect your server") } else { Text("Connect your services.") }
                }
            }
            .font(Typo.title)
            .lineLimit(1)
            .arrives(0)
            .frame(width: 440)

            if step == .models || step == .voice {
                Group {
                    switch step {
                    case .models:
                        if showsSpeechPicker {
                            Text("Selecting a speech model downloads it to this Mac.")
                        } else {
                            Text("About \(Self.megabytes(app.onboarding.modelBytes)) MB in total.")
                        }
                    default: Text("Read this aloud at your normal speaking voice.")
                    }
                }
                .font(Typo.body)
                .foregroundStyle(Palette.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .arrives(1)
                .frame(width: 440)
            }

            FadingScrollView(ground: Palette.window) {
                VStack(alignment: .leading, spacing: 8) { rows }
                    .frame(width: 440)
                    .padding(.horizontal, Self.travel)
                    .padding(.bottom, 4)
            }
            .padding(.top, 24)
        }
        .multilineTextAlignment(.center)
        .frame(width: 440 + 2 * Self.travel)
        .environment(\.arrival, Arrival(shown: shown, forward: forward))
        .onAppear { shown = true }
    }

    private var showsSpeechPicker: Bool {
        !app.settings.settings.hasCompletedOnboarding || app.settings.settings.transcriptionOrder.contains(.local)
    }

    @ViewBuilder private var rows: some View {
        Group {
            switch step {
            case .usage: UsageRows(flow: app.onboarding)
            case .permissions: PermissionRows(setup: app.setup, asSetupRows: true)
            case .models:
                if showsSpeechPicker {
                    VStack(alignment: .leading, spacing: 10) {
                        SpeechModelPicker(store: app.settings, setup: app.setup)
                    }
                    .setupRow()
                }
                TranslationEnableRow(app: app).setupRow()
                CaptionTranslationRow(app: app).setupRow()
                ModelRows(setup: app.setup)
            case .voice: VoiceEnrollmentView(model: app.enrollment, models: app.setup.models)
            case .services: ServiceRows(app: app)
            }
        }
        .multilineTextAlignment(.leading)
    }

    /// Decimal megabytes, as Finder counts them.
    static func megabytes(_ bytes: Int64) -> Int {
        Int((Double(bytes) / 1_000_000).rounded())
    }
}

// MARK: 1. Usage

private struct UsageRows: View {
    let flow: OnboardingFlow

    var body: some View {
        ChoiceRow(choice: .signIn, selected: false, title: UsageChoice.signIn.title,
                  detail: "Free, 250 minutes a month", flow: flow)
            .arrives(2)
        ChoiceRow(choice: .ownKeys, selected: flow.choice == .ownKeys, title: "Use your own API keys",
                  detail: "ElevenLabs and Gemini, billed to your accounts.", flow: flow)
            .arrives(3)
        ChoiceRow(choice: .ownServer, selected: flow.choice == .ownServer, title: UsageChoice.ownServer.title,
                  detail: "This Mac or your own server", flow: flow)
            .arrives(4)
    }
}

private struct ChoiceRow: View {
    let choice: UsageChoice
    let selected: Bool
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let flow: OnboardingFlow
    @State private var hovering = false

    var body: some View {
        Button { flow.select(choice) } label: {
            HStack(spacing: 12) {
                Icon(choice.icon, size: 20).foregroundStyle(selected ? Palette.orange : Palette.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(Typo.bodyStrong).lineLimit(1)
                        if !choice.isAvailable {
                            ComingSoonBadge()
                        }
                    }
                    Text(detail).font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Icon("check", size: 16)
                    .foregroundStyle(Palette.orange)
                    .opacity(selected ? 1 : 0)
            }
            .setupRow()
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(hovering && choice.isAvailable ? Palette.hover : .clear)
            }
            .overlay {
                // The selection ring: a state of this control, drawn inside its shape.
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.orange, lineWidth: selected ? 1.5 : 0)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(Pressable())
        .focusEffectDisabled()
        .disabled(!choice.isAvailable)
        .opacity(choice.isAvailable ? 1 : 0.5)
        .onHover { hovering = $0 && choice.isAvailable }
        .motion(Motion.touch, value: hovering)
        .motion(Motion.touch, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: 3. Models

private struct ModelRows: View {
    let setup: SetupModel

    var body: some View {
        ModelRow(name: "Speakers and voiceprints",
                 state: setup.models, failure: nil) {
            Task { await setup.downloadModels() }
        }
        .arrives(2)
    }
}

/// A model's name and download: a progress line and a percentage that becomes a check.
private struct ModelRow: View {
    let name: LocalizedStringKey
    let state: ModelDownloadState
    /// What a failure says; nil shows the download's own error.
    let failure: LocalizedStringKey?
    /// A second caption line: size, or why this Mac is not suited.
    var detail: Text?
    /// Whether the row starts its own download; otherwise it starts on its own and shows 0%.
    var offersDownload = false
    /// Starts the download, and again after a failure.
    let retry: () -> Void
    /// Turns the source that needs this model off, while the model is not on disk.
    var turnOff: (() -> Void)?

    private var failed: String? {
        if case .failed(let reason) = state { reason } else { nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Typo.bodyStrong).lineLimit(1)
                    if let detail {
                        detail.font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            ProgressLine(fraction: OnboardingFlow.fraction(state), animation: .linear(duration: 0.2))
            if let failed {
                Group {
                    if let failure { Text(failure) } else { Text(verbatim: failed) }
                }
                .font(Typo.caption)
                .foregroundStyle(Palette.danger)
                .lineLimit(3)
                .transition(.opacity)
            }
        }
        .setupRow()
        .motion(Motion.reveal, value: state == .downloaded)
        .motion(Motion.reveal, value: failed)
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .downloaded:
            Icon("circle-check", size: 18).foregroundStyle(Palette.success)
                .transition(.scale.combined(with: .opacity))
                .accessibilityElement()
                .accessibilityLabel("Downloaded")
        case .failed:
            HStack(spacing: 12) {
                turnOffButton
                PillButton("Retry", icon: "refresh", action: retry)
            }
            .transition(.opacity)
        case .notDownloaded where offersDownload:
            HStack(spacing: 12) {
                turnOffButton
                PillButton("Download", icon: "download", action: retry)
            }
            .transition(.opacity)
        case .downloading, .notDownloaded:
            Text(OnboardingFlow.fraction(state), format: .percent.precision(.fractionLength(0)))
                .font(Typo.caption)
                .foregroundStyle(Palette.secondary)
                .monospacedDigit()
                .transition(.opacity)
        }
    }

    /// Quieter than the pill beside it: plain secondary text.
    @ViewBuilder private var turnOffButton: some View {
        if let turnOff {
            Button(action: turnOff) {
                Text("Turn Off").font(Typo.captionStrong).foregroundStyle(Palette.secondary)
                    .frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(Pressable())
            .focusEffectDisabled()
        }
    }
}

// MARK: 4. Voice

/// The passage the user reads once so mm2t knows their voice, and how the reading went.
struct VoiceEnrollmentView: View {
    let model: VoiceEnrollmentModel
    /// The speaker model turns the reading into a voiceprint, so it has to be on disk first.
    let models: ModelDownloadState

    static let passage = String(localized: "Today I am setting up my meeting notes. Whenever we meet in the same room, this is how the app will know which voice is mine.")

    var body: some View {
        Text(verbatim: Self.passage)
            .font(Typo.heading)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .setupRow()
            .arrives(2)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                switch model.state {
                case .recording:
                    PillButton("Done Reading", icon: "player-stop", kind: .primary) {
                        Task { await model.finish(passage: Self.passage, name: Copy.presentationLabels.me) }
                    }
                    Spacer(minLength: 0)
                    MiniMeter(level: model.level, color: Palette.orange, restColor: Palette.muted,
                              shape: MiniMeter.wideShape, barWidth: 5, spacing: 4, height: 28)
                    Spacer(minLength: 0)
                case .checking:
                    Text("Checking…").foregroundStyle(Palette.secondary)
                case .enrolled:
                    Icon("circle-check", size: 18).foregroundStyle(Palette.success)
                    Text("mm2t knows your voice").lineLimit(1)
                    Spacer()
                    PillButton("Read Again", icon: "refresh") {
                        model.retry()
                        Task { await model.start() }
                    }
                case .idle, .rejected:
                    // The step's main act, so it stays the orange one; the footer waits in grey.
                    PillButton("Start Reading", icon: "microphone", kind: .primary) {
                        model.retry()
                        Task { await model.start() }
                    }
                    .disabled(models != .downloaded)
                    switch models {
                    case .downloaded:
                        EmptyView()
                    case .downloading(let fraction):
                        Text("Waiting for the speaker model… \(Int(fraction * 100))%")
                            .font(Typo.caption).foregroundStyle(Palette.secondary).monospacedDigit().lineLimit(1)
                    case .notDownloaded, .failed:
                        Text("Download the speaker separation model first.")
                            .font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(2)
                    }
                }
            }
            .frame(minHeight: 30)
            if case .rejected(let problem) = model.state {
                HStack(spacing: 8) {
                    Icon("alert-triangle", size: 15).foregroundStyle(Palette.orange)
                    Text(Copy.enrollment(problem)).fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        }
        .setupRow()
        .motion(Motion.reveal, value: model.state)
        .arrives(3)
    }
}

// MARK: 5. Services

private struct ServiceRows: View {
    let app: AppController

    var body: some View {
        let flow = app.onboarding
        let setup = app.setup
        let services = flow.services
        ForEach(Array(services.enumerated()), id: \.element) { index, entry in
            Group {
                switch entry {
                case .elevenLabs:
                    ServiceRow(title: Text(verbatim: "ElevenLabs")) {
                        CredentialFieldView(field: setup.field(.elevenLabsAPIKey), setup: setup)
                    }
                case .gemini:
                    ServiceRow(title: Text(verbatim: "Gemini")) {
                        CredentialFieldView(field: setup.field(.geminiAPIKey), setup: setup)
                    }
                case .transcriptionServer:
                    ServiceRow(title: Text("Transcription server")) {
                        ServerURLField(store: app.settings)
                        CredentialFieldView(field: setup.field(.selfHostedToken), setup: setup)
                    }
                case .llmServer:
                    ServiceRow(title: Text("Language model server")) {
                        LLMServerFields(store: app.settings, key: setup.field(.openAICompatibleAPIKey))
                        CredentialFieldView(field: setup.field(.openAICompatibleAPIKey), setup: setup)
                    }
                case .offlineModel(.llm):
                    OfflineModelRow(model: .llm, setup: setup, flow: flow)
                case .offlineModel, .speechModelPicker:
                    ServiceRow(title: Text("On-device transcription")) {
                        SpeechModelPicker(store: app.settings, setup: setup)
                        PillButton("Turn Off") { flow.turnOff(.transcription) }
                    }
                case .transcriptionSource:
                    ServiceRow(title: Text("Transcription"), purpose: Text(Copy.issue(.noTranscriptionSource))) {
                        Group {
                            if flow.choice == .ownServer {
                                PillButton("Use Your Server", action: flow.turnOnTranscriptionSource)
                            } else {
                                PillButton("Use ElevenLabs", action: flow.turnOnTranscriptionSource)
                            }
                        }
                    }
                case .settings(let issue):
                    // Never needed for processing today; kept so no issue is ever left without a way out.
                    ServiceRow(title: Text("Settings"), purpose: Text(Copy.issue(issue))) {
                        PillButton("Open Settings") {
                            MainNavigation.shared.settingsOpen = true
                            WindowOpener.open(WindowID.main)
                        }
                    }
                }
            }
            .arrives(2 + index)
        }
        if let account = app.collabAccount {
            ServiceRow(title: Text("Sign in to share meetings")) {
                if let user = account.user {
                    HStack(spacing: 8) {
                        AccountAvatar(name: user.name, size: 28)
                        Text(verbatim: user.name).font(Typo.bodyStrong).lineLimit(1)
                        Icon("check", size: 16).foregroundStyle(Palette.orange)
                    }
                } else {
                    AccountSignInButtons(account: account)
                }
                AccountErrorLine(account: account)
            }
            .arrives(2 + services.count)
        }
    }
}

/// An on-device model a chosen source needs: download it here, or turn that source off the way
/// its Settings switch does.
private struct OfflineModelRow: View {
    let model: OfflineModel
    let setup: SetupModel
    let flow: OnboardingFlow

    var body: some View {
        ModelRow(name: "On-device language model",
                 state: setup.offlineModels[model] ?? .notDownloaded, failure: nil, detail: detail,
                 offersDownload: true,
                 retry: { Task { await setup.downloadOfflineModel(model) } },
                 turnOff: { flow.turnOff(model) })
    }

    /// The size, or why this Mac is not suited, in the words Settings uses.
    private var detail: Text {
        if case .unsuited(let reason) = setup.fit(for: model) {
            switch reason {
            case .intelProcessor: return Text("Not recommended on a Mac with an Intel processor.")
            case .memory(let minimumGB): return Text("Not recommended: needs at least \(minimumGB) GB of memory.")
            }
        }
        let size = ByteCountFormatter.string(fromByteCount: setup.offlineModelBytes(model), countStyle: .file)
        return Text("Needs a model on this Mac (\(size)).")
    }
}

private struct ServiceRow<Fields: View>: View {
    let title: Text
    var purpose: Text?
    @ViewBuilder let fields: Fields

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                title.font(Typo.bodyStrong).lineLimit(1)
                purpose?.font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(2)
            }
            fields
        }
        .setupRow()
    }
}

// MARK: 2. Permissions

/// The permission list, shared by first-run setup and the settings page. macOS sends no
/// notification when a switch is flipped in System Settings, so it re-reads them while on screen.
/// In setup each permission is a row of its own and its request button gives way to the footer's.
struct PermissionRows: View {
    let setup: SetupModel
    var asSetupRows = false

    var body: some View {
        let request: PillButton.Kind = asSetupRows ? .ghost : .primary
        Group {
        PermissionRow(title: "Microphone",
                      state: setup.microphone, pane: .microphone, requestKind: request) {
            Task { await setup.requestMicrophone() }
        }
        .asSetupRow(2, asSetupRows)
        PermissionRow(title: "System audio recording",
                      state: setup.systemAudio, pane: .systemAudio, requestKind: request, request: nil)
        .asSetupRow(3, asSetupRows)
        PermissionRow(title: "Accessibility",
                      state: setup.accessibility, pane: .accessibility, requestKind: request) {
            setup.requestAccessibility()
        }
        .asSetupRow(4, asSetupRows)
        if setup.accessibility == .denied {
            // macOS ties the switch to the build that was added. A build signed differently shows
            // the old switch as on while the running app is still refused.
            Text("Already switched on? The switch may belong to an older build of mm2t. Select mm2t in the list, remove it with the − button, then add it again.")
                .font(Typo.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                .asSetupCaption(5, asSetupRows)
        }
        ForEach(Array(setup.automation.keys.sorted().enumerated()), id: \.element) { index, browser in
            PermissionRow(title: "Automation: \(browser)",
                          state: setup.automation[browser] ?? .unknown, pane: .automation, requestKind: request) {
                Task { await setup.requestAutomation(of: browser) }
            }
            .asSetupRow(6 + index, asSetupRows)
        }
        if setup.automation.isEmpty {
            Text("Open your browser to grant it.")
                .font(Typo.caption).foregroundStyle(Palette.secondary)
                .asSetupCaption(6, asSetupRows)
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

extension View {
    @ViewBuilder fileprivate func asSetupRow(_ order: Int, _ on: Bool) -> some View {
        if on { setupRow().arrives(order) } else { self }
    }

    @ViewBuilder fileprivate func asSetupCaption(_ order: Int, _ on: Bool) -> some View {
        if on { padding(.horizontal, 14).arrives(order) } else { self }
    }
}

struct PermissionRow: View {
    let title: LocalizedStringKey
    let state: PermissionState
    let pane: SettingsPane
    var requestKind = PillButton.Kind.primary
    let request: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(Typo.bodyStrong)
            Spacer(minLength: 8)
            if state == .granted {
                Icon("circle-check", size: 18).foregroundStyle(Palette.success)
                    .transition(.scale.combined(with: .opacity))
            } else if state == .notDetermined, let request {
                PillButton("Allow…", kind: requestKind, action: request)
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
