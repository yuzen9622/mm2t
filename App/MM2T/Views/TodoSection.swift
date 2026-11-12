import AppKit
import MM2TApp
import SwiftUI

/// A meeting's to-dos: check them off, and send them to the Reminders app, where completion then
/// follows in both directions.
struct TodoSection: View {
    let title: String
    let rows: [SourcedRow]
    let model: MeetingDetailModel

    private var access: RemindersAccess? { model.remindersAccess }
    private var unlinked: [SourcedRow] { rows.filter { !model.isInReminders($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(Typo.captionStrong).foregroundStyle(Palette.secondary)
                Spacer()
                if access != nil, access != .denied {
                    if unlinked.isEmpty {
                        Label("In Reminders", systemImage: "checkmark")
                            .font(Typo.caption).foregroundStyle(Palette.secondary)
                    } else {
                        PillButton("Add to Reminders", icon: "plus") { Task { await model.addToReminders() } }
                    }
                }
            }
            if access == .denied {
                HStack(spacing: 8) {
                    Text("mm2t can't use Reminders. Allow it in System Settings to add to-dos there.")
                        .font(Typo.caption).foregroundStyle(Palette.secondary)
                    Spacer()
                    PillButton("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                    }
                }
            }
            ForEach(rows) { row in
                TodoRowView(row: row, model: model, canAdd: access != nil && access != .denied)
            }
        }
        .card()
    }
}

private struct TodoRowView: View {
    let row: SourcedRow
    let model: MeetingDetailModel
    let canAdd: Bool
    @State private var hovering = false

    var body: some View {
        let done = model.isDone(row)
        HStack(alignment: .top, spacing: 10) {
            Button { model.toggleDone(row) } label: {
                ZStack {
                    Circle().strokeBorder(done ? Palette.orange : Palette.muted, lineWidth: 1.5)
                    if done {
                        Circle().fill(Palette.orange)
                        Icon("check", size: 11).foregroundStyle(.white)
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Circle())
            }
            .buttonStyle(Pressable())
            .accessibilityLabel(done ? "Mark as not done" : "Mark as done")
            if let name = row.speakerName { Avatar(name: name, isNamed: true) }
            Text(row.text)
                .strikethrough(done)
                .foregroundStyle(done ? Palette.muted : Palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if canAdd {
                if model.isInReminders(row) {
                    Icon("circle-check", size: 15).foregroundStyle(Palette.secondary).help("In Reminders")
                } else {
                    IconButton("Add to Reminders", icon: "plus") { Task { await model.addToReminders([row]) } }
                        .opacity(hovering ? 1 : 0)
                }
            }
            if let jump = row.jump {
                Button { model.jump(to: jump) } label: {
                    Text(MeetingPresentation.timestamp(jump.time)).font(Typo.caption).monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .motion(Motion.select, value: done)
    }
}
