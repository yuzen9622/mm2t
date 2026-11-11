import Foundation
import MM2TCore
import MM2TSystem
import Observation

/// The app whose audio becomes the remote track.
public struct RecordingTarget: Hashable, Sendable {
    /// nil records everything the Mac plays, for a recording started with no meeting detected.
    public let bundleID: String?
    public let name: String
    public let platform: MeetingPlatform?
    /// Browsers are captured as a whole process, so other tabs' sound is recorded too (story 11).
    public var isBrowser: Bool { bundleID.map(MeetingDetector.browsers.contains) ?? false }

    public init(bundleID: String?, name: String, platform: MeetingPlatform?) {
        self.bundleID = bundleID
        self.name = name
        self.platform = platform
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
    case stopping(RecordingTarget)
    case failed(CaptureFailure)

    public var target: RecordingTarget? {
        switch self {
        case .awaitingMicrophone(let t), .starting(let t), .recording(let t), .paused(let t), .stopping(let t): t
        case .idle, .prompting, .failed: nil
        }
    }

    public var isCapturing: Bool {
        switch self {
        case .recording, .paused: true
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
    /// A meeting the user dismissed stays dismissed until it has been over this long, so the
    /// detector ending and re-detecting one call (a rejoin, a device switch) does not prompt again.
    public static let dismissalCooldown: TimeInterval = 120

    public private(set) var state: CaptureState = .idle
    public let meters = RecordingMeters()

    @ObservationIgnored private let recorder: any Recorder
    @ObservationIgnored private let permissions: any PermissionsProviding
    @ObservationIgnored private let library: MeetingLibrary
    @ObservationIgnored private let recordingsDirectory: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let onRecorded: @MainActor (MeetingID) async -> Void
    @ObservationIgnored private var detected: DetectedMeeting?
    @ObservationIgnored private var dismissed: (meeting: DetectedMeeting, endedAt: Date?)?
    @ObservationIgnored private var session: (any RecordingSession)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    public init(
        recorder: any Recorder,
        permissions: any PermissionsProviding,
        library: MeetingLibrary,
        recordingsDirectory: URL,
        now: @escaping () -> Date = Date.init,
        onRecorded: @escaping @MainActor (MeetingID) async -> Void
    ) {
        self.recorder = recorder
        self.permissions = permissions
        self.library = library
        self.recordingsDirectory = recordingsDirectory
        self.now = now
        self.onRecorded = onRecorded
    }

    // MARK: Detection

    /// Feeds one poll of system signals through `MeetingDetector`.
    public func handle(_ signals: SystemSignals) async {
        let (next, events) = MeetingDetector.evaluate(signals, current: detected)
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
        if let dismissed, dismissed.meeting == meeting {
            if let endedAt = dismissed.endedAt, now().timeIntervalSince(endedAt) >= Self.dismissalCooldown {
                self.dismissed = nil
            } else {
                self.dismissed?.endedAt = nil
                return
            }
        }
        state = .prompting(meeting)
    }

    private func end(_ meeting: DetectedMeeting) async {
        if dismissed?.meeting == meeting { dismissed?.endedAt = now() }
        switch state {
        case .prompting(let prompted) where prompted == meeting:
            state = .idle
        case .recording(let target), .paused(let target):
            if target.bundleID == meeting.bundleID { await stop() }
        default:
            break
        }
    }

    /// Answers the prompt with "not this one".
    public func dismiss() {
        guard case .prompting(let meeting) = state else { return }
        dismissed = (meeting, nil)
        state = .idle
    }

    /// Answers the prompt with "record".
    public func startPrompted() async {
        guard case .prompting(let meeting) = state else { return }
        await begin(RecordingTarget(bundleID: meeting.bundleID, name: meeting.platform.displayName, platform: meeting.platform))
    }

    /// The record button: the meeting in progress if the detector sees one, otherwise the Mac's
    /// whole sound output. `title` names a recording that has no meeting to name it.
    public func startNow(title: String) async {
        if let detected {
            await startManually(RecordingTarget(
                bundleID: detected.bundleID, name: detected.platform.displayName, platform: detected.platform))
        } else {
            await startManually(RecordingTarget(bundleID: nil, name: title, platform: nil))
        }
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
        let configuration = RecorderConfiguration(
            targetBundleID: target.bundleID,
            directory: recordingsDirectory.appending(path: UUID().uuidString),
            title: target.name,
            platform: target.platform)
        do {
            let session = try await recorder.start(configuration)
            self.session = session
            meters.reset()
            state = .recording(target)
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

    private func apply(_ event: RecorderEvent, from session: any RecordingSession) async {
        switch event {
        case .levels(let levels):
            meters.me = levels.me
            meters.remote = levels.remote
            meters.elapsed = await session.elapsed
        case .remoteSilentWhileTargetPlaying:
            meters.remoteSilentWhilePlaying = true
        case .microphoneSwitched, .captureRestarted, .audioDropped, .writeFailed, .targetProcessesChanged:
            break
        }
    }

    public func pause() async {
        guard case .recording(let target) = state, let session else { return }
        await session.pause()
        state = .paused(target)
    }

    public func resume() async {
        guard case .paused(let target) = state, let session else { return }
        await session.resume()
        meters.remoteSilentWhilePlaying = false
        state = .recording(target)
    }

    public func markHighlight() async {
        guard state.isCapturing, let session, (try? await session.markHighlight()) != nil else { return }
        meters.highlightCount += 1
    }

    /// Finishes both tracks, moves them into the library and hands the meeting to processing.
    public func stop() async {
        guard state.isCapturing, let target = state.target, let session else { return }
        state = .stopping(target)
        eventTask?.cancel()
        eventTask = nil
        self.session = nil
        let id: MeetingID
        do {
            let recording = try await session.stop()
            id = try await library.create(recording).id
            try? FileManager.default.removeItem(at: recording.micTrack.deletingLastPathComponent())
        } catch {
            state = .failed(.saveFailed(String(describing: error)))
            return
        }
        state = .idle
        await onRecorded(id)
    }

    public func acknowledgeFailure() {
        if case .failed = state { state = .idle }
    }
}
