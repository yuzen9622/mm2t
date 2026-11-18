import MM2TApp
import SwiftUI

struct AssistantToolbar: View {
    let model: AssistantModel
    @State private var deleteID: UUID?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PillButton("New conversation", icon: "plus") { model.newConversation() }
                if let store = model.conversations {
                    Menu {
                        ForEach(store.records) { record in
                            Button(record.title) { model.openConversation(record.id) }
                        }
                    } label: { Text("Conversation history") }
                    .menuStyle(.borderlessButton).fixedSize()
                    if !model.turns.isEmpty {
                        Button("Delete conversation", role: .destructive) { deleteID = model.conversationID }
                            .buttonStyle(.plain).foregroundStyle(Palette.muted)
                    }
                }
                Spacer()
                IconButton("Personalized memory", icon: "adjustments-horizontal") {
                    MainNavigation.shared.settingsSection = .assistant
                    MainNavigation.shared.settingsOpen = true
                }
            }
            if let message = model.storageError ?? error {
                HStack {
                    Text(verbatim: message).font(Typo.caption).foregroundStyle(Palette.danger)
                    Button("Retry") { model.save() }
                }
            }
        }
        .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
            Button("Delete", role: .destructive) {
                guard let id = deleteID else { return }
                model.newConversation()
                do { try model.conversations?.delete(id) } catch { self.error = String(describing: error) }
                deleteID = nil
            }
        } message: { Text("This removes the saved conversation from this Mac. Meeting records and preferences are kept.") }
    }
}

private struct MemoryTextField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Preference", text: $text,
                  prompt: Text("For example: List meeting decisions first, then action items.")
                    .foregroundColor(Palette.secondary), axis: .vertical)
            .textFieldStyle(.plain)
            .font(Typo.body)
            .lineLimit(3, reservesSpace: true)
            .focused($focused)
            .padding(12)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
    }
}

struct AssistantPreferenceProposal: View {
    let model: AssistantModel
    let turn: AssistantTurn
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remember this preference?").font(Typo.bodyStrong)
            MemoryTextField(text: $text)
            HStack {
                PillButton("Save", kind: .primary) { model.confirmPreference(turn: turn.id, text: text) }
                    .disabled(model.isRunning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 300)
                PillButton("Dismiss") { model.dismissPreference(turn: turn.id) }
            }
        }.card()
            .onAppear { text = turn.memoryProposal ?? "" }
    }
}

struct AssistantMemorySettings: View {
    let preferences: AssistantPreferences
    let conversations: AssistantConversations
    @State private var editing: UUID?
    @State private var text = ""
    @State private var scope = ""
    @State private var error: String?
    @State private var deleting: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Use my preferences in replies", isOn: Binding(get: { preferences.enabled }, set: { value in
                perform { try preferences.setEnabled(value) }
            }))
            if let message = preferences.error ?? error {
                Text(verbatim: message).font(Typo.caption).foregroundStyle(Palette.danger)
            }
            ForEach(preferences.items) { item in
                HStack(alignment: .top) {
                    Toggle(isOn: Binding(get: { item.enabled }, set: { value in
                        perform { try preferences.put(id: item.id, text: item.text, scope: item.scope, enabled: value) }
                    })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: item.text)
                            if !item.scope.isEmpty { Text(verbatim: item.scope).font(Typo.caption).foregroundStyle(Palette.muted) }
                        }
                    }
                    PillButton("Edit") { editing = item.id; text = item.text; scope = item.scope }
                    PillButton("Delete", kind: .danger) { deleting = item.id }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                MemoryTextField(text: $text)
                FieldBox {
                    TextField("Project or topic (optional)", text: $scope)
                }
            }
            HStack {
                Spacer()
                if editing != nil { PillButton("Cancel") { editing = nil; text = ""; scope = "" } }
                PillButton("Save", kind: .primary) {
                    perform {
                        try preferences.put(id: editing, text: text, scope: scope)
                        editing = nil; text = ""; scope = ""
                    }
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 300)
            }
            if !conversations.errors.isEmpty {
                Text("Some conversations could not be loaded. Their files have been preserved.")
                    .font(Typo.caption).foregroundStyle(Palette.danger)
            }
        }
        .confirmationDialog("Delete this preference?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = deleting { perform { try preferences.delete(id) } }
                deleting = nil
            }
        } message: { Text("It will no longer be used in future requests. Earlier messages may still show it in conversation history.") }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = String(describing: error) }
    }
}
