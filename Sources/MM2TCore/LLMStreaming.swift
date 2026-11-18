import Foundation

public extension LLMProvider {
    func generateText(system: String, input: String) async throws -> String {
        try await rewrite(input, instruction: system)
    }
    func streamText(system: String, input: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await generateText(system: system, input: input)
                    try Task.checkCancellation()
                    continuation.yield(text)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
