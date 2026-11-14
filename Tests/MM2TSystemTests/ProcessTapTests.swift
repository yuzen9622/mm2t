import CoreAudio
import Foundation
import Testing
@testable import MM2TSystem

@Suite struct ProcessTapTests {
    private func process(_ id: AudioObjectID, owner: String?, bundle: String? = nil, running: Bool = true) -> AudioProcess {
        AudioProcess(objectID: id, identity: ProcessIdentity(pid: Int32(id), bundleID: bundle ?? owner, executablePath: nil),
                     ownerBundleID: owner, isRunningInput: false, isRunningOutput: running)
    }

    @Test func systemCaptureExcludesTheRelayButKeepsOriginalProducers() {
        let clients = [process(1, owner: "dev.mm2t.app"), process(2, owner: "com.finetuneapp.FineTune", running: false),
                       process(3, owner: "com.google.Chrome"), process(4, owner: "com.openai.codex"),
                       process(5, owner: nil), process(6, owner: "com.finetuneapp.FineTune", bundle: "relay.helper")]
        #expect(TapScope.recording(targetBundleID: nil, ownBundleID: "dev.mm2t.app", processes: clients) == .allExcept([1, 2, 6]))
        #expect(TapScope.recording(targetBundleID: "com.google.Chrome", ownBundleID: "dev.mm2t.app", processes: clients) == .only([3]))
        // An explicit request for the processed relay output remains possible.
        #expect(TapScope.recording(targetBundleID: "com.finetuneapp.FineTune", ownBundleID: "dev.mm2t.app", processes: clients) == .only([2, 6]))
        // Command-line diagnostics have no owner bundle; unknown clients must still be captured.
        #expect(TapScope.recording(targetBundleID: nil, ownBundleID: nil, processes: clients) == .allExcept([2, 6]))
    }

    @Test func newlyStartedRelayIsExcludedOnProcessRefresh() {
        let original = [process(3, owner: "com.google.Chrome")]
        #expect(TapScope.recording(targetBundleID: nil, ownBundleID: "dev.mm2t.app", processes: original) == .allExcept([]))
        let updated = original + [process(9, owner: nil, bundle: "com.finetuneapp.FineTune")]
        #expect(TapScope.recording(targetBundleID: nil, ownBundleID: "dev.mm2t.app", processes: updated) == .allExcept([9]))
    }

    @Test func bothCaptureModesStayOnOneOutputStreamWhenProcessesChange() {
        let uuid = UUID()
        for scope in [TapScope.allExcept([11]), .only([21, 22]), .only([21, 23])] {
            let description = ProcessTap.description(scope, outputUID: "headphones", uuid: uuid)
            #expect(description.deviceUID == "headphones")
            #expect(description.stream == 0)
            #expect(description.uuid == uuid)
            #expect(description.processes == scope.processes)
            #expect(description.isPrivate)
            #expect(description.muteBehavior == .unmuted)
            if case .allExcept = scope { #expect(description.isExclusive) }
            else { #expect(!description.isExclusive) }
        }
    }

    @Test func planarStereoIsAveragedOnce() {
        let ring = CaptureRing()
        var left: [Float] = [0.2, 0.6, -0.8]
        var right: [Float] = [0.4, -0.2, 0.2]
        let buffers = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(buffers.unsafeMutablePointer) }
        left.withUnsafeMutableBytes { l in
            right.withUnsafeMutableBytes { r in
                buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
                buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
                ring.write(buffers.unsafePointer, hostTime: 1, sampleRate: 48_000)
            }
        }
        var result: [Float] = []
        ring.drain { _, samples in result += samples }
        #expect(result.count == 3)
        #expect(zip(result, [Float(0.3), 0.2, -0.3]).allSatisfy { abs($0 - $1) < 0.0001 })
    }
}
