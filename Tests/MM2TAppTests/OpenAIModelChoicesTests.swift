import MM2TApp
import Testing

@Suite struct OpenAIModelChoicesTests {
    @Test func aSuccessfulListNeverOffersAnAbsentSavedModel() {
        let choices = OpenAIModelChoices(serverModels: ["current"], savedModel: "retired")
        #expect(choices.selectable == ["current"])
        #expect(choices.unavailable == "retired")

        let empty = OpenAIModelChoices(serverModels: [], savedModel: "retired")
        #expect(empty.selectable.isEmpty)
        #expect(empty.unavailable == "retired")

        let present = OpenAIModelChoices(serverModels: ["current"], savedModel: "current")
        #expect(present.selectable == ["current"])
        #expect(present.unavailable == nil)
    }

    @Test func aFailedListKeepsTheSavedModelSelectable() {
        let choices = OpenAIModelChoices(serverModels: nil, savedModel: "retired")
        #expect(choices.selectable == ["retired"])
        #expect(choices.unavailable == nil)
    }
}
