import AppKit
import Foundation
import MM2TCore
import MM2TDiarization
import MM2TLocal
import MM2TProviders
import MM2TSystem
import Observation

/// Where the app keeps its data. `MM2TDataRoot` in UserDefaults (or `-MM2TDataRoot <path>` on the
/// command line) moves everything, for development against a scratch library.
public struct AppPaths: Sendable {
    public let root: URL
    public var meetings: URL { root.appending(path: "Meetings") }
    public var recordings: URL { root.appending(path: "Recordings") }
    public var voiceprints: URL { root.appending(path: "voiceprints.json") }
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
    public let voiceprints: VoiceprintStore
    public let queue: ProcessingQueue
    public let capture: CaptureController
    public let setup: SetupModel
    public let meetings: MeetingListModel
    public let people: VoiceprintsModel
    public let dashboard: DashboardModel
    public let enrollment: VoiceEnrollmentModel

    /// The app is not usable until setup is finished and the user's voice is enrolled.
    public var needsOnboarding: Bool { !settings.settings.hasCompletedOnboarding || !enrollment.hasVoice }
    /// Recordings repaired at launch (or left unprocessed by a quit), offered for processing.
    public private(set) var recovered: [MeetingID] = []
    public private(set) var recoveryFailures: [URL: String] = [:]

    @ObservationIgnored private let pipelineSetup: PipelineSetup
    @ObservationIgnored private var monitor: SystemSignalMonitor?
    @ObservationIgnored private var watchMeetings = false

    public init(
        paths: AppPaths,
        defaults: UserDefaults,
        credentials: any CredentialStoring,
        catalog: any ProviderCatalog,
        recorder: any Recorder,
        permissions: any PermissionsProviding,
        installer: any ModelInstalling,
        offlineInstallers: [OfflineModel: any ModelInstalling],
        machine: MachineProfile = .current,
        validator: any KeyValidating,
        calendars: [any CalendarSource] = [],
        voiceRecorder: any VoiceSampleRecording = MicrophoneSampleRecorder(),
        runningBrowsers: @escaping @MainActor () -> [String] = { [] },
        now: @escaping () -> Date = Date.init,
        endCountdown: Duration = CaptureController.endCountdown
    ) throws {
        self.paths = paths
        let settings = SettingsStore(defaults: defaults)
        let library = MeetingLibrary(root: paths.meetings)
        let voiceprints = try VoiceprintStore(fileURL: paths.voiceprints)
        let pipelineSetup = PipelineSetup(library: library, voiceprints: voiceprints, credentials: credentials, catalog: catalog)
        let queue = ProcessingQueue { try pipelineSetup.build(settings.settings) }
        self.settings = settings
        self.library = library
        self.voiceprints = voiceprints
        self.pipelineSetup = pipelineSetup
        self.queue = queue
        capture = CaptureController(
            recorder: recorder, permissions: permissions, library: library, recordingsDirectory: paths.recordings,
            now: now, endCountdown: endCountdown,
            makeLive: { directory in
                // Only with hosted speech recognition and the on-device speaker model: an on-device
                // speech model would compete with the meeting for the machine, and pieces carry no
                // speaker labels for the fallback separation to use.
                let current = settings.settings
                guard !current.transcriptionOrder.contains(.local), current.diarizationOrder.first == .local,
                      case .ready(let pipeline)? = try? pipelineSetup.build(current), pipeline.diarizer != nil else { return nil }
                let names = await voiceprints.spokenNames()
                return LiveTranscriber(
                    mic: directory.appending(path: RecordingManifest.micFile),
                    remote: directory.appending(path: RecordingManifest.remoteFile),
                    chain: pipeline.transcription, hints: names + pipeline.vocabulary.filter { !names.contains($0) },
                    scratch: paths.recordings.appending(path: "live-\(UUID().uuidString)"))
            },
            onRecorded: { id, live in
                if let live, let meeting = try? await library.meeting(id),
                   let transcription = await live.finish(
                       mic: await library.audioURL(meeting, track: .me), remote: await library.audioURL(meeting, track: .remote)) {
                    _ = try? await library.attach(transcription, to: id)
                }
                await queue.run(.process, on: id)
            })
        setup = SetupModel(
            permissions: permissions, installer: installer, offlineInstallers: offlineInstallers,
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
        dashboard = DashboardModel(
            library: library, voiceprints: voiceprints, settings: settings, calendars: calendars,
            todosFile: paths.root.appending(path: "todos.json"), now: now)
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
        queue.onCompleted = { meeting in
            for term in meeting.outputs.summary?.terms ?? [] { settings.settings.addVocabulary(term, source: .learned) }
        }
    }

    /// `signedInPage` is what the browser shows when a calendar sign-in hands back to the app;
    /// `calendars` replaces the live calendar sources (the snapshot hook passes sample ones).
    public static func live(
        defaults: UserDefaults = .standard, credentials: any CredentialStoring = KeychainCredentialStore(),
        signedInPage: String = "mm2t", calendars: [any CalendarSource]? = nil
    ) throws -> AppController {
        let paths = AppPaths.standard(defaults: defaults)
        let openBrowser: @Sendable (URL) async -> Void = { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }
        let info = { (key: String) in OAuthClientID.resolve(Bundle.main.object(forInfoDictionaryKey: key)) }
        let models = DiarizationModels(directory: paths.models)
        let transcription = LocalTranscriptionModel.breeze(in: paths.models)
        let llm = LocalLLMModel.qwen35(in: paths.models)
        return try AppController(
            paths: paths, defaults: defaults, credentials: credentials,
            catalog: LiveProviderCatalog(models: models, transcriptionModel: transcription, llmModel: llm),
            recorder: LiveRecorder(), permissions: LivePermissions(),
            installer: models, offlineInstallers: [.transcription: transcription.snapshot, .llm: llm.snapshot],
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
            })
    }

    /// Imports recordings a crash left behind, then starts watching for meetings.
    public func launch(watchMeetings: Bool = true) async {
        let scanner = RecordingRecoveryScanner(recordingsDirectory: paths.recordings, library: library)
        let outcome = await scanner.recoverAll()
        recoveryFailures = outcome.failures
        let unprocessed = await scanner.unprocessedMeetings()
        recovered = outcome.recovered + unprocessed.filter { !outcome.recovered.contains($0) }
        await meetings.reload()
        await enrollment.refresh()
        self.watchMeetings = watchMeetings
        startMonitorIfReady()
    }

    /// Marks setup finished; from here the app watches for meetings.
    public func completeOnboarding() {
        settings.settings.hasCompletedOnboarding = true
        startMonitorIfReady()
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
            learn: { [settings] term in settings.settings.addVocabulary(term, source: .learned) })
    }

    /// Meetings are not offered for recording until setup is done.
    private func startMonitorIfReady() {
        guard watchMeetings, monitor == nil, !needsOnboarding else { return }
        let monitor = SystemSignalMonitor()
        monitor.start { [weak self] signals, _ in
            Task { await self?.capture.handle(signals) }
        }
        self.monitor = monitor
    }
}
