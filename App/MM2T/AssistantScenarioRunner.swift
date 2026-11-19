#if DEBUG
import AppKit
import MM2TApp
import MM2TCore

@MainActor
enum AssistantScenarioRunner {
    static var requested: Bool { UserDefaults.standard.string(forKey: "MM2TAssistantScenario") != nil }
    static var fixtureRoot: URL? {
        guard let path = UserDefaults.standard.string(forKey: "MM2TDataRoot") else { return nil }
        let root = URL(filePath: path).resolvingSymlinksInPath()
        guard (try? String(contentsOf: root.appending(path: "assistant-fixture.txt"), encoding: .utf8)) == "synthetic-assistant-fixture-v1" else { return nil }
        return root
    }

    static func fixtureDefaults() throws -> UserDefaults? {
        guard let root = fixtureRoot else { return nil }
        let runID = UserDefaults.standard.string(forKey: "MM2TFixtureRunID").flatMap(UUID.init(uuidString:)) ?? UUID()
        let defaults = UserDefaults(suiteName: "mm2t-assistant-fixture-\(runID.uuidString)")!
        var settings = try UserDefaults.standard.data(forKey: SettingsStore.key).map {
            try JSONDecoder().decode(AppSettings.self, from: $0)
        } ?? AppSettings()
        settings.hasCompletedOnboarding = !UserDefaults.standard.bool(forKey: "MM2TFixtureFirstRun")
        settings.hidesFromScreenCapture = false
        defaults.register(defaults: ["settings.v1": try JSONEncoder().encode(settings), "MM2TDataRoot": root.path])
        return defaults
    }

    static func run(_ app: AppController) async {
        let root = app.paths.root.resolvingSymlinksInPath()
        guard let scenarioPath = UserDefaults.standard.string(forKey: "MM2TAssistantScenario"),
              UserDefaults.standard.string(forKey: "MM2TDataRoot") != nil,
              let marker = try? String(contentsOf: root.appending(path: "assistant-fixture.txt"), encoding: .utf8),
              marker == "synthetic-assistant-fixture-v1" else {
            NSLog("Assistant scenario refused: an explicitly isolated synthetic fixture is required")
            NSApp.terminate(nil)
            return
        }
        let output = root.appending(path: "assistant-scenario-results.json")
        var records: [[String: Any]] = []
        do {
            let questions = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(filePath: scenarioPath)))
            try await app.searchIndex.rebuild(from: app.library.list())
            let assistant = app.makeAssistant()
            for question in questions {
                assistant.send(question)
                while assistant.isRunning { try await Task.sleep(for: .milliseconds(100)) }
                guard let turn = assistant.turns.last else { throw NSError(domain: "AssistantScenario", code: 1) }
                records.append([
                    "question": question, "answer": turn.answer.text, "state": String(describing: turn.state),
                    "steps": turn.steps.map { ["kind": $0.kind.rawValue, "reasoning": $0.reasoning, "coverage": $0.result?.coverage ?? ""] },
                    "sources": turn.citedSources.map { ["id": $0.id, "meeting": $0.meeting.description, "quote": $0.quote ?? ""] },
                    "memoryProposal": turn.memoryProposal ?? "",
                ])
                try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
                if case .needsSetup = turn.state { break }
                if case .failed = turn.state { break }
            }
            assistant.close()
        } catch {
            records.append(["blocker": String(describing: error)])
            try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        }
        NSApp.terminate(nil)
    }
}
#endif
