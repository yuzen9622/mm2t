import AppKit
import Foundation
import MM2TCore
import MM2TSystem

let usage = """
usage: mm2t-probe <command> [options]

  permissions                       Permission states and TCC attribution, without prompting.
  request-permissions               Prompt for microphone, Accessibility and Automation (run via make-app).
  make-app [DIR]                    Build "MM2T Probe.app" around this binary so macOS can grant it
                                    microphone and system audio access (default DIR: ~/Applications).
  processes [--all]                 Core Audio client processes resolved to their owning app
                                    (tappable targets). --all includes idle system daemons.
  signals [--seconds N]             Live SystemSignals and MeetingDetector events (default 60 s).
  record <app> [options]            Record the mic and <app>'s audio, printing levels.
      <app>                         Bundle id or the app's name as shown in the Dock.
      --seconds N                   Length in wall-clock seconds (default 10).
      --out DIR                     Empty or new directory (default ~/mm2t-probe/<time>).
      --pause-at S --resume-at S    Pause and resume at these wall-clock seconds (repeatable, paired).
      --highlight-at S              Mark a highlight at this wall-clock second (repeatable).
      --no-mic                      Remote track only; the mic track is written as silence.
  analyze DIR [--hz F ...]          Per-second levels of both tracks (and tone energy at F Hz).
  recover DIR                       Repair the tracks of an interrupted session and print the Recording.
  tap-selftest [--seconds N]        Plays a 440 Hz tone from a helper inside a throwaway app bundle and
                                    a 1000 Hz decoy from a separate process, taps only the app, and
                                    checks the remote track has the tone but not the decoy.
"""

let allArguments = Array(CommandLine.arguments.dropFirst())
guard let command = allArguments.first else {
    print(usage)
    exit(2)
}
let arguments = Array(allArguments.dropFirst())

@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

@MainActor func options(_ name: String) -> [Double] {
    arguments.indices.filter { arguments[$0] == name && $0 + 1 < arguments.count }.compactMap { Double(arguments[$0 + 1]) }
}

@MainActor func flag(_ name: String) -> Bool { arguments.contains(name) }

/// Runs `body` on the main actor while the main run loop services timers and listeners.
func runMain(_ body: @escaping @MainActor () async throws -> Void) -> Never {
    Task { @MainActor in
        do {
            try await body()
            exit(0)
        } catch {
            print("error: \(error)")
            if let error = error as? RecorderError, let pane = error.settingsPane {
                print("fix in System Settings: \(pane.url.absoluteString)")
            }
            exit(1)
        }
    }
    RunLoop.main.run()
    exit(0)
}

@available(macOS 14.2, *)
@MainActor func dispatch(_ command: String) throws {
    switch command {
    case "permissions":
        Probe.permissions()
    case "request-permissions":
        runMain { await Probe.requestPermissions() }
    case "make-app":
        let directory = arguments.first.map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")
        try Probe.makeApp(at: directory)
    case "processes":
        try Probe.processes(all: flag("--all"))
    case "signals":
        runMain { try await Probe.signals(seconds: option("--seconds").flatMap(Double.init) ?? 60) }
    case "record":
        guard let app = arguments.first, !app.hasPrefix("--") else {
            print(usage)
            exit(2)
        }
        let pauses = options("--pause-at"), resumes = options("--resume-at")
        runMain {
            try await Probe.record(
                app: app,
                seconds: option("--seconds").flatMap(Double.init) ?? 10,
                directory: option("--out").map { URL(filePath: $0) } ?? Probe.defaultDirectory(),
                pauses: Array(zip(pauses, resumes)),
                highlights: options("--highlight-at"),
                microphone: !flag("--no-mic"))
        }
    case "analyze":
        guard let path = arguments.first else {
            print(usage)
            exit(2)
        }
        try Probe.analyze(URL(filePath: path), tones: options("--hz"))
    case "recover":
        guard let path = arguments.first else {
            print(usage)
            exit(2)
        }
        try Probe.recover(URL(filePath: path))
    case "play-tone":
        guard let path = arguments.first else { exit(2) }
        runMain { try await ToneFixture.playFile(path) }
    case "tap-selftest":
        runMain { try await Probe.tapSelfTest(seconds: option("--seconds").flatMap(Double.init) ?? 6) }
    default:
        print(usage)
        exit(2)
    }
}

if #available(macOS 14.2, *) {
    try dispatch(command)
} else {
    print("mm2t-probe needs macOS 14.2 or newer (Core Audio process taps)")
    exit(1)
}
