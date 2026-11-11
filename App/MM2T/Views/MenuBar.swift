import MM2TApp
import MM2TCore
import SwiftUI

struct MenuBarLabel: View {
    let app: AppController?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .onAppear { WindowOpener.register(openWindow) }
            .onChange(of: app?.queue.pendingSetup ?? []) { _, issues in
                if !issues.isEmpty { openWindow(id: WindowID.onboarding) }
            }
    }

    private var symbol: String {
        switch app?.capture.state {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .prompting: "waveform.badge.exclamationmark"
        default: app?.queue.activeJob == nil ? "waveform" : "waveform.badge.ellipsis"
        }
    }
}

struct MenuBarContent: View {
    let app: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            captureSection
            if let job = app.queue.activeJob {
                Divider()
                Text(Copy.job(job.state))
            }
            if !app.recovered.isEmpty {
                Divider()
                Text("\(app.recovered.count) interrupted recordings were recovered.")
                Button("Show Meetings") { openWindow(id: WindowID.main) }
            }
            Divider()
            Button("Meetings…") { openWindow(id: WindowID.main) }
            Button("Setup…") { openWindow(id: WindowID.onboarding) }
            Button("Quit mm2t") { NSApp.terminate(nil) }
        }
        .padding()
        .frame(width: 300, alignment: .leading)
    }

    @ViewBuilder private var captureSection: some View {
        switch app.capture.state {
        case .recording(let target), .paused(let target):
            Text("Recording \(target.name)")
            HStack {
                if case .paused = app.capture.state {
                    Button("Resume") { Task { await app.capture.resume() } }
                } else {
                    Button("Pause") { Task { await app.capture.pause() } }
                }
                Button("Highlight") { Task { await app.capture.markHighlight() } }
                Button("Stop") { Task { await app.capture.stop() } }
            }
        case .prompting(let meeting):
            Text("\(meeting.platform.displayName) meeting")
            HStack {
                Button("Record") { Task { await app.capture.startPrompted() } }
                Button("Not This Time") { app.capture.dismiss() }
            }
        default:
            Button("Start Recording") {
                Task { await app.capture.startNow(title: String(localized: "Recording")) }
            }
            if !app.capture.state.isCapturing, app.capture.state != .idle {
                Text(Copy.capture(app.capture.state))
            }
        }
    }
}

extension Copy {
    static func capture(_ state: CaptureState) -> String {
        switch state {
        case .awaitingMicrophone: String(localized: "Waiting for microphone permission")
        case .starting: String(localized: "Starting…")
        case .stopping: String(localized: "Saving…")
        case .failed(let failure): Self.failure(failure)
        default: ""
        }
    }
}
