import Testing
import MM2TProviders
@testable import MM2TLocal

@Suite struct AssistantGrammarTests {
    @Test func iterativeDecisionUsesSupportedGrammar() throws {
        let grammar = try Grammar.gbnf(for: AssistantGeneration.decisionSchema)
        #expect(grammar.contains("query_actions"))
        #expect(grammar.contains("read_meeting"))
        #expect(grammar.contains("cursor"))
    }
    @Test func supportsPlanningBoolean() throws {
        let schema = JSON.dict([("type", .text("object")), ("properties", .dict([
            ("needsMeetings", .dict([("type", .text("boolean"))])),
        ]))])
        let grammar = try Grammar.gbnf(for: schema)
        #expect(grammar.contains(#"("true" | "false")"#))
    }
}
