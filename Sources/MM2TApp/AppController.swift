import AppKit
import Foundation
import MM2TCore
import MM2TDiarization
import MM2TLocal
import MM2TProviders
import MM2TSystem
import MM2TWidgetData
import Observation

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
    public private(set) var recoveryFailures: [URL: String] = [:]

    @ObservationIgnored private let pipelineSetup: PipelineSetup
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
        AssistantModel(engine: AssistantEngine(library: library, index: searchIndex, voiceprints: voiceprints,
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
        translationInstaller: any ModelInstalling,
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
        self.paths = paths
        assistantConversations = AssistantConversations(directory: paths.assistantConversations)
        assistantPreferences = AssistantPreferences(file: paths.assistantPreferences)
        self.recordingTitle = recordingTitle
        let settings = SettingsStore(defaults: defaults)
        let library = MeetingLibrary(root: paths.meetings)
        let voiceprints = try VoiceprintStore(fileURL: paths.voiceprints)
        let pipelineSetup = PipelineSetup(library: library, voiceprints: voiceprints, credentials: credentials, catalog: catalog)
        let queue = ProcessingQueue(
            makePipeline: { try pipelineSetup.build(settings.settings) },
            makeLLM: { try pipelineSetup.buildLLM(settings.settings) })
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
                // Only with hosted speech recognition and the on-device speaker model: an on-device
                // speech model would compete with the meeting for the machine.
                let current = settings.settings
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
                let scratch = paths.recordings.appending(path: "live-\(UUID().uuidString)")
                let processing: LiveRecordingProcessor?
                if current.llmLocation == .cloud, let factory = pipeline.diarizer as? any StreamingDiarizerFactory,
                   let session = try? await factory.makeStreamingSession() {
                    processing = LiveRecordingProcessor(pipeline: pipeline, session: session,
                        scratch: scratch.appending(path: "speakers"), configurationIsCurrent: configurationIsCurrent)
                } else { processing = nil }
                let names = await voiceprints.spokenNames()
                guard configurationIsCurrent(), !Task.isCancelled else { await processing?.discard(); return nil }
                return LiveTranscriber(
                    mic: directory.appending(path: RecordingManifest.micFile),
                    remote: directory.appending(path: RecordingManifest.remoteFile),
                    chain: chain, hints: names + pipeline.vocabulary.filter { !names.contains($0) },
                    scratch: scratch, processing: processing, configurationIsCurrent: configurationIsCurrent)
            },
            makeCaptions: { captions in
                // Opt-in, and only with an ElevenLabs key; otherwise nothing runs and no socket opens.
                let current = settings.settings
                guard current.liveCaptions, let key = try? credentials.read(.elevenLabsAPIKey), !key.isEmpty else { return nil }
                // Translation on this Mac, only once its models are downloaded.
                if let target = current.captionTranslation.target, let translator = catalog.captionTranslator() {
                    captions.translate(with: translator, to: target)
                }
                let names = await voiceprints.spokenNames()
                return CaptionStream(
                    provider: catalog.streamingTranscription(apiKey: key),
                    languageCode: current.transcriptionLanguage.code,
                    hints: names + current.vocabulary.filter { !names.contains($0) }, captions: captions)
            },
            onRecorded: { id, live in
                let prepared = live?.processing
                if let live, let meeting = try? await library.meeting(id),
                   let transcription = await live.finish(
                       mic: await library.audioURL(meeting, track: .me), remote: await library.audioURL(meeting, track: .remote)) {
                    if (try? await prepared?.attach(transcription, to: id)) != true {
                        _ = try? await library.attach(transcription, to: id)
                    }
                }
                let reusable = await live?.isConfigurationCurrent() == true
                await queue.run(.process, on: id, using: reusable ? prepared?.pipeline : nil,
                                whileValid: { await live?.isConfigurationCurrent() == true })
            })
        setup = SetupModel(
            permissions: permissions, installer: installer, offlineInstallers: offlineInstallers,
            translationInstaller: translationInstaller,
            suitability: OfflineSuitability(machine), credentials: credentials, validator: validator,
            settings: settings, runningBrowsers: runningBrowsers,
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
        shareWidget: Bool = true
    ) throws -> AppController {
        let paths = AppPaths.standard(defaults: defaults)
        let openBrowser: @Sendable (URL) async -> Void = { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }
        let info = { (key: String) in OAuthClientID.resolve(Bundle.main.object(forInfoDictionaryKey: key)) }
        let models = DiarizationModels(directory: paths.models)
        let transcription = LocalTranscriptionModel.breeze(in: paths.models)
        let llm = LocalLLMModel.qwen35(in: paths.models)
        let translation = TranslationModels.mozilla(in: paths.models)
        return try AppController(
            paths: paths, defaults: defaults, credentials: credentials,
            catalog: LiveProviderCatalog(models: models, transcriptionModel: transcription, llmModel: llm,
                                         translationModels: translation),
            recorder: recorder, permissions: permissions,
            installer: models, offlineInstallers: [.transcription: transcription.snapshot, .llm: llm.snapshot],
            translationInstaller: translation,
            validator: LiveKeyValidator(),
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

    /// Imports recordings a crash left behind, then starts watching for meetings.
    public func launch(watchMeetings: Bool = true) async {
        // Indexing reads every meeting; the rest of launch does not wait for it.
        Task { [searchSync] in await searchSync.start() }
        let scanner = RecordingRecoveryScanner(recordingsDirectory: paths.recordings, library: library)
        let outcome = await scanner.recoverAll()
        recoveryFailures = outcome.failures
        let unprocessed = await scanner.unprocessedMeetings()
        recovered = outcome.recovered + unprocessed.filter { !outcome.recovered.contains($0) }
        await meetings.reload()
        await enrollment.refresh()
        reminders.start()
        widget?.start()
        self.watchMeetings = watchMeetings
        startMonitorIfReady()
    }

    /// Live caption translation: the models for both directions download the first time it is
    /// turned on. It applies from the next recording.
    public func setCaptionTranslation(_ choice: CaptionTranslation) async {
        settings.settings.captionTranslation = choice
        guard choice != .off else { return }
        switch setup.translationModels {
        case .notDownloaded, .failed: await setup.downloadTranslationModels()
        case .downloading, .downloaded: break
        }
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
