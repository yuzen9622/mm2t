import Testing
import MM2TProviders
@testable import MM2TLocal

@Suite struct AssistantGrammarTests {
    @Test func supportsPlanningBoolean() throws {
        let schema = JSON.dict([("type", .text("object")), ("properties", .dict([
            ("needsMeetings", .dict([("type", .text("boolean"))])),
        ]))])
        let grammar = try Grammar.gbnf(for: schema)
        #expect(grammar.contains(#"("true" | "false")"#))
    }
}
