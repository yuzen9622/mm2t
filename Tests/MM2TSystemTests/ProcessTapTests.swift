import CoreAudio
import Foundation
import Testing
@testable import MM2TSystem

@Suite struct ProcessTapTests {
    private func process(_ id: AudioObjectID, owner: String?, bundle: String? = nil, running: Bool = true, input: Bool = false) -> AudioProcess {
        AudioProcess(objectID: id, identity: ProcessIdentity(pid: Int32(id), bundleID: bundle ?? owner, executablePath: nil),
                     ownerBundleID: owner, isRunningInput: input, isRunningOutput: running)
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

    @Test func automaticLocksToZoomIncludingItsHelpersNotSpotify() {
        let zoom = "us.zoom.xos"
        let clients = [process(7, owner: zoom, bundle: "zoom.helper"), process(5, owner: "com.spotify.client"),
                       process(2, owner: zoom, input: true)]
        let result = TapScope.automatic(ownBundleID: "dev.mm2t.app", ignoring: [], locked: [], processes: clients)
        #expect(result.scope == .only([2, 7]))
        #expect(result.locked == [zoom])
    }

    @Test func automaticFallbackExcludesOwnAppRelaysAndMediaPlayers() {
        let clients = [process(8, owner: "com.apple.Music"), process(7, owner: "com.spotify.client"),
                       process(6, owner: nil, bundle: "com.finetuneapp.FineTune"),
                       process(3, owner: "dev.mm2t.app"), process(1, owner: "com.google.Chrome")]
        let result = TapScope.automatic(ownBundleID: "dev.mm2t.app", ignoring: [], locked: [], processes: clients)
        #expect(result.scope == .allExcept([3, 6, 7, 8]))
        #expect(result.locked.isEmpty)
    }

    @Test func automaticLockSurvivesMicrophoneReleaseAndCanAddAnotherCall() {
        let zoom = "us.zoom.xos", browser = "com.google.Chrome"
        let clients = [process(2, owner: zoom), process(7, owner: "com.spotify.client")]
        let result = TapScope.automatic(ownBundleID: nil, ignoring: [], locked: [zoom], processes: clients)
        #expect(result.scope == .only([2]))
        #expect(result.locked == [zoom])
        let another = TapScope.automatic(ownBundleID: nil, ignoring: [], locked: result.locked,
                                         processes: clients + [process(1, owner: browser, input: true)])
        #expect(another.scope == .only([1, 2]))
        #expect(another.locked == [zoom, browser])
    }

    @Test func automaticIgnoresIneligibleProcessesThatHoldTheMicrophone() {
        let own = "dev.mm2t.app", ignored = "us.zoom.xos"
        let clients = [process(1, owner: own, input: true), process(2, owner: ignored, input: true),
                       process(3, owner: "com.apple.VoiceMemos", input: true),
                       process(4, owner: "com.finetuneapp.FineTune", input: true), process(5, owner: nil, input: true)]
        let result = TapScope.automatic(ownBundleID: own, ignoring: [ignored], locked: [], processes: clients)
        #expect(result.locked.isEmpty)
        #expect(result.scope == .allExcept([1, 4]))
    }

    @Test func automaticTreatsABrowserAsOneMeetingApp() {
        let browser = "com.google.Chrome"
        let clients = [process(1, owner: browser, input: true), process(2, owner: browser, bundle: "chrome.helper"),
                       process(3, owner: "com.apple.Music")]
        let result = TapScope.automatic(ownBundleID: nil, ignoring: [], locked: [], processes: clients)
        #expect(result.scope == .only([1, 2]))
        #expect(result.locked == [browser])
    }

    @Test func recorderWithBothDevicesOffStillWritesEqualTracksAndStreamsSilence() async throws {
        let directory = try temporaryDirectory()
        let recorder = try await AudioRecorder.start(.init(systemAudio: .off, directory: directory,
                                                           title: "No I/O", captureMicrophone: false))
        let audio = await recorder.audioStream()
        try await Task.sleep(for: .milliseconds(2200))
        let recording = try await recorder.stop()
        let mic = try WAVFormat.frameCount(recording.micTrack)
        #expect(mic > 0)
        #expect(try WAVFormat.frameCount(recording.remoteTrack) == mic)
        #expect(WAVFormat.isDigitalSilence(recording.remoteTrack))
        var iterator = audio.makeAsyncIterator()
        let chunk = try #require(await iterator.next())
        #expect(!chunk.isEmpty && chunk.allSatisfy { $0 == 0 })
        for await event in recorder.events {
            if case .captureRestarted = event { Issue.record("No device should be restarted: \(event)") }
        }
    }

    @Test func recordingFollowsProcessesAcrossOutputDevices() {
        let uuid = UUID()
        for scope in [TapScope.allExcept([11]), .only([21, 22]), .only([21, 23])] {
            let description = ProcessTap.description(scope, uuid: uuid)
            #expect(description.deviceUID == nil)
            #expect(description.stream == nil)
            #expect(description.isMixdown && description.isMono)
            #expect(description.uuid == uuid)
            #expect(description.processes == scope.processes)
            #expect(description.isPrivate)
            #expect(description.muteBehavior == .unmuted)
            if case .allExcept = scope { #expect(description.isExclusive) }
            else { #expect(!description.isExclusive) }
        }
    }

    @Test func deviceDiagnosticsCanStillSelectOneOutputStream() {
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
