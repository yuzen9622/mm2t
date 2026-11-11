import CoreAudio
import Foundation
import MM2TCore

public struct RecorderConfiguration: Sendable {
    /// The app whose audio becomes the remote track; for a browser, the browser's own bundle id.
    public var targetBundleID: String
    /// A fresh directory for this session; `mic.wav`, `remote.wav` and `session.json` go here.
    public var directory: URL
    public var title: String
    public var platform: MeetingPlatform?
    /// Both tracks are written at this rate, mono 16-bit.
    public var sampleRate: Int
    /// false leaves the mic track silent (same length) and skips the microphone permission; for
    /// remote-only recording and the probe's tap self-test.
    public var captureMicrophone: Bool

    public init(targetBundleID: String, directory: URL, title: String,
                platform: MeetingPlatform? = nil, sampleRate: Int = 16_000, captureMicrophone: Bool = true) {
        self.targetBundleID = targetBundleID
        self.directory = directory
        self.title = title
        self.platform = platform
        self.sampleRate = sampleRate
        self.captureMicrophone = captureMicrophone
    }
}

public enum RecorderError: Error, Equatable, Sendable {
    /// The UI should explain and link to `SettingsPane.microphone`.
    case microphoneAccessDenied
    /// Run onboarding (`Permissions.requestMicrophone()`) before recording.
    case microphoneAccessNotDetermined
    case noInputDevice
    /// Creating the process tap failed; on macOS before 14.2 this is always the case.
    case systemAudioCaptureUnavailable(CoreAudioError)
    case microphoneCaptureFailed(CoreAudioError)
    case directoryNotEmpty(URL)
    case fileSystem(String)
    case alreadyStopped

    public var settingsPane: SettingsPane? {
        switch self {
        case .microphoneAccessDenied, .microphoneAccessNotDetermined: .microphone
        case .systemAudioCaptureUnavailable: .systemAudio
        default: nil
        }
    }
}

public enum RecorderEvent: Sendable, Equatable {
    /// About 20 times a second.
    case levels(TrackLevels)
    /// The remote track has been exact digital silence for several seconds while the target app is
    /// outputting audio. That is how a missing system-audio-capture permission shows up, because a
    /// denied tap delivers zeros instead of failing. Sent once per silent stretch.
    case remoteSilentWhileTargetPlaying
    case microphoneSwitched(deviceName: String)
    /// A capture stalled (sleep, device removed) and was rebuilt; the gap is silence in the file.
    case captureRestarted(Track, reason: String)
    case audioDropped(Track, frames: Int)
    /// Flushing to disk failed (disk full, volume removed); capture continues and retries each second.
    case writeFailed(String)
    case targetProcessesChanged(count: Int)
}

/// Records the microphone and one app's audio into two time-aligned WAV tracks.
///
/// Audio flows IO thread -> `CaptureRing` -> this actor, which every 50 ms drains both rings
/// through the shared `RecordingTimeline`, writes, and publishes levels.
@available(macOS 14.2, *)
public actor AudioRecorder {
    public nonisolated let events: AsyncStream<RecorderEvent>
    public nonisolated let configuration: RecorderConfiguration
    private let continuation: AsyncStream<RecorderEvent>.Continuation

    private var timeline: RecordingTimeline
    private var manifest: RecordingManifest
    private let mic: TrackPipeline
    private let remote: TrackPipeline
    private var micIO: DeviceIO?
    private var micListeners: [PropertyListener] = []
    private var tap: ProcessTap?
    private var tapIO: DeviceIO?
    private var systemListeners: [PropertyListener] = []
    private let listenerQueue = DispatchQueue(label: "mm2t.recorder.listeners")
    private var drainTask: Task<Void, Never>?
    private var lastFlush = 0.0
    private var micStartedAt = 0.0
    private var tapStartedAt = 0.0
    private var remoteSilentSince: Double?
    private var reportedSilence = false

    static let stallTimeout = 2.0
    static let silenceTimeout = 6.0
    /// Audio younger than this may still be in flight from the IO thread, so gap padding stops short of it.
    static let captureLatencyMargin = 0.5

    /// Starts both captures. Throws `RecorderError` with a settings pane for permission problems.
    public static func start(_ configuration: RecorderConfiguration) async throws -> AudioRecorder {
        if configuration.captureMicrophone {
            switch Permissions.microphone {
            case .denied: throw RecorderError.microphoneAccessDenied
            case .notDetermined: throw RecorderError.microphoneAccessNotDetermined
            case .granted, .unknown: break
            }
        }
        let recorder = try AudioRecorder(configuration)
        do {
            try await recorder.begin()
        } catch {
            try? FileManager.default.removeItem(at: configuration.directory)
            throw error
        }
        return recorder
    }

    private init(_ configuration: RecorderConfiguration) throws {
        self.configuration = configuration
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        let files = FileManager.default
        let directory = configuration.directory
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            guard try files.contentsOfDirectory(atPath: directory.path).isEmpty else {
                throw RecorderError.directoryNotEmpty(directory)
            }
            manifest = RecordingManifest(title: configuration.title, startedAt: Date(),
                                         platform: configuration.platform, targetBundleID: configuration.targetBundleID)
            try manifest.write(to: directory)
            mic = try TrackPipeline(track: .me, url: directory.appending(path: RecordingManifest.micFile), sampleRate: configuration.sampleRate)
            remote = try TrackPipeline(track: .remote, url: directory.appending(path: RecordingManifest.remoteFile), sampleRate: configuration.sampleRate)
        } catch let error as RecorderError {
            throw error
        } catch {
            throw RecorderError.fileSystem(error.localizedDescription)
        }
        timeline = RecordingTimeline(startedAt: HostTime.now)
    }

    private func begin() throws {
        do {
            try startTap()
        } catch let error as CoreAudioError {
            throw RecorderError.systemAudioCaptureUnavailable(error)
        }
        do {
            if configuration.captureMicrophone { try startMicrophone() }
        } catch let error as CoreAudioError {
            stopCaptures()
            throw RecorderError.microphoneCaptureFailed(error)
        } catch {
            stopCaptures()
            throw error
        }
        let queue = listenerQueue
        do {
            systemListeners = [
                try PropertyListener(systemObject, kAudioHardwarePropertyDefaultInputDevice, queue: queue) { [weak self] in
                    Task { await self?.restartMicrophone(reason: "default input changed") }
                },
                try PropertyListener(systemObject, kAudioHardwarePropertyProcessObjectList, queue: queue) { [weak self] in
                    Task { await self?.refreshTapProcesses() }
                },
            ]
        } catch {
            stopCaptures()
            throw error
        }
        timeline = RecordingTimeline(startedAt: HostTime.now)
        lastFlush = HostTime.now
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    public var state: RecordingTimeline.State { timeline.state }

    /// Recorded seconds so far, paused time excluded; what the capsule's clock shows.
    public var elapsed: TimeInterval { timeline.elapsed(at: HostTime.now) }

    public func pause() {
        timeline.pause(at: HostTime.now)
    }

    public func resume() {
        timeline.resume(at: HostTime.now)
    }

    /// Marks the current recording time and persists it immediately.
    @discardableResult
    public func markHighlight() throws -> Highlight {
        guard timeline.state != .stopped else { throw RecorderError.alreadyStopped }
        let time = timeline.elapsed(at: HostTime.now)
        manifest.highlights.append(time)
        try writeManifest()
        return Highlight(time: time)
    }

    /// Stops capture, finishes both files to the same length and returns what `MeetingLibrary.create` takes.
    public func stop() throws -> Recording {
        guard timeline.state != .stopped else { throw RecorderError.alreadyStopped }
        let now = HostTime.now
        stopCaptures()
        timeline.stop(at: now)
        drainTask?.cancel()
        drainTask = nil
        mic.drain(timeline)
        remote.drain(timeline)
        let duration = timeline.elapsed(at: now)
        do {
            try mic.finish(duration: duration)
            try remote.finish(duration: duration)
        } catch {
            throw RecorderError.fileSystem(error.localizedDescription)
        }
        manifest.duration = duration
        try writeManifest()
        continuation.finish()
        return manifest.recording(in: configuration.directory, duration: duration)
    }

    // MARK: Draining

    private func tick() {
        guard timeline.state != .stopped else { return }
        let now = HostTime.now
        mic.drain(timeline)
        remote.drain(timeline)
        for pipeline in [mic, remote] {
            let dropped = pipeline.ring.takeDroppedFrames()
            if dropped > 0 { continuation.yield(.audioDropped(pipeline.track, frames: dropped)) }
        }
        let remoteLevel = remote.takeLevel()
        continuation.yield(.levels(TrackLevels(me: mic.takeLevel(), remote: remoteLevel)))
        if now - lastFlush >= 1 {
            lastFlush = now
            let settled = timeline.elapsed(at: now) - Self.captureLatencyMargin
            mic.padSilence(upTo: settled)
            remote.padSilence(upTo: settled)
            do {
                try mic.writer.flush()
                try remote.writer.flush()
            } catch {
                continuation.yield(.writeFailed(error.localizedDescription))
            }
        }
        watchForStalls(now: now)
        watchForSilence(remoteLevel, now: now)
    }

    private func watchForStalls(now: Double) {
        guard timeline.state == .recording else { return }
        if configuration.captureMicrophone, isStalled(mic.ring, since: micStartedAt, now: now) {
            restartMicrophone(reason: "no microphone audio for \(Self.stallTimeout) s")
        }
        if isStalled(remote.ring, since: tapStartedAt, now: now) {
            stopTap()
            do {
                try startTap()
                continuation.yield(.captureRestarted(.remote, reason: "no tap audio for \(Self.stallTimeout) s"))
            } catch {
                tapStartedAt = now
                continuation.yield(.captureRestarted(.remote, reason: "rebuild failed: \(error)"))
            }
        }
    }

    /// Measured from the later of the last IO callback and the last (re)start, so a failing
    /// restart is retried every `stallTimeout` rather than on every tick.
    private func isStalled(_ ring: CaptureRing, since started: Double, now: Double) -> Bool {
        let last = ring.lastHostTime
        return now - max(started, last == 0 ? 0 : HostTime.seconds(last)) > Self.stallTimeout
    }

    private func watchForSilence(_ level: AudioLevel, now: Double) {
        guard level.peak == 0 else {
            remoteSilentSince = nil
            reportedSilence = false
            return
        }
        let since = remoteSilentSince ?? now
        remoteSilentSince = since
        guard !reportedSilence, now - since > Self.silenceTimeout else { return }
        let playing = (try? AudioProcesses.list())?
            .contains { $0.ownerBundleID == configuration.targetBundleID && $0.isRunningOutput } ?? false
        if playing {
            reportedSilence = true
            continuation.yield(.remoteSilentWhileTargetPlaying)
        } else {
            remoteSilentSince = now
        }
    }

    // MARK: Captures

    private func startTap() throws {
        let processes = try AudioProcesses.objects(ownedBy: configuration.targetBundleID)
        let tap = try ProcessTap(processes: processes)
        let io = try DeviceIO(device: tap.aggregateID, ring: remote.ring)
        try io.start()
        self.tap = tap
        tapIO = io
        tapStartedAt = HostTime.now
    }

    private func stopTap() {
        tapIO?.stop()
        tapIO = nil
        tap?.destroy()
        tap = nil
    }

    private func refreshTapProcesses() {
        guard let tap, timeline.state != .stopped,
              let processes = try? AudioProcesses.objects(ownedBy: configuration.targetBundleID),
              processes != tap.processes else { return }
        do {
            try tap.setProcesses(processes)
            continuation.yield(.targetProcessesChanged(count: processes.count))
        } catch {
            continuation.yield(.captureRestarted(.remote, reason: "tap update failed: \(error)"))
        }
    }

    private func startMicrophone() throws {
        let device = try AudioDevices.defaultInput()
        let io = try DeviceIO(device: device, ring: mic.ring)
        try io.start()
        micIO = io
        micStartedAt = HostTime.now
        micListeners = [
            try PropertyListener(device, kAudioDevicePropertyNominalSampleRate, queue: listenerQueue) { [weak self] in
                Task { await self?.restartMicrophone(reason: "sample rate changed") }
            },
        ]
    }

    private func restartMicrophone(reason: String) {
        guard configuration.captureMicrophone, timeline.state != .stopped else { return }
        micListeners.forEach { $0.remove() }
        micIO?.stop()
        micIO = nil
        micStartedAt = HostTime.now
        do {
            try startMicrophone()
            continuation.yield(.microphoneSwitched(deviceName: AudioDevices.name(micIO!.device)))
        } catch {
            continuation.yield(.captureRestarted(.me, reason: "\(reason); restart failed: \(error)"))
        }
    }

    private func stopCaptures() {
        systemListeners.forEach { $0.remove() }
        micListeners.forEach { $0.remove() }
        micIO?.stop()
        micIO = nil
        stopTap()
    }

    private func writeManifest() throws {
        do {
            try manifest.write(to: configuration.directory)
        } catch {
            throw RecorderError.fileSystem(error.localizedDescription)
        }
    }
}
