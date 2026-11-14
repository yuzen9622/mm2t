import AppKit
import AVFoundation
import Foundation
import MM2TCore
import MM2TSystem

@MainActor
enum Probe {
    #if DEBUG
    /// Persist launch and failure status ourselves; LaunchServices stdout/stderr redirection can
    /// fail before the diagnostic process starts, leaving no useful error file.
    @MainActor
    static func echoSelfTest(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func status(_ state: String, error: String? = nil) throws {
            var report = ["status": state, "updatedAt": ISO8601DateFormatter().string(from: Date())]
            if let error { report["error"] = error }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appending(path: "status.json"), options: .atomic)
        }
        try status("running")
        do {
            try await AudioCaptureProbe.run(in: directory)
            try status("completed")
        } catch {
            try? status("failed", error: String(describing: error))
            throw error
        }
    }
    #endif

    static func permissions() {
        print("microphone           \(Permissions.microphone.rawValue)")
        print("system audio capture \(Permissions.systemAudio.rawValue)  (no public API; watch for remoteSilentWhileTargetPlaying while recording)")
        print("accessibility        \(Permissions.accessibility.rawValue)  (window titles)")
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for browser in BrowserScripting.scriptableBrowsers.sorted() {
            let state = running.contains(browser) ? Permissions.automation(of: browser).rawValue : "not running"
            print("automation \(browser.padding(toLength: 28, withPad: " ", startingAt: 0)) \(state)  (tab URL)")
        }
        print("process attribution  \(AudioProcesses.hasResponsibilityLookup ? "responsible-process lookup available" : "path only")")
        guard let app = AudioProcesses.responsibleApp(ofPID: getpid()), let bundle = Bundle(url: app) else {
            print("TCC attribution: unknown")
            return
        }
        print("TCC attributes this probe to \(bundle.bundleIdentifier ?? "?") at \(app.path)")
        for key in ["NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription", "NSAppleEventsUsageDescription"] {
            let present = bundle.object(forInfoDictionaryKey: key) != nil
            print("  \(key.padding(toLength: 31, withPad: " ", startingAt: 0)) \(present ? "present" : "MISSING: macOS refuses this permission without prompting")")
        }
        if bundle.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") == nil {
            print("  run `mm2t-probe make-app` and launch the probe through the app it builds")
        }
    }

    /// Asks for every permission the recorder and signal sources use; each shows the system prompt
    /// once. Run inside the bundle `make-app` builds, so the prompts name the probe.
    static func requestPermissions() async {
        print("microphone: \(await Permissions.requestMicrophone() ? "granted" : "denied")")
        Permissions.requestAccessibility()
        print("accessibility: prompt shown if not yet trusted; re-run `permissions` after granting")
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for browser in BrowserScripting.scriptableBrowsers.sorted() where running.contains(browser) {
            let state = await Task.detached { Permissions.requestAutomation(of: browser) }.value
            print("automation \(browser): \(state.rawValue)")
        }
        print("system audio: macOS asks on the first recording (run tap-selftest)")
    }

    /// Wraps this binary in an app bundle carrying the usage-description keys, ad-hoc signed, so
    /// TCC attributes permissions to the probe instead of refusing them for the terminal.
    static func makeApp(at directory: URL) throws {
        let app = directory.appending(path: "MM2T Probe.app")
        let files = FileManager.default
        try? files.removeItem(at: app)
        try files.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.mm2t.probe",
            "CFBundleName": "MM2T Probe",
            "CFBundleExecutable": "mm2t-probe",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1",
            "LSMinimumSystemVersion": "14.2",
            "LSUIElement": true,
            "NSMicrophoneUsageDescription": "mm2t-probe records your microphone to verify the recorder.",
            "NSAudioCaptureUsageDescription": "mm2t-probe records one app's audio to verify the recorder.",
            "NSAppleEventsUsageDescription": "mm2t-probe reads the active browser tab's URL to verify meeting detection.",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        try files.copyItem(at: URL(filePath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath(),
                           to: app.appending(path: "Contents/MacOS/mm2t-probe"))
        let sign = Process()
        sign.executableURL = URL(filePath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        print("built \(app.path)")
        print("run subcommands through it, with output in this terminal:")
        print("  open -n -W --stdout $(tty) --stderr $(tty) \"\(app.path)\" --args permissions")
    }

    static func processes(all: Bool) throws {
        let processes = try AudioProcesses.list().sorted { ($0.ownerBundleID ?? "~", $0.identity.pid) < ($1.ownerBundleID ?? "~", $1.identity.pid) }
        print("object  pid     in  out  owner app                              process bundle id")
        for process in processes where all || process.ownerBundleID.map({ !$0.hasPrefix("com.apple.") }) ?? false || process.isRunningInput || process.isRunningOutput {
            print([
                String(process.objectID).padding(toLength: 7, withPad: " ", startingAt: 0),
                String(process.identity.pid).padding(toLength: 7, withPad: " ", startingAt: 0),
                (process.isRunningInput ? "in" : "-").padding(toLength: 3, withPad: " ", startingAt: 0),
                (process.isRunningOutput ? "out" : "-").padding(toLength: 4, withPad: " ", startingAt: 0),
                (process.ownerBundleID ?? "?").padding(toLength: 38, withPad: " ", startingAt: 0),
                process.identity.bundleID ?? "-",
            ].joined(separator: " "))
        }
        print("\nrecordable targets: " + Set(processes.compactMap(\.ownerBundleID)).sorted().joined(separator: ", "))
    }

    static func signals(seconds: Double) async throws {
        print("accessibility: \(Permissions.accessibility.rawValue); tab URLs need Automation per browser (see `permissions`)")
        var current: DetectedMeeting?
        var last: SystemSignals?
        let monitor = SystemSignalMonitor()
        let start = Date()
        monitor.start { signals, _ in
            let (next, events) = MeetingDetector.evaluate(signals, current: current)
            current = next
            let stamp = String(format: "%6.1f", Date().timeIntervalSince(start))
            if signals != last {
                last = signals
                print("\(stamp) mic=\(signals.micBundleIDs.sorted()) front=\(signals.frontmostBundleID ?? "-") "
                      + "title=\(signals.frontmostWindowTitle.map { "\"\($0)\"" } ?? "-") url=\(signals.browserURL?.absoluteString ?? "-")")
            }
            for event in events {
                switch event {
                case .detected(let meeting): print("\(stamp) EVENT detected \(meeting.platform) \(meeting.client) target=\(meeting.bundleID)")
                case .ended(let meeting): print("\(stamp) EVENT ended \(meeting.platform) target=\(meeting.bundleID)")
                }
            }
        }
        try await Task.sleep(for: .seconds(seconds))
        monitor.stop()
    }

    /// Under the home folder, since an app launched with `open` runs with `/` as its directory.
    static func defaultDirectory() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "mm2t-probe/\(stamp)")
    }

    static func resolveApp(_ name: String) -> String {
        let apps = NSWorkspace.shared.runningApplications
        if let app = apps.first(where: { $0.bundleIdentifier == name || $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }),
           let id = app.bundleIdentifier {
            return id
        }
        return name
    }

    static func record(app: String, seconds: Double, directory: URL, pauses: [(Double, Double)],
                       highlights: [Double], microphone: Bool) async throws {
        let target = resolveApp(app)
        let processes = try AudioProcesses.list().filter { $0.ownerBundleID == target }
        print("target \(target): \(processes.count) audio process(es) \(processes.map(\.identity.pid))")
        if processes.isEmpty { print("  (none yet; the tap picks them up when the app starts audio)") }
        let recorder = try await AudioRecorder.start(RecorderConfiguration(
            targetBundleID: target, directory: directory, title: "probe \(target)", captureMicrophone: microphone))
        print("recording to \(directory.path)")
        let eventTask = Task { @MainActor in
            var lastPrint = Date.distantPast
            for await event in recorder.events {
                switch event {
                case .levels(let levels):
                    guard Date().timeIntervalSince(lastPrint) >= 0.5 else { continue }
                    lastPrint = Date()
                    let elapsed = await recorder.elapsed
                    let state = await recorder.state
                    print(String(format: "%6.1fs %@ me %@ %6.1f dB   remote %@ %6.1f dB", elapsed, state == .paused ? "PAUSED" : "      ",
                                 bar(levels.me), levels.me.rmsDBFS, bar(levels.remote), levels.remote.rmsDBFS))
                default:
                    print("event: \(event)")
                }
            }
        }
        let start = Date()
        var schedule: [(Double, String)] = highlights.map { ($0, "highlight") }
        for (pause, resume) in pauses { schedule += [(pause, "pause"), (resume, "resume")] }
        schedule.sort { $0.0 < $1.0 }
        while Date().timeIntervalSince(start) < seconds {
            let now = Date().timeIntervalSince(start)
            while let next = schedule.first, next.0 <= now {
                schedule.removeFirst()
                switch next.1 {
                case "pause": await recorder.pause(); print("-- paused at wall \(String(format: "%.1f", now)) s")
                case "resume": await recorder.resume(); print("-- resumed at wall \(String(format: "%.1f", now)) s")
                default:
                    let mark = try await recorder.markHighlight()
                    print("-- highlight at recording \(String(format: "%.2f", mark.time)) s")
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let recording = try await recorder.stop()
        eventTask.cancel()
        printRecording(recording)
        try analyze(directory, tones: [])
    }

    static func bar(_ level: AudioLevel) -> String {
        let filled = Int((level.meter() * 20).rounded())
        return "[" + String(repeating: "#", count: filled) + String(repeating: ".", count: 20 - filled) + "]"
    }

    static func printRecording(_ recording: Recording) {
        print("Recording")
        print("  mic       \(recording.micTrack.path)")
        print("  remote    \(recording.remoteTrack.path)")
        print("  duration  \(String(format: "%.2f", recording.metadata.duration)) s")
        print("  started   \(recording.metadata.startedAt)")
        print("  highlights \(recording.highlights.map { String(format: "%.2f", $0.time) })")
    }

    static func analyze(_ directory: URL, tones: [Double]) throws {
        let mic = try WAVFormat.read(directory.appending(path: RecordingManifest.micFile))
        let remote = try WAVFormat.read(directory.appending(path: RecordingManifest.remoteFile))
        print(String(format: "mic %.3f s, remote %.3f s at %d Hz (difference %.0f ms)",
                     mic.duration, remote.duration, mic.sampleRate, abs(mic.duration - remote.duration) * 1000))
        let header = "  sec    me dB  remote dB" + tones.map { String(format: "  %5.0fHz(remote)", $0) }.joined()
        print(header)
        let seconds = Int(max(mic.duration, remote.duration).rounded(.up))
        for second in 0 ..< seconds {
            let me = Analysis.window(mic, second: second), far = Analysis.window(remote, second: second)
            var line = String(format: "  %3d  %7.1f  %9.1f", second, Analysis.dB(me), Analysis.dB(far))
            for tone in tones { line += String(format: "  %14.1f", Analysis.toneDB(far, hz: tone, sampleRate: remote.sampleRate)) }
            print(line)
        }
    }

    static func recover(_ directory: URL) throws {
        print(RecordingRecovery.isInterrupted(directory) ? "session was interrupted; repairing" : "session ended cleanly; re-checking")
        printRecording(try RecordingRecovery.recover(directory))
    }

    static func tapSelfTest(seconds: Double, directory: URL? = nil, outputUID: String? = nil) async throws {
        guard seconds.isFinite, seconds >= 5 else { throw CocoaError(.validationMissingMandatoryProperty) }
        let work = directory ?? FileManager.default.temporaryDirectory.appending(path: "mm2t-tap-selftest-\(UUID().uuidString.prefix(8))")
        let bundleID = "dev.mm2t.probe.tone"
        let player = try ToneFixture.makeHelperApp(in: work, bundleID: bundleID)
        let tone = try ToneFixture.writeTone(work.appending(path: "tone440.wav"), hz: 440, seconds: seconds)
        let decoy = try ToneFixture.writeTone(work.appending(path: "tone1000.wav"), hz: 1000, seconds: seconds)
        print("helper: \(player.path)")
        let target = try ToneFixture.play(player, file: tone, outputUID: outputUID)
        guard target.isRunning else { throw CocoaError(.executableLoad) }
        let other = try ToneFixture.play(URL(filePath: "/usr/bin/afplay"), file: decoy)
        defer { target.terminate(); other.terminate() }
        try await Task.sleep(for: .milliseconds(700))
        let owned = try AudioProcesses.list().filter { $0.identity.pid == target.processIdentifier || $0.identity.pid == other.processIdentifier }
        for process in owned {
            print("pid \(process.identity.pid) bundle=\(process.identity.bundleID ?? "-") owner=\(process.ownerBundleID ?? "?") out=\(process.isRunningOutput)")
        }
        let directory = work.appending(path: "recording")
        try await record(app: bundleID, seconds: seconds - 1.5, directory: directory, pauses: [], highlights: [], microphone: false)
        let remote = try WAVFormat.read(directory.appending(path: RecordingManifest.remoteFile))
        let middle = Analysis.window(remote, second: 2)
        let wanted = Analysis.toneDB(middle, hz: 440, sampleRate: remote.sampleRate)
        let unwanted = Analysis.toneDB(middle, hz: 1000, sampleRate: remote.sampleRate)
        print(String(format: "remote second 2: 440 Hz %.1f dB, 1000 Hz %.1f dB", wanted, unwanted))
        if wanted > -40, wanted - unwanted > 30 {
            print("PASS: tapped the helper's tone and excluded the other process")
        } else if Analysis.dB(middle) < -150 {
            print("FAIL: remote track is digital silence (system audio capture permission is the usual cause)")
        } else {
            print("FAIL: tone separation not as expected")
        }
        print("files kept in \(work.path)")
        guard wanted > -40, wanted - unwanted > 30 else { throw CocoaError(.fileReadCorruptFile) }
    }
}

enum Analysis {
    static func window(_ audio: WAVAudio, second: Int) -> ArraySlice<Int16> {
        let start = min(audio.samples.count, second * audio.sampleRate)
        return audio.samples[start ..< min(audio.samples.count, start + audio.sampleRate)]
    }

    static func dB(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return -160 }
        let mean = samples.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) } / Double(samples.count)
        return mean > 0 ? max(-160, 10 * log10(mean)) : -160
    }

    /// Goertzel power at one frequency, scaled so a full-scale sine reads about 0 dB.
    static func toneDB(_ samples: ArraySlice<Int16>, hz: Double, sampleRate: Int) -> Double {
        guard !samples.isEmpty else { return -160 }
        let coefficient = 2 * cos(2 * Double.pi * hz / Double(sampleRate))
        var s1 = 0.0, s2 = 0.0
        for sample in samples {
            let s0 = Double(sample) / 32768 + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        let amplitude = 2 * power.squareRoot() / Double(samples.count)
        return amplitude > 0 ? max(-160, 20 * log10(amplitude)) : -160
    }
}

enum ToneFixture {
    /// `Tone.app/Contents/Helpers/Player.app/Contents/MacOS/mm2t-probe`: a helper nested in an app,
    /// like a browser's audio process, so the tap has to resolve it to the outer bundle id. The
    /// helper is a copy of this probe (`play-tone`), because macOS refuses to launch relocated
    /// copies of system binaries such as afplay.
    static func makeHelperApp(in directory: URL, bundleID: String) throws -> URL {
        let app = directory.appending(path: "Tone.app")
        let helper = app.appending(path: "Contents/Helpers/Player.app")
        let files = FileManager.default
        try files.createDirectory(at: helper.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try files.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try plist(bundleID: bundleID, executable: "Tone").write(to: app.appending(path: "Contents/Info.plist"))
        try plist(bundleID: bundleID + ".helper", executable: "mm2t-probe").write(to: helper.appending(path: "Contents/Info.plist"))
        let binary = helper.appending(path: "Contents/MacOS/mm2t-probe")
        try files.copyItem(at: URL(filePath: CommandLine.arguments[0]).standardizedFileURL, to: binary)
        return binary
    }

    private static func plist(bundleID: String, executable: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": bundleID, "CFBundleExecutable": executable, "CFBundlePackageType": "APPL",
        ], format: .xml, options: 0)
    }

    static func writeTone(_ url: URL, hz: Double, seconds: Double) throws -> URL {
        let rate = 48_000
        let writer = try WAVWriter(url: url, sampleRate: rate)
        let samples = (0 ..< Int(seconds * Double(rate))).map { Float(0.5 * sin(2 * Double.pi * hz * Double($0) / Double(rate))) }
        samples.withUnsafeBufferPointer { writer.append($0) }
        try writer.close()
        return url
    }

    static func play(_ binary: URL, file: URL, outputUID: String? = nil) throws -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = binary.lastPathComponent == "afplay" ? ["-v", "0.15", file.path] : ["play-tone", file.path]
        if let outputUID { process.arguments?.append(contentsOf: ["--output-uid", outputUID]) }
        try process.run()
        return process
    }

    /// The helper side of `tap-selftest`: plays a file quietly and exits when it ends.
    @MainActor
    static func playFile(_ path: String, outputUID: String? = nil) async throws {
        let player = try AVAudioPlayer(contentsOf: URL(filePath: path))
        if let outputUID { player.currentDevice = outputUID }
        player.volume = 0.15
        guard player.play() else { throw CocoaError(.fileReadUnknown) }
        if let outputUID, player.currentDevice != outputUID { throw CocoaError(.validationMissingMandatoryProperty) }
        print("tone output: \(player.currentDevice ?? "system default")")
        try await Task.sleep(for: .seconds(player.duration + 0.2))
    }
}
