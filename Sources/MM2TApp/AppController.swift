import AppKit
import Foundation
import MM2TCore
import MM2TDiarization
import MM2TLocal
import MM2TProviders
import MM2TSystem
import MM2TWidgetData
import Observation
import OSLog

/// Where the app keeps its data. `MM2TDataRoot` in UserDefaults (or `-MM2TDataRoot <path>` on the
/// command line) moves everything, for development against a scratch library.
public struct AppPaths: Sendable {
    public let root: URL
    public var meetings: URL { root.appending(path: "Meetings") }
    public var recordings: URL { root.appending(path: "Recordings") }
    public var voiceprints: URL { root.appending(path: "voiceprints.json") }
    public var searchIndex: URL { root.appending(path: "search.sqlite") }
    public var assistantConversations: URL { root.appending(path: "Assistant/Conversations") }
    public var assistantPreferences: URL { root.appending(path: "Assistant/preferences.json") }
    /// Same place as `DiarizationModels.applicationSupport` for the default root.
    public var models: URL { root.appending(path: "Models") }

    public init(root: URL) { self.root = root }

    public static func standard(defaults: UserDefaults = .standard) -> AppPaths {
        if let override = defaults.string(forKey: "MM2TDataRoot"), !override.isEmpty {
            return AppPaths(root: URL(filePath: override))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: support.appending(path: "mm2t"))
    }
}

/// The composition root: owns the stores, the queue and the controllers, and wires the system
/// signal monitor into capture. The app target only adds views and windows.
@MainActor @Observable
public final class AppController {
    public let paths: AppPaths
    public let settings: SettingsStore
    public let library: MeetingLibrary
    public let searchIndex: MeetingIndex
    private let searchSync: SearchIndexSync
    public let voiceprints: VoiceprintStore
    public let queue: ProcessingQueue
    public let capture: CaptureController
    public let setup: SetupModel
    public let folders: MeetingFolders
    public let meetings: MeetingListModel
    public let people: VoiceprintsModel
    public let dashboard: DashboardModel
    public let todoStatus: TodoStatus
    public let assistantConversations: AssistantConversations
    public let assistantPreferences: AssistantPreferences
    public let reminders: RemindersSync
    public let enrollment: VoiceEnrollmentModel
    /// First-run setup's screens; reopened at its first incomplete screen each time the window opens.
    public let onboarding: OnboardingFlow
    /// Nil when this copy cannot share data with the desktop widget (an ad-hoc build has no team).
    public let widget: WidgetPublisher?

    /// The app is not usable until setup is finished and the user's voice is enrolled.
    public var needsOnboarding: Bool { !settings.settings.hasCompletedOnboarding || !enrollment.hasVoice }
    /// Whether the main window shows setup instead of the app: while setup is unfinished, or after
    /// the user opened it again. Until the voiceprints are read, a finished setup counts as still
    /// finished, so a launch never shows setup for a moment before the app.
    public var showsSetup: Bool {
        onboarding.isOpenedAgain || !settings.settings.hasCompletedOnboarding
            || (enrollment.hasCheckedVoice && !enrollment.hasVoice)
    }
    /// Recordings repaired at launch (or left unprocessed by a quit), offered for processing.
    public private(set) var recovered: [MeetingID] = []
    /// Set while an update to the voiceprint model fetches it and rebuilds stored voices.
    public private(set) var voiceprintUpdate: VoiceprintUpdate?
    public private(set) var recoveryFailures: [URL: String] = [:]

    @ObservationIgnored private let pipelineSetup: PipelineSetup
    @ObservationIgnored private let migrateVoiceprints: @Sendable (_ progress: @escaping @Sendable (Int, Int) async -> Void) async -> Void
    private nonisolated static let logger = Logger(subsystem: "dev.mm2t.app", category: "Voiceprints")
    @ObservationIgnored private var monitor: SystemSignalMonitor?
    @ObservationIgnored private var watchMeetings = false
    @ObservationIgnored private var hotkey: GlobalHotkeyMonitor?
    @ObservationIgnored private let recordingTitle: String
    /// Set while the shortcut field in Settings is listening, so pressing the current shortcut
    /// there to replace it does not also start or stop a recording.
    public var suspendsRecordShortcut: Bool {
        get { hotkey?.isSuspended ?? false }
        set { hotkey?.isSuspended = newValue }
    }

    public func makeAssistant() -> AssistantModel {
        AssistantModel(engine: AssistantEngine(library: library, index: searchIndex, voiceprints: voiceprints, folders: folders,
                                               todos: { [todoStatus] in await todoStatus.snapshot }),
                       conversations: assistantConversations, preferences: assistantPreferences,
                       build: { [pipelineSetup, settings] in try pipelineSetup.buildLLM(settings.settings) })
    }

    public init(
        paths: AppPaths,
        defaults: UserDefaults,
        credentials: any CredentialStoring,
        catalog: any ProviderCatalog,
        recorder: any Recorder,
        permissions: any PermissionsProviding,
        installer: any ModelInstalling,
        offlineInstallers: [OfflineModel: any ModelInstalling],
        translationInstaller: @escaping @MainActor (CaptionEngine, CaptionTarget) -> (any ModelInstalling)?,
        machine: MachineProfile = .current,
        validator: any KeyValidating,
        calendars: [any CalendarSource] = [],
        reminders: any ReminderStore = SystemReminders(),
        voiceRecorder: any VoiceSampleRecording = MicrophoneSampleRecorder(),
        runningBrowsers: @escaping @MainActor () -> [String] = { [] },
        widgetFile: URL? = nil,
        now: @escaping () -> Date = Date.init,
        endCountdown: Duration = CaptureController.endCountdown,
        recordingTitle: String = "Recording"
    ) throws {
        let folders = try MeetingFolders(file: paths.root.appending(path: "folders.json"))
        self.folders = folders
        self.paths = paths
        assistantConversations = AssistantConversations(directory: paths.assistantConversations)
        assistantPreferences = AssistantPreferences(file: paths.assistantPreferences)
        self.recordingTitle = recordingTitle
        let settings = SettingsStore(defaults: defaults, machine: machine, installedMLX: offlineInstallers[.transcription]?.isDownloaded)
        let library = MeetingLibrary(root: paths.meetings)
        let voiceprints = try VoiceprintStore(fileURL: paths.voiceprints)
        let pipelineSetup = PipelineSetup(library: library, voiceprints: voiceprints, credentials: credentials, catalog: catalog)
        migrateVoiceprints = { progress in
            guard let models = catalog.localSpeakerModels() else { return }
            let migration = VoiceprintMigration(library: library, voiceprints: voiceprints, embedder: models.embedder)
            guard (try? await migration.isNeeded()) == true else { return }
            let started = Date()
            do {
                let outcome = try await migration.run(progress: progress)
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                Self.logger.notice("event=voiceprint_migration meetings=\(outcome.meetings) unreadable=\(outcome.unreadable) dropped=\(outcome.dropped) userCalls=\(outcome.userCalls) seconds=\(seconds, privacy: .public)")
            } catch {
                Self.logger.error("event=voiceprint_migration_failed error=\(String(describing: error), privacy: .public)")
            }
        }
        let queue = ProcessingQueue(
            makePipeline: { try pipelineSetup.build(settings.settings) },
            makeLLM: { try pipelineSetup.buildLLM(settings.settings) })
        queue.onCompleted = { meeting in
            guard folders.claimRecording(meeting.id), !folders.folders.isEmpty, folders.revision(of: meeting.id) == nil else { return }
            Task {
                guard case .ready(let provider) = try? pipelineSetup.buildLLM(settings.settings) else { return }
                _ = try? await FolderOrganizer.run(folders, library: library, provider: provider, question: "", scope: [meeting.id], automatic: true)
            }
        }
        self.settings = settings
        self.library = library
        let searchIndex = MeetingIndex(fileURL: paths.searchIndex)
        self.searchIndex = searchIndex
        searchSync = SearchIndexSync(library: library, index: searchIndex, voiceprints: voiceprints)
        self.voiceprints = voiceprints
        self.pipelineSetup = pipelineSetup
        self.queue = queue
        capture = CaptureController(
            recorder: recorder, permissions: permissions, library: library, recordingsDirectory: paths.recordings,
            now: now, endCountdown: endCountdown,
            rules: { settings.settings.detectionRules },
            saveRules: { settings.settings.detectionRules = $0 },
            makeLive: { directory in
                let current = settings.settings
                let scratch = paths.recordings.appending(path: "live-\(UUID().uuidString)")
                let mic = directory.appending(path: RecordingManifest.micFile)
                let remote = directory.appending(path: RecordingManifest.remoteFile)
                if current.transcriptionOrder.first == .local, let choice = current.localSpeechModel, choice.isBreeze {
                    guard let breeze = catalog.localTranscription(model: choice, language: current.transcriptionLanguage) else { return nil }
                    let names = await voiceprints.spokenNames()
                    return LiveTranscriber(mic: mic, remote: remote, chain: TranscriptionChain([.init(.local, breeze)]),
                        hints: names + current.vocabulary.filter { !names.contains($0) }, scratch: scratch,
                        pieceSeconds: LiveTranscriber.breezePieceSeconds, configurationIsCurrent: {
                            let latest = settings.settings
                            return latest.transcriptionOrder == current.transcriptionOrder && latest.localSpeechModel == current.localSpeechModel
                                && latest.transcriptionLanguage == current.transcriptionLanguage && latest.vocabulary == current.vocabulary
                        })
                }
                guard case .ready(let configured)? = try? pipelineSetup.build(current), configured.diarizer != nil,
                      let chain = LiveTranscriber.recordingChain(configured.transcription) else { return nil }
                let pipeline: MeetingProcessingPipeline
                if current.llmLocation == .cloud, let gemini = configured.llm as? GeminiLLM {
                    pipeline = configured.withLLM(gemini.forRecording())
                } else if current.llmLocation == .cloud, let compatible = configured.llm as? OpenAICompatibleLLM {
                    pipeline = configured.withLLM(compatible.forRecording())
                } else { pipeline = configured }
                let speechCredentials: [Credential] = chain.routes.compactMap {
                    switch $0.source { case .cloud: .elevenLabsAPIKey; case .selfHosted: .selfHostedToken; case .local: nil }
                }
                let credentialKinds = speechCredentials + (current.llmLocation == .cloud
                    ? [current.cloudLLM == .gemini ? Credential.geminiAPIKey : .openAICompatibleAPIKey] : [])
                guard let initialCredentials = try? credentialKinds.map({ try credentials.read($0) }) else { return nil }
                let configurationIsCurrent: @MainActor @Sendable () -> Bool = {
                    settings.settings.forProcessing == current.forProcessing && (try? credentialKinds.map { try credentials.read($0) }) == initialCredentials
                }
                let processing: LiveRecordingProcessor?
                if current.llmLocation == .cloud, let factory = pipeline.diarizer as? any StreamingDiarizerFactory,
                   let session = try? await factory.makeStreamingSession() {
                    processing = LiveRecordingProcessor(pipeline: pipeline, session: session,
                        scratch: scratch.appending(path: "speakers"), configurationIsCurrent: configurationIsCurrent)
                } else { processing = nil }
                let names = await voiceprints.spokenNames()
                guard configurationIsCurrent(), !Task.isCancelled else { await processing?.discard(); return nil }
                return LiveTranscriber(
                    mic: mic, remote: remote,
                    chain: chain, hints: names + pipeline.vocabulary.filter { !names.contains($0) },
                    scratch: scratch, processing: processing, configurationIsCurrent: configurationIsCurrent)
            },
            makeCaptions: { captions in
                // Opt-in, from the transcription sources in their order; with none set up nothing runs.
                let current = settings.settings
                guard current.liveCaptions, let provider = pipelineSetup.buildCaptions(current) else { return nil }
                // Translation on this Mac, only once its models are downloaded.
                let source = current.captionEngine == .apple ? current.transcriptionLanguage.fixedCaptionSource : nil
                if current.translationEnabled, let target = current.captionTranslation.target, let translator = await catalog.captionTranslator(for: target, engine: current.captionEngine, source: source) {
                    guard !Task.isCancelled else { return nil }
                    captions.translate(with: translator, to: target, engine: current.captionEngine, source: source)
                }
                let names = await voiceprints.spokenNames()
                return CaptionStream(
                    provider: provider,
                    languageCode: current.transcriptionLanguage.code,
                    hints: names + current.vocabulary.filter { !names.contains($0) }, captions: captions)
            },
            enqueueRecording: { id, live in
                folders.recorded(id)
                guard let live else { return queue.enqueue(.process, on: id) }
                let prepared = live.processing
                return queue.enqueue(.process, on: id, using: prepared?.pipeline, finalize: {
                    guard let meeting = try? await library.meeting(id),
                          let transcription = await live.finish(mic: library.audioURL(meeting, track: .me),
                                                                remote: library.audioURL(meeting, track: .remote)),
                          !Task.isCancelled else { return }
                    if (try? await prepared?.attach(transcription, to: id)) != true {
                        _ = try? await library.attach(transcription, to: id)
                    }
                }, whileValid: { await live.isConfigurationCurrent() })
            })
        setup = SetupModel(
            permissions: permissions, installer: installer, offlineInstallers: offlineInstallers,
            translationInstaller: translationInstaller,
            suitability: OfflineSuitability(machine), credentials: credentials, validator: validator,
            settings: settings, runningBrowsers: runningBrowsers,
            prepareCoreML: {
                guard let engine = catalog.localTranscription(model: .breezeCoreML, language: .auto) as? any ClipTranscriber else {
                    throw ProviderError(.localTranscription, .modelUnavailable)
                }
                try await engine.prepare()
            },
            checkSetup: {
                switch (try? pipelineSetup.build(settings.settings)) {
                case .needsSetup(let issues): issues
                case .ready, nil: []
                }
            })
        meetings = MeetingListModel(library: library, voiceprints: voiceprints, queue: queue)
        people = VoiceprintsModel(store: voiceprints)
        let todoStatus = TodoStatus(file: paths.root.appending(path: "todos.json"))
        self.todoStatus = todoStatus
        self.reminders = RemindersSync(store: reminders, status: todoStatus, file: paths.root.appending(path: "reminders.json"))
        dashboard = DashboardModel(
            library: library, voiceprints: voiceprints, settings: settings, calendars: calendars,
            todosFile: paths.root.appending(path: "todos.json"), status: todoStatus, now: now)
        if let widgetFile {
            widget = WidgetPublisher(file: widgetFile, dashboard: dashboard, capture: capture, now: now)
        } else {
            widget = nil
        }
        enrollment = VoiceEnrollmentModel(
            voiceprints: voiceprints, recorder: voiceRecorder, permissions: permissions,
            scratch: paths.recordings.appending(path: "enrollment.wav"),
            transcribe: { audio in
                guard case .ready(let pipeline)? = try? pipelineSetup.build(settings.settings),
                      let heard = try? await pipeline.transcription.transcribe(audio: audio, hints: [], labelSpeakers: false) else { return nil }
                return heard.words.map(\.text).joined()
            },
            embed: { audio, duration in
                guard let models = catalog.localSpeakerModels() else { return nil }
                let voice = ClusterID("user")
                let segment = Diarization.Segment(cluster: voice, range: TimeRange(start: 0, end: duration))
                return try await models.embedder.embeddings(track: audio, segments: [segment])[voice] ?? []
            })
        onboarding = OnboardingFlow(setup: setup, settings: settings, enrollment: enrollment)
    }

    /// `signedInPage` is what the browser shows when a calendar sign-in hands back to the app;
    /// `calendars` replaces the live calendar sources (the snapshot hook passes sample ones);
    /// `recordingTitle` names a recording the global shortcut starts with no meeting to name it.
    public static func live(
        defaults: UserDefaults = .standard, credentials: any CredentialStoring = KeychainCredentialStore(),
        signedInPage: String = "mm2t", calendars: [any CalendarSource]? = nil, recordingTitle: String = "Recording",
        recorder: any Recorder = LiveRecorder(), permissions: any PermissionsProviding = LivePermissions(),
        shareWidget: Bool = true, machine: MachineProfile = .current
    ) throws -> AppController {
        let paths = AppPaths.standard(defaults: defaults)
        let openBrowser: @Sendable (URL) async -> Void = { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }
        let info = { (key: String) in OAuthClientID.resolve(Bundle.main.object(forInfoDictionaryKey: key)) }
        let models = DiarizationModels(directory: paths.models)
        let transcription = LocalTranscriptionModel.breezeMLX(in: paths.models)
        let llm = LocalLLMModel.qwen35(in: paths.models)
        let translation = TranslationModels.mozilla(in: paths.models)
        return try AppController(
            paths: paths, defaults: defaults, credentials: credentials,
            catalog: LiveProviderCatalog(models: models, transcriptionModel: transcription, llmModel: llm,
                                         translationModels: translation, machine: machine),
            recorder: recorder, permissions: permissions,
            installer: models, offlineInstallers: [.whisperCPU: LocalSpeechModel.whisperCPU.snapshot(in: paths.models), .transcription: transcription.snapshot, .breezeCoreML: LocalSpeechModel.breezeCoreML.snapshot(in: paths.models), .llm: llm.snapshot,
                .parakeet: LocalSpeechModel.parakeet.snapshot(in: paths.models), .nemotron: LocalSpeechModel.nemotron.snapshot(in: paths.models)],
            translationInstaller: { engine, target in
                switch engine {
                case .firefox: translation.for(target)
                case .hyMT2: HyTranslationModels(in: paths.models)
                case .apple: nil // System-owned; prepared with the system consent sheet.
                }
            },
            machine: machine, validator: LiveKeyValidator(),
            calendars: calendars ?? [
                SystemCalendar(defaults: defaults),
                OnlineCalendar.google(clientID: info("MM2TGoogleClientID"), credentials: credentials),
                OnlineCalendar.microsoft(clientID: info("MM2TMicrosoftClientID"), credentials: credentials,
                                         signedInPage: signedInPage, openBrowser: openBrowser),
            ],
            runningBrowsers: {
                let running = Set(RunningApps.recordable().map(\.bundleID))
                return BrowserScripting.scriptableBrowsers.filter(running.contains).sorted()
            },
            widgetFile: shareWidget ? WidgetLink.snapshotFile() : nil,
            recordingTitle: recordingTitle)
    }

    public var shouldPrepareBreeze: Bool {
        let selected = settings.settings
        return selected.transcriptionOrder.first == .local
            && (selected.localSpeechModel == .breeze || (selected.liveCaptions && selected.effectiveCaptionModel == .breeze))
            && setup.offlineModels[.transcription] == .downloaded
    }

    public func preparePreferredBreeze() async {
        guard shouldPrepareBreeze, let breeze = pipelineSetup.catalog.localTranscription(model: .breeze,
            language: settings.settings.transcriptionLanguage) as? any ClipTranscriber else { return }
        try? await breeze.prepare()
    }

    /// Imports recordings a crash left behind, then starts watching for meetings.
    public func launch(watchMeetings: Bool = true) async {
        Task(priority: .utility) {
            if settings.settings.localSpeechModel == .breezeCoreML, settings.settings.transcriptionOrder.contains(.local),
               setup.offlineModels[.breezeCoreML] == .downloaded { await setup.prepareInstalledCoreML() }
            await preparePreferredBreeze()
        }
        // Indexing reads every meeting; the rest of launch does not wait for it.
        Task { [searchSync] in await searchSync.start() }
        let scanner = RecordingRecoveryScanner(recordingsDirectory: paths.recordings, library: library)
        let outcome = await scanner.recoverAll()
        recoveryFailures = outcome.failures
        let unprocessed = await scanner.unprocessedMeetings()
        recovered = outcome.recovered + unprocessed.filter { !outcome.recovered.contains($0) }
        await meetings.reload()
        await enrollment.refresh()
        // Re-deriving voiceprints after a model change reads every meeting's audio, about 85 s for
        // 15 meetings, so the app opens first and shows the result when it is done.
        Task {
            if setup.needsCompletingModels { voiceprintUpdate = .fetchingModel }
            await setup.completeModelsAfterUpdate()
            await migrateVoiceprints { done, total in
                await MainActor.run { self.voiceprintUpdate = .rebuilding(done: done, of: total) }
            }
            voiceprintUpdate = nil
            await meetings.reload()
            await enrollment.refresh()
        }
        reminders.start()
        widget?.start()
        self.watchMeetings = watchMeetings
        startMonitorIfReady()
    }

    /// Live caption translation: the models the chosen language needs download when it is first
    /// chosen; other languages' models stay on disk. It applies from the next recording.
    public func setTranslationEnabled(_ enabled: Bool) async {
        settings.settings.translationEnabled = enabled
        setup.refreshTranslation()
        if enabled { await setup.downloadTranslationModels() }
    }

    public func setCaptionEngine(_ engine: CaptionEngine) async {
        if engine == .apple, #unavailable(macOS 26) { return }
        var current = settings.settings
        current.captionEngine = engine
        if let target = current.captionTranslation.target,
           (engine == .firefox && !CaptionTarget.all.contains(target)) || (engine == .hyMT2 && !CaptionTarget.hyTargets.contains(target)) {
            current.captionTranslation = .off
        }
        settings.settings = current
        setup.refreshTranslation()
        await setup.downloadTranslationModels()
    }

    public func setCaptionTranslation(_ choice: CaptionTranslation) async {
        settings.settings.captionTranslation = choice
        setup.refreshTranslation()
        if choice != .off { await setup.downloadTranslationModels() }
    }

    /// Marks setup finished and leaves it; from here the app watches for meetings.
    public func completeOnboarding() {
        settings.settings.hasCompletedOnboarding = true
        onboarding.close()
        startMonitorIfReady()
    }

    /// Shows setup in the main window again, at its first incomplete screen.
    public func openSetup() {
        onboarding.open()
    }

    /// Whether setup can be closed without finishing it: it was opened again after being finished,
    /// and nothing it asks for blocks the app, such as a missing voiceprint.
    public var canCloseSetup: Bool { onboarding.isOpenedAgain && !needsOnboarding }

    /// Leaves setup the user opened again without finishing it; unfinished setup stays.
    public func closeSetup() {
        onboarding.close()
    }

    public func processRecovered(_ id: MeetingID) async {
        recovered.removeAll { $0 == id }
        await queue.run(.process, on: id)
        await meetings.reload()
    }

    public func dismissRecovered(_ id: MeetingID) {
        recovered.removeAll { $0 == id }
    }

    public var translationCatalog: any ProviderCatalog { pipelineSetup.catalog }

    public func detail(_ id: MeetingID, labels: PresentationLabels, playback: (any MeetingPlayback)?) -> MeetingDetailModel {
        MeetingDetailModel(
            id: id, library: library, voiceprints: voiceprints, queue: queue, labels: labels, playback: playback,
            todos: todoStatus, reminders: reminders,
            learn: { [settings] term in settings.settings.addVocabulary(term, source: .learned) })
    }

    /// Meetings are not offered for recording until setup is done, and the record shortcut, like
    /// the record buttons, waits for the same.
    private func startMonitorIfReady() {
        guard watchMeetings, monitor == nil, !needsOnboarding else { return }
        let monitor = SystemSignalMonitor()
        monitor.start { [weak self] signals, _ in
            Task { await self?.capture.handle(signals) }
        }
        self.monitor = monitor
        let hotkey = GlobalHotkeyMonitor(hotkey: { [settings] in settings.settings.recordShortcut }) { [weak self] in
            guard let self else { return }
            Task { await self.capture.toggle(title: self.recordingTitle) }
        }
        hotkey.start()
        self.hotkey = hotkey
    }
}

/// What the app shows while an update to the voiceprint model is applied.
public enum VoiceprintUpdate: Equatable, Sendable {
    case fetchingModel
    case rebuilding(done: Int, of: Int)
}
