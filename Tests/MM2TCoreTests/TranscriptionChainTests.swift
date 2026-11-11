import Foundation
import Testing
@testable import MM2TCore

@Suite struct TranscriptionChainTests {
    let audio = URL(filePath: "/tmp/remote.caf")

    @Test func fallsThroughUnreachableSourcesInOrderAndReportsTheOneUsed() async throws {
        let selfHosted = FakeSTT(.unreachable), cloud = FakeSTT(.unreachable), local = FakeSTT()
        let chain = TranscriptionChain([.init(.selfHosted, selfHosted), .init(.cloud, cloud), .init(.local, local)])

        let result = try await chain.transcribe(audio: audio, hints: ["Alice"], labelSpeakers: true)

        #expect(result.source == .local)
        #expect(result.words == Script.remoteWords)
        #expect(selfHosted.calls.get.count == 1 && cloud.calls.get.count == 1)
        #expect(local.calls.get.first?.hints == ["Alice"])
        #expect(local.calls.get.first?.labelSpeakers == true)
    }

    @Test func usesTheFirstReachableSourceAndSkipsTheRest() async throws {
        let selfHosted = FakeSTT(), cloud = FakeSTT()
        let chain = TranscriptionChain([.init(.selfHosted, selfHosted), .init(.cloud, cloud)])

        #expect(try await chain.transcribe(audio: audio, hints: [], labelSpeakers: false).source == .selfHosted)
        #expect(cloud.calls.get.isEmpty)
    }

    @Test func membershipComesFromSettings() async throws {
        let cloud = FakeSTT(.unreachable), local = FakeSTT()
        let chain = TranscriptionChain([.init(.cloud, cloud)])

        await #expect(throws: TranscriptionError.unreachable("connection refused")) {
            try await chain.transcribe(audio: audio, hints: [], labelSpeakers: false)
        }
        #expect(local.calls.get.isEmpty)
    }

    @Test func aNonConnectionFailureStopsTheChain() async throws {
        let cloud = FakeSTT(.failed), local = FakeSTT()
        let chain = TranscriptionChain([.init(.cloud, cloud), .init(.local, local)])

        await #expect(throws: TranscriptionError.failed("invalid API key")) {
            try await chain.transcribe(audio: audio, hints: [], labelSpeakers: false)
        }
        #expect(local.calls.get.isEmpty)
    }
}
