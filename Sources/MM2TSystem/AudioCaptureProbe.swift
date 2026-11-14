#if DEBUG
import AVFoundation
import CoreAudio
import Foundation
import MM2TCore

/// Local, microphone-free diagnostic: send a known signal through the actual output and record
/// its process tap. The saved reference distinguishes capture duplication from source reverb.
public enum AudioCaptureProbe {
    @MainActor
    public static func run(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rate = 48_000
        var samples = [Int16](repeating: 0, count: rate * 6)
        var random: UInt64 = 42
        for start in [rate, rate * 3] {
            for i in 0..<rate / 4 {
                random = random &* 6364136223846793005 &+ 1
                let window = sin(.pi * Double(i) / Double(rate / 4))
                samples[start + i] = Int16((Double(random >> 48) / 32768 - 1) * 1500 * window)
            }
        }
        let reference = directory.appending(path: "reference.wav")
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: samples), to: reference)
        let player = try AVAudioPlayer(contentsOf: reference)
        defer { player.stop() }
        player.prepareToPlay()
        // Register the playback client while the reference is still in its initial silence.
        player.play()
        try await Task.sleep(for: .milliseconds(200))
        player.pause()
        let output = try AudioDevices.defaultOutput()
        let processes = try AudioProcesses.list()
        let own = processes.filter { $0.identity.pid == ProcessInfo.processInfo.processIdentifier }.map(\.objectID)
        guard !own.isEmpty else { throw CoreAudioError(operation: "find diagnostic playback process", status: -1) }
        var report: [String: Any] = [
            "output": AudioDevices.name(output),
            "processes": processes.map { ["pid": String($0.identity.pid), "owner": $0.ownerBundleID ?? "", "output": String($0.isRunningOutput)] },
        ]
        // The third pass uses the production exclusion policy, but deliberately retains this
        // diagnostic's own generated signal. Each pass refreshes the process list.
        for name in ["own", "global", "filtered"] {
            let current = try AudioProcesses.list()
            let scope: TapScope = switch name {
            case "own": .only(current.filter { $0.identity.pid == ProcessInfo.processInfo.processIdentifier }.map(\.objectID))
            case "global": .allExcept([])
            default: .recording(targetBundleID: nil, ownBundleID: nil, processes: current)
            }
            report["\(name)_process_ids"] = scope.processes
            let tap = try ProcessTap(scope: scope, outputDevice: output)
            let pipeline = try TrackPipeline(track: .remote, url: directory.appending(path: "\(name).wav"), sampleRate: 16_000)
            let io = try DeviceIO(device: tap.aggregateID, ring: pipeline.ring)
            try io.start()
            defer { io.stop(); tap.destroy() }
            let start = HostTime.now
            var timeline = RecordingTimeline(startedAt: start)
            player.currentTime = 0
            player.play()
            var sampledProcesses = false
            while HostTime.now - start < 6.5 {
                try await Task.sleep(for: .milliseconds(50))
                pipeline.drain(timeline)
                if !sampledProcesses, HostTime.now - start > 1.15 {
                    sampledProcesses = true
                    report["\(name)_active_outputs"] = (try? AudioProcesses.list())?
                        .filter(\.isRunningOutput).map { ["pid": String($0.identity.pid), "owner": $0.ownerBundleID ?? ""] } ?? []
                }
            }
            player.stop()
            io.stop()
            let end = HostTime.now
            timeline.stop(at: end)
            pipeline.drain(timeline)
            try pipeline.finish(duration: end - start)
            report["\(name)_dropped_frames"] = pipeline.ring.takeDroppedFrames()
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appending(path: "report.json"), options: .atomic)
    }
}
#endif
