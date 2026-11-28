import AppKit
import MM2TApp
import SwiftUI

/// A meeting's to-dos: check them off, and send them to the Reminders app, where completion then
/// follows in both directions.
struct TodoSection: View {
    let title: String
    let rows: [SourcedRow]
    let model: MeetingDetailModel

    var highlight: String? = nil
    private var visible: [SourcedRow] { model.visibleActionItems(rows) }
    private var access: RemindersAccess? { model.remindersAccess }
    private var unlinked: [SourcedRow] { visible.filter { !model.isInReminders($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(Typo.captionStrong).foregroundStyle(Palette.secondary)
                Spacer()
                if let status = model.todos, let key = status.lastDeleted, rows.contains(where: { model.markKey($0) == key }) {
                    Button("Undo Delete") { status.set(.deleted, for: key, enabled: false) }.buttonStyle(.link)
                }
                if !visible.isEmpty, access != nil, access != .denied {
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
            ForEach(visible) { row in
                let content = TodoRowView(row: row, model: model, canAdd: access != nil && access != .denied)
                if let status = model.todos, let key = model.markKey(row) {
                    content.hidden().accessibilityHidden(true).padding(.vertical, 5).overlay {
                        List {
                            content.modifier(TodoActions(status: status, key: key, allowPersonal: !model.isPersonal(row)))
                                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                                .listRowBackground(highlight == key ? Palette.orange.opacity(0.2) : Color.clear)
                        }.listStyle(.plain).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 1)
                    }.id(key)
                } else { content }
            }
        }
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
            VStack(alignment: .leading, spacing: 4) {
                Text(row.text)
                    .strikethrough(done)
                    .foregroundStyle(done ? Palette.muted : Palette.text)
                    .onTapGesture { model.toggleDone(row) }
                    .fixedSize(horizontal: false, vertical: true)
                if let due = row.due {
                    Text(due.date, format: Date.FormatStyle(date: .abbreviated,
                        time: due.hasTime ? .shortened : .omitted,
                        timeZone: TimeZone(identifier: due.timeZoneIdentifier) ?? .current))
                        .font(Typo.caption).foregroundStyle(Palette.secondary)
                }
            }
            Spacer(minLength: 8)
            if let key = model.markKey(row), model.todos?.marks[key]?.contains(.pinned) == true { Image(systemName: "pin.fill").font(.caption) }
            if canAdd {
                if model.isInReminders(row) {
                    Icon("circle-check", size: 15).foregroundStyle(Palette.secondary).help("In Reminders")
                } else {
                    IconButton("Add to Reminders", icon: "plus") { Task { await model.addToReminders([row]) } }
                        .opacity(hovering ? 1 : 0)
                }
            }
            if let jump = row.jump {
                IconButton("Show in transcript", icon: "file-text") { model.jump(to: jump) }
            }
        }
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .motion(Motion.select, value: done)
    }
}

struct TodoActions: ViewModifier {
    let status: TodoStatus
    let key: String
    let allowPersonal: Bool
    @Environment(\.undoManager) private var undo
    private var pinned: Bool { status.marks[key]?.contains(.pinned) == true }
    private var pinIcon: String { pinned ? "pin.slash" : "pin" }
    private var pinTitle: LocalizedStringKey { pinned ? "Unpin" : "Pin" }

    private func togglePin() { status.set(.pinned, for: key, enabled: !pinned) }

    private func remove() {
        guard status.set(.deleted, for: key, enabled: true) else { return }
        let deletedKey = key
        undo?.registerUndo(withTarget: status) { target in
            MainActor.assumeIsolated { _ = target.set(.deleted, for: deletedKey, enabled: false) }
        }
        undo?.setActionName(String(localized: "Delete to-do"))
    }

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button(action: togglePin) { Image(systemName: pinIcon) }
                    .accessibilityLabel(pinTitle).tint(Palette.orange)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .accessibilityLabel("Delete to-do")
            }
            .contextMenu {
                Button(action: togglePin) { Label(pinTitle, systemImage: pinIcon) }
                if allowPersonal {
                    let personal = status.marks[key]?.contains(.personal) == true
                    Button(personal ? "Remove from My to-dos" : "Add to My to-dos") {
                        status.set(.personal, for: key, enabled: !personal)
                    }
                }
                Button(role: .destructive, action: remove) { Label("Delete to-do", systemImage: "trash") }
            }
    }
}
