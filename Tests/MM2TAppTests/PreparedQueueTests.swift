import Foundation
import MM2TCore
import Testing
@testable import MM2TApp

@MainActor @Suite struct PreparedQueueTests {
    @Test func finalizationOwnsTheMeetingUntilItCanBeRetried() async throws {
        let world = try World()
        let id = try await world.recordedMeeting(title: "To retry").id
        let other = try await world.recordedMeeting(title: "Prior job").id
        let priorGate = Gate<Bool>()
        let gate = Gate<Bool>()
        let queue = ProcessingQueue(makePipeline: { .needsSetup([]) }, makeLLM: { .needsSetup([]) })
        var finished = 0
        queue.onJobFinished = { finished += 1 }
        let priorJob = queue.enqueue(.process, on: other, finalize: { _ = await priorGate.wait() })
        let prior = try #require(priorJob)
        let firstJob = queue.enqueue(.process, on: id, finalize: { _ = await gate.wait() })
        let first = try #require(firstJob)
        #expect(queue.jobs[id] == .running(.transcribe))
        #expect(queue.enqueue(.process, on: id) == nil)
        queue.cancel(id)
        await gate.open(true)
        #expect(await eventually { !queue.isBusy(id) })
        #expect(finished == 1)
        let queued = try #require(queue.enqueue(.process, on: id))
        queue.cancel(id)
        #expect(finished == 2)
        let retry = try #require(queue.enqueue(.process, on: id))
        #expect(queue.jobs[id] == .queued)
        await priorGate.open(true)
        await prior.value
        await first.value
        await queued.value
        await retry.value
        #expect(queue.jobs[id] == .needsSetup([]))
        #expect(finished == 4)
    }

    @Test func pipelineFailureFinishesTheJobOnce() async throws {
        let id = try await World().recordedMeeting(title: "Failure").id
        let queue = ProcessingQueue(makePipeline: { throw CocoaError(.fileReadUnknown) }, makeLLM: { .needsSetup([]) })
        var finished = 0
        queue.onJobFinished = { finished += 1 }
        await queue.run(.process, on: id)
        guard case .failed = queue.jobs[id] else { Issue.record("expected pipeline failure"); return }
        #expect(finished == 1)
    }

    @Test func queuedPreparationIsRevalidatedBeforeSelectingItsProvider() async throws {
        let world = try World()
        let first = try await world.recordedMeeting(title: "First")
        let second = try await world.recordedMeeting(title: "Second")
        let setup = PipelineSetup(library: world.library, voiceprints: world.app.voiceprints,
                                  credentials: world.credentials, catalog: world.catalog)
        guard case .ready(let base) = try setup.build(world.app.settings.settings) else {
            Issue.record("expected a configured test pipeline")
            return
        }

        let blockingLLM = FakeLLM(), oldLLM = FakeLLM(), latestLLM = FakeLLM()
        let releaseFirst = Gate<Bool>()
        blockingLLM.holds.update { $0["cleanTranscript"] = releaseFirst }
        let current = Box(true)
        let checks = Box<[Bool]>([])
        let factoryCalls = Box(0)
        let latest = base.withLLM(latestLLM)
        let queue = ProcessingQueue(makePipeline: {
            factoryCalls.update { $0 += 1 }
            return .ready(latest)
        }, makeLLM: { .ready(latestLLM) })

        var finished = 0
        queue.onJobFinished = { finished += 1 }
        let processingFirst = Task {
            await queue.run(.regenerate, on: first.id, using: base.withLLM(blockingLLM))
        }
        #expect(await eventually { blockingLLM.calls.get.contains("cleanTranscript") })
        let processingSecond = Task {
            await queue.run(.regenerate, on: second.id, using: base.withLLM(oldLLM), whileValid: {
                let valid = current.get
                checks.update { $0.append(valid) }
                return valid
            })
        }
        #expect(await eventually { queue.jobs[second.id] == .queued })
        #expect(checks.get.isEmpty, "provider validity is checked after the earlier job finishes, not when queued")
        #expect(oldLLM.calls.get.isEmpty && latestLLM.calls.get.isEmpty)
        current.set(false)
        await releaseFirst.open(true)
        await processingFirst.value
        await processingSecond.value

        #expect(finished == 2)
        #expect(queue.jobs[first.id] == .completed)
        #expect(queue.jobs[second.id] == .completed)
        #expect(checks.get == [false])
        #expect(factoryCalls.get == 1, "the invalidated prepared pipeline must be rebuilt from current settings")
        #expect(oldLLM.calls.get.isEmpty, "none of the queued meeting may be sent to the obsolete provider")
        #expect(Set(latestLLM.calls.get) == ["inferNames", "cleanTranscript", "digestPerPerson", "summarize"])
        let result = try await world.library.meeting(second.id)
        #expect(result.status == .completed)
        #expect(result.outputs.cleaned != nil && result.outputs.digests != nil && result.outputs.summary != nil)
    }
}
