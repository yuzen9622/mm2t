import Foundation
import MM2TCore
import MM2TSystem
import Observation
import OSLog

/// The app whose audio becomes the remote track.
public struct RecordingTarget: Hashable, Sendable {
    /// nil leaves app selection automatic for online recordings.
    public let bundleID: String?
    public let name: String
    public let platform: MeetingPlatform?
    public let mode: RecordingMode
    /// Browsers are captured as a whole process, so other tabs' sound is recorded too (story 11).
    public var isBrowser: Bool { bundleID.map(MeetingDetector.browsers.contains) ?? false }

    public init(bundleID: String?, name: String, platform: MeetingPlatform?, mode: RecordingMode = .online) {
        self.bundleID = bundleID
        self.name = name
        self.platform = platform
        self.mode = mode
    }
}

extension MeetingPlatform {
    /// Product names, the same in every language; also the default meeting title.
    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .googleMeet: "Google Meet"
        }
    }
}

public enum CaptureFailure: Equatable, Sendable {
    case microphoneDenied
    case recorder(RecorderError)
    /// The recording stopped but could not be moved into the library; its files stay in the
    /// recordings folder and are imported at the next launch.
    case saveFailed(String)

    public var settingsPane: SettingsPane? {
        switch self {
        case .microphoneDenied: .microphone
        case .recorder(let error): error.settingsPane
        case .saveFailed: nil
        }
    }
}

/// The capture half of a session: from a detected meeting to a recording handed to processing.
/// Processing runs in `ProcessingQueue`, so a new meeting can be recorded while the last one is processed.
public enum CaptureState: Equatable, Sendable {
    case idle
    /// A meeting was detected and the prompt is showing; nothing records until the user starts.
    case prompting(DetectedMeeting)
    case awaitingMicrophone(RecordingTarget)
    case starting(RecordingTarget)
    case recording(RecordingTarget)
    case paused(RecordingTarget)
    /// The meeting ended; recording goes on until `deadline` so the user can keep it going.
    case endingSoon(RecordingTarget, deadline: Date)
    case stopping(RecordingTarget)
    case failed(CaptureFailure)

    public var target: RecordingTarget? {
        switch self {
        case .awaitingMicrophone(let t), .starting(let t), .recording(let t), .paused(let t), .endingSoon(let t, _),
             .stopping(let t): t
        case .idle, .prompting, .failed: nil
        }
    }

    public var isCapturing: Bool {
        switch self {
        case .recording, .paused, .endingSoon: true
        default: false
        }
    }
}

/// Levels and clock for the capsule, kept apart from `CaptureState` so 20 updates a second
/// redraw only the meters.
@MainActor @Observable
public final class RecordingMeters {
    public internal(set) var me = AudioLevel.silent
    public internal(set) var remote = AudioLevel.silent
    public internal(set) var elapsed: TimeInterval = 0
    public internal(set) var highlightCount = 0
    /// The remote track is digital silence while the target plays audio: system audio capture is
    /// almost certainly not granted.
    public internal(set) var remoteSilentWhilePlaying = false

    func reset() {
        me = .silent
        remote = .silent
        elapsed = 0
        highlightCount = 0
        remoteSilentWhilePlaying = false
    }
}

@MainActor @Observable
public final class CaptureController {
    private static let logger = Logger(subsystem: "dev.mm2t.app", category: "Processing")
    /// A call the user declined stays declined until its app has been off the mic this long, so a
    /// rejoin or device switch within one call does not prompt again; after that it is a new call.
    public static let dismissalCooldown: TimeInterval = 120
    /// How long the capsule counts down after a meeting ends before the recording stops; zero stops at once.
    public static let endCountdown = Duration.seconds(5)

    public private(set) var state: CaptureState = .idle
    public let meters = RecordingMeters()
    /// Live captions for the recording in progress; `.off` unless the user turned them on.
    public let captions = LiveCaptions()
    public private(set) var collaboration: CollabSession?

    @ObservationIgnored private let recorder: any Recorder
    @ObservationIgnored private let permissions: any PermissionsProviding
    @ObservationIgnored private let library: MeetingLibrary
    @ObservationIgnored private let recordingsDirectory: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let enqueueRecording: @MainActor (MeetingID, LiveTranscriber?) -> Task<Void, Never>?
    @ObservationIgnored private let makeLive: @MainActor (URL) async -> LiveTranscriber?
    @ObservationIgnored private var live: LiveTranscriber?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private let makeCollaboration: @MainActor (String) -> CollabSession?
    @ObservationIgnored private let makeCaptions: @MainActor (LiveCaptions) async -> CaptionStream?
    @ObservationIgnored private var closingCollaboration: Task<Void, Never>?
    @ObservationIgnored private var captionStream: CaptionStream?
    @ObservationIgnored private var captionTask: Task<Void, Never>?
    @ObservationIgnored private var detected: DetectedMeeting?
    /// Declined calls by bundle ID, kept out of detection so they neither prompt again nor hide
    /// another meeting. `releasedAt` is when the app last let go of the mic; nil while it holds it.
    @ObservationIgnored private var declined: [String: (meeting: DetectedMeeting, releasedAt: Date?)] = [:]
    @ObservationIgnored private var session: (any RecordingSession)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private let endCountdown: Duration
    @ObservationIgnored private var countdown: (task: Task<Void, Never>, resumeTo: CaptureState)?
    @ObservationIgnored private let recordingMode: @MainActor () -> RecordingMode
    @ObservationIgnored private let rules: @MainActor () -> DetectionRules
    @ObservationIgnored private let saveRules: @MainActor (DetectionRules) -> Void
    @ObservationIgnored private let appName: @MainActor (String) -> String?

    public init(
        recorder: any Recorder,
        permissions: any PermissionsProviding,
        library: MeetingLibrary,
        recordingsDirectory: URL,
        now: @escaping () -> Date = Date.init,
        endCountdown: Duration = CaptureController.endCountdown,
        rules: @escaping @MainActor () -> DetectionRules = { DetectionRules() },
        recordingMode: @escaping @MainActor () -> RecordingMode = { .online },
        saveRules: @escaping @MainActor (DetectionRules) -> Void = { _ in },
        appName: @escaping @MainActor (String) -> String? = { SystemSignalReader.appName(bundleID: $0) },
        makeLive: @escaping @MainActor (URL) async -> LiveTranscriber? = { _ in nil },
        makeCollaboration: @escaping @MainActor (String) -> CollabSession? = { _ in nil },
        makeCaptions: @escaping @MainActor (LiveCaptions) async -> CaptionStream? = { _ in nil },
        enqueueRecording: (@MainActor (MeetingID, LiveTranscriber?) -> Task<Void, Never>?)? = nil,
        onRecorded: @escaping @MainActor (MeetingID, LiveTranscriber?) async -> Void = { _, _ in }
    ) {
        self.rules = rules
        self.recordingMode = recordingMode
        self.saveRules = saveRules
        self.appName = appName
        self.makeLive = makeLive
        self.makeCaptions = makeCaptions
        self.makeCollaboration = makeCollaboration
        self.endCountdown = endCountdown
        self.recorder = recorder
        self.permissions = permissions
        self.library = library
        self.recordingsDirectory = recordingsDirectory
        self.now = now
        self.enqueueRecording = enqueueRecording ?? { id, live in Task { await onRecorded(id, live) } }
    }

    // MARK: Detection

    /// Feeds one poll of system signals through `MeetingDetector`.
    public func handle(_ signals: SystemSignals) async {
        let time = now()
        for (bundleID, call) in declined {
            if let releasedAt = call.releasedAt, time.timeIntervalSince(releasedAt) >= Self.dismissalCooldown {
                declined[bundleID] = nil
            } else if signals.micBundleIDs.contains(bundleID) {
                declined[bundleID]?.releasedAt = nil
            } else if call.releasedAt == nil {
                declined[bundleID]?.releasedAt = time
            }
        }
        let (next, events) = MeetingDetector.evaluate(signals, current: detected, declined: Set(declined.keys), rules: rules())
        detected = next
        for event in events {
            switch event {
            case .detected(let meeting): detect(meeting)
            case .ended(let meeting): await end(meeting)
            }
        }
    }

    private func detect(_ meeting: DetectedMeeting) {
        guard state == .idle else { return }
        state = .prompting(meeting)
    }

    private func end(_ meeting: DetectedMeeting) async {
        switch state {
        case .prompting(let prompted) where prompted == meeting:
            state = .idle
        case .recording(let target), .paused(let target):
            guard target.mode == .online, target.bundleID == meeting.bundleID || target.bundleID == nil else { break }
            if endCountdown == .zero { await stop() } else { beginCountdown(target) }
        default:
            break
        }
    }

    /// Answers the prompt with "not this one". The call stops being the tracked one, so another
    /// meeting that starts while it still holds the mic is prompted.
    public func dismiss() {
        guard case .prompting(let meeting) = state else { return }
        declined[meeting.bundleID] = (meeting, nil)
        if detected?.bundleID == meeting.bundleID { detected = nil }
        state = .idle
    }

    /// Answers an unlisted app's or site's prompt with "always prompt": the rule is saved and the
    /// prompt stays up, without the learn choices, for the user to record this call or not.
    public func alwaysPrompt() {
        guard case .prompting(var meeting) = state, meeting.isUnlisted else { return }
        remember(meeting, prompts: true)
        meeting.isUnlisted = false
        if detected?.bundleID == meeting.bundleID { detected = meeting }
        state = .prompting(meeting)
    }

    /// Answers an unlisted app's or site's prompt with "never ask": the rule is saved and the prompt closes.
    public func neverAsk() {
        guard case .prompting(let meeting) = state, meeting.isUnlisted else { return }
        remember(meeting, prompts: false)
        state = .idle
    }

    private func remember(_ meeting: DetectedMeeting, prompts: Bool) {
        var rules = rules()
        if let domain = meeting.domain {
            rules.set(DetectionRule(key: domain, name: domain, prompts: prompts), in: \.sites)
        } else {
            rules.set(DetectionRule(key: meeting.bundleID, name: displayName(of: meeting), prompts: prompts), in: \.apps)
        }
        saveRules(rules)
    }

    /// What the prompt and the recording call a detected call: the platform, the site's domain or
    /// the app's own name; the bundle ID only when the app cannot be found.
    public func displayName(of meeting: DetectedMeeting) -> String {
        meeting.platform?.displayName ?? meeting.domain ?? DetectionPolicy.callApp(meeting.bundleID)?.name
            ?? appName(meeting.bundleID) ?? rules().app(meeting.bundleID)?.name ?? meeting.bundleID
    }

    /// Answers the prompt with "record".
    public func startPrompted() async {
        guard case .prompting(let meeting) = state else { return }
        await begin(RecordingTarget(bundleID: meeting.bundleID, name: displayName(of: meeting), platform: meeting.platform, mode: .online))
    }

    /// Manual recording uses the saved meeting type. `title` names a recording with no detected call.
    public func startNow(title: String) async {
        if recordingMode() == .inPerson {
            await startManually(RecordingTarget(bundleID: nil, name: title, platform: nil, mode: .inPerson))
            return
        }
        // A declined call still on the mic is the meeting the user changed their mind about; it is
        // tracked again so its end stops the recording.
        if detected == nil, state.target == nil,
           let call = declined.values.filter({ $0.releasedAt == nil }).map(\.meeting).min(by: { $0.bundleID < $1.bundleID }) {
            declined[call.bundleID] = nil
            detected = call
        }
        if let detected {
            await startManually(RecordingTarget(
                bundleID: detected.bundleID, name: displayName(of: detected), platform: detected.platform))
        } else {
            await startManually(RecordingTarget(bundleID: nil, name: title, platform: nil))
        }
    }

    /// The global shortcut: finishes the recording in progress, otherwise starts one exactly as the
    /// record button does. A meeting waiting at the prompt counts as accepted. While a recording is
    /// starting or stopping a press does nothing, so a double press cannot start a second one.
    public func toggle(title: String) async {
        if state.isCapturing { await stop() } else { await startNow(title: title) }
    }

    /// From the menu, when detection missed the meeting or the user wants another app.
    public func startManually(_ target: RecordingTarget) async {
        switch state {
        case .idle, .prompting, .failed: await begin(target)
        default: return
        }
    }

    // MARK: Recording

    private func begin(_ target: RecordingTarget) async {
        switch permissions.microphone {
        case .notDetermined:
            state = .awaitingMicrophone(target)
            guard await permissions.requestMicrophone() else {
                state = .failed(.microphoneDenied)
                return
            }
        case .denied:
            state = .failed(.microphoneDenied)
            return
        case .granted, .unknown:
            break
        }
        state = .starting(target)
        let systemAudio: SystemAudioCapture
        if target.mode == .inPerson { systemAudio = .off }
        else if let id = target.bundleID { systemAudio = .app(id) }
        else { systemAudio = .automatic(ignoring: Set(rules().apps.filter { !$0.prompts }.map(\.key))) }
        let configuration = RecorderConfiguration(
            systemAudio: systemAudio,
            directory: recordingsDirectory.appending(path: UUID().uuidString),
            title: target.name,
            platform: target.platform)
        do {
            let session = try await recorder.start(configuration)
            self.session = session
            meters.reset()
            collaboration = makeCollaboration(target.name)
            if let collaboration {
                collaboration.captionsActive = { [weak captions] in captions?.isActive == true }
                captions.onFinalized = { [weak collaboration] segment in collaboration?.finalized(segment) }
            }
            state = .recording(target)
            liveTask = Task { [weak self] in
                guard let live = await self?.makeLive(configuration.directory), !Task.isCancelled else { return }
                self?.live = live
                let interval = await live.pollingInterval
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    if !Task.isCancelled { await live.advance() }
                }
            }
            startCaptions(session, sampleRate: configuration.sampleRate)
            eventTask = Task { [weak self] in
                for await event in session.events {
                    await self?.apply(event, from: session)
                }
            }
        } catch let error as RecorderError {
            state = .failed(.recorder(error))
        } catch {
            state = .failed(.recorder(.fileSystem(String(describing: error))))
        }
    }

    /// Captions run beside the recording and the batch pieces and never feed either; a caption
    /// failure only shows in `captions.status`.
    private func startCaptions(_ session: any RecordingSession, sampleRate: Int) {
        captions.clear()
        captionTask = Task { [weak self] in
            guard let self, let stream = await self.makeCaptions(self.captions), !Task.isCancelled else { return }
            self.captionStream = stream
            await stream.start(audio: await session.audioStream(), sampleRate: sampleRate)
            if case .paused = self.state { await stream.pause() }
        }
    }

    private func stopCaptions(savedMeeting: MeetingID? = nil) async {
        captionTask?.cancel()
        captionTask = nil
        let stream = captionStream
        captionStream = nil
        await stream?.stop(retainingLeaseFor: savedMeeting)
        captions.clear()
    }

    private func apply(_ event: RecorderEvent, from session: any RecordingSession) async {
        switch event {
        case .levels(let levels):
            meters.me = levels.me
            meters.remote = levels.remote
            if levels.remote.peak > 0 { meters.remoteSilentWhilePlaying = false }
            meters.elapsed = await session.elapsed
        case .remoteSilentWhileTargetPlaying:
            meters.remoteSilentWhilePlaying = true
        case .microphoneSwitched, .captureRestarted, .audioDropped, .writeFailed, .targetProcessesChanged, .systemAudioLocked:
            break
        }
    }

    private func beginCountdown(_ target: RecordingTarget) {
        let resumeTo = state
        let seconds = Double(endCountdown.components.seconds) + Double(endCountdown.components.attoseconds) / 1e18
        state = .endingSoon(target, deadline: now().addingTimeInterval(seconds))
        let task = Task { [weak self, endCountdown] in
            try? await Task.sleep(for: endCountdown)
            guard !Task.isCancelled, let self, case .endingSoon = self.state else { return }
            await self.stop()
        }
        countdown = (task, resumeTo)
    }

    /// Answers the end-of-meeting countdown with "keep recording".
    public func keepRecording() async {
        guard case .endingSoon = state, let countdown else { return }
        countdown.task.cancel()
        self.countdown = nil
        state = countdown.resumeTo
    }

    public func pause() async {
        guard case .recording(let target) = state, let session else { return }
        await session.pause()
        state = .paused(target)
        await captionStream?.pause()
    }

    public func resume() async {
        guard case .paused(let target) = state, let session else { return }
        await session.resume()
        meters.remoteSilentWhilePlaying = false
        state = .recording(target)
        await captionStream?.resume()
    }

    public func markHighlight() async {
        guard state.isCapturing, let session, (try? await session.markHighlight()) != nil else { return }
        meters.highlightCount += 1
    }

    public private(set) var lastSavedMeeting: MeetingID?

    func signOutOfCollaboration() async {
        await collaboration?.signOut()
        await closingCollaboration?.value
    }

    func endCollaboration() -> Task<Void, Never>? {
        captions.onFinalized = nil
        if let ending = collaboration?.end() {
            let previous = closingCollaboration
            closingCollaboration = Task { await previous?.value; await ending.value }
        }
        collaboration = nil
        return closingCollaboration
    }

    /// Finishes both tracks, moves them into the library and hands the meeting to processing.
    public func stop() async {
        guard state.isCapturing, let target = state.target, let session else { return }
        let started = ContinuousClock.now
        countdown?.task.cancel()
        countdown = nil
        state = .stopping(target)
        let room = collaboration?.meetingRoom
        let closingCollaboration = endCollaboration()
        eventTask?.cancel()
        eventTask = nil
        liveTask?.cancel()
        liveTask = nil
        let live = self.live
        self.live = nil
        self.session = nil
        await live?.prepareForMove()
        captionTask?.cancel()
        let id: MeetingID
        do {
            let recording = try await session.stop()
            id = try await library.create(recording, room: room).id
            try? FileManager.default.removeItem(at: recording.micTrack.deletingLastPathComponent())
        } catch {
            await stopCaptions()
            state = .failed(.saveFailed(String(describing: error)))
            return
        }
        await stopCaptions(savedMeeting: id)
        let job = enqueueRecording(id, live)
        lastSavedMeeting = id
        state = .idle
        await closingCollaboration?.value
        await job?.value
        let elapsed = started.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        Self.logger.info("event=stop_to_processing_return elapsed_seconds=\(seconds, privacy: .public) live_enabled=\(live != nil, privacy: .public)")
    }

    public func liveProgress() async -> LiveProcessingProgress? {
        await live?.progress()
    }

    public func acknowledgeFailure() {
        if case .failed = state { state = .idle }
    }
}
