import MM2TApp
import MM2TCore
import SwiftUI

struct FolderSidebarRow: View {
    let name: String
    let icon: String
    var expanded: Bool?
    var selected = false
    var accepting = false
    var received = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let expanded {
                    Icon("chevron-right", size: 10)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .transaction { if reduce { $0.animation = nil } }
                        .foregroundStyle(Palette.secondary)
                }
                Icon(received ? "check" : icon, size: expanded == nil ? 13 : 16)
                    .foregroundStyle(accepting || received || selected ? Palette.orange : Palette.secondary)
                    .scaleEffect(accepting && !reduce ? 1.12 : 1)
                Text(verbatim: name).lineLimit(1).truncationMode(.tail)
                    .font(expanded == nil ? Typo.caption : selected ? Typo.bodyStrong : Typo.body)
                    .foregroundStyle(selected || accepting ? Palette.text : Palette.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: expanded == nil ? 29 : 34)
            .background(accepting || received ? Palette.orangeSoft : selected ? Palette.selected : hovering ? Palette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay { RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Palette.orange.opacity(accepting ? 0.75 : 0), lineWidth: 1.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable()).onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering).motion(Motion.touch, value: accepting)
        .motion(Motion.select, value: selected).motion(Motion.reveal, value: received)
        .accessibilityLabel(Text(verbatim: name)).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct FolderNameDialog: View {
    let folder: MeetingFolders.Folder?
    let validate: (String) -> Bool
    let save: (String) -> Void
    let dismiss: () -> Void
    @State private var name: String

    init(folder: MeetingFolders.Folder? = nil, validate: @escaping (String) -> Bool = { _ in true }, save: @escaping (String) -> Void, dismiss: @escaping () -> Void) {
        self.folder = folder
        self.validate = validate
        self.save = save
        self.dismiss = dismiss
        _name = State(initialValue: folder?.name ?? "")
    }
    @FocusState private var focused: Bool
    private var cleaned: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(folder == nil ? LocalizedStringKey("New Folder") : "Edit Folder").font(Typo.title)
            FieldBox { TextField("Folder name", text: $name).focused($focused).onSubmit(submit) }
            HStack(spacing: 8) {
                Spacer()
                PillButton("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                PillButton(folder == nil ? "Create" : "Save", kind: .primary, action: submit).keyboardShortcut(.defaultAction).disabled(cleaned.isEmpty || !validate(cleaned))
            }
        }
        .padding(22).frame(width: 340)
        .background(Palette.window)
        .onAppear { focused = true }
    }
    private func submit() { if !cleaned.isEmpty && validate(cleaned) { save(cleaned) } }
}
