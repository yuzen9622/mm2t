import AVFoundation
import os
import Foundation
import MM2TCore
@testable import MM2TDiarization

/// One folder per test process, removed when it exits; one a crashed run left behind is swept an hour later.
let testScratch: URL = {
    let files = FileManager.default
    let parent = files.temporaryDirectory.appending(path: "mm2t-test-runs")
    for old in (try? files.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey])) ?? []
    where (try? old.resourceValues(forKeys: [.creationDateKey]).creationDate).flatMap { $0 } ?? .distantFuture
        < Date(timeIntervalSinceNow: -3600) {
        try? files.removeItem(at: old)
    }
    atexit { try? FileManager.default.removeItem(at: testScratch) }
    return parent.appending(path: UUID().uuidString)
}()

func temporaryDirectory() throws -> URL {
    let url = testScratch.appending(path: "mm2t-diarization-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func segment(_ cluster: String, _ start: TimeInterval, _ end: TimeInterval) -> Diarization.Segment {
    .init(cluster: ClusterID(cluster), range: TimeRange(start: start, end: end))
}

/// Writes `channels` (one array per channel, equal length) as a file in `settings`' format.
func writeAudio(_ channels: [[Float]], sampleRate: Double, to url: URL, settings: [String: Any]) throws {
    let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count))!
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let block = 1 << 16
    for start in stride(from: 0, to: channels[0].count, by: block) {
        let count = min(block, channels[0].count - start)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer {
                buffer.floatChannelData![index].update(from: $0.baseAddress!.advanced(by: start), count: count)
            }
        }
        try file.write(from: buffer)
    }
}

func wavSettings(sampleRate: Double, channels: Int, float: Bool) -> [String: Any] {
    [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: float ? 32 : 16,
        AVLinearPCMIsFloatKey: float,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
}

/// Peak memory of this process so far, in MB.
func peakResidentMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

func currentFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : .nan
}

/// Highest `phys_footprint` seen while `body` runs, sampled every 20 ms on a separate thread.
func peakFootprintMB<T>(during body: () async throws -> T) async rethrows -> (value: T, peakMB: Double) {
    let peak = OSAllocatedUnfairLock(initialState: currentFootprintMB())
    let running = OSAllocatedUnfairLock(initialState: true)
    let sampler = Thread {
        while running.withLock({ $0 }) {
            let now = currentFootprintMB()
            peak.withLock { $0 = max($0, now) }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
    sampler.start()
    defer { running.withLock { $0 = false } }
    let value = try await body()
    let now = currentFootprintMB()
    return (value, peak.withLock { max($0, now) })
}
