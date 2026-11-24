import Foundation
import MM2TCore
import Testing
@testable import MM2TApp

@Test func whiteboardPromptFoldsLabelsAndOnlyCommandsCanEditDrawings() throws {
    let bounds: [String: Any] = ["x": 5.6, "y": -3.4, "width": 100.1, "height": 80.9]
    let drawings: [(String, [String: Any])] = [
        ("box", ["type": "rectangle", "boundElements": [["id": "label", "type": "text"]]]),
        ("label", ["type": "text", "containerId": "box", "text": "Wrapped\nlabel", "originalText": "Wrapped label"]),
        ("deleted", ["type": "text", "text": "Missing", "isDeleted": true]),
        ("free", ["type": "freedraw", "points": [[0, 0], [1, 2]]]),
        ("image", ["type": "image", "fileId": "private"]),
        ("pin", ["type": "embeddable", "link": "mm2t://component/poll"]),
    ]
    var elements: [String: String] = [:]
    for (id, fields) in drawings {
        elements[id] = String(decoding: try JSONSerialization.data(withJSONObject: bounds.merging(fields) { _, new in new }), as: UTF8.self)
    }
    let json = try JSONSerialization.data(withJSONObject: [
        "id": "board", "kind": "whiteboard", "title": "Sketch", "source": "command", "building": false,
        "updatedAt": "2026-01-01T00:00:00Z", "elements": elements,
    ])
    let component = try JSONDecoder().decode(CollabComponent.self, from: json)
    let fields = CollabModelWork.promptFields(component)
    let geometry: [String: CollabJSON] = ["x": .number(6), "y": .number(-3), "w": .number(100), "h": .number(81)]
    #expect(fields["elements"] == nil)
    #expect(fields["drawn"] == .array([
        .object(geometry.merging(["id": .string("box"), "type": .string("rectangle"), "text": .string("Wrapped label"), "inside": .string("box")]) { _, new in new }),
        .object(geometry.merging(["id": .string("free"), "type": .string("freedraw")]) { _, new in new }),
        .object(geometry.merging(["id": .string("image"), "type": .string("image")]) { _, new in new }),
        .object(geometry.merging(["id": .string("pin"), "type": .string("embeddable")]) { _, new in new }),
    ]))
    let edit = CollabOp.setElement(id: "board", elementId: "box", shape: .ellipse, text: nil, strokeColor: nil, backgroundColor: nil)
    var live = CollabGeneration(updating: component)
    var command = CollabGeneration(components: [component], newID: "new", source: .command)
    #expect(try live.accept(edit) == nil)
    #expect(try live.accept(.removeElement(id: "board", elementId: "box")) == nil)
    #expect(try command.accept(edit) == edit)
}
