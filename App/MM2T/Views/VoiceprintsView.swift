import MM2TApp
import MM2TCore
import SwiftUI

struct VoiceprintsView: View {
    let model: VoiceprintsModel
    @State private var editing: PersonRow?
    @State private var newName = ""
    @State private var deleting: PersonRow?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: Text("People")) {}
            if model.rows.isEmpty {
                EmptyState(icon: "users", title: "Naming a speaker in a meeting saves their voiceprint on this Mac.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.rows) { person in
                            HStack(spacing: 12) {
                                Avatar(name: person.name, isNamed: true, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.name).font(Typo.bodyStrong)
                                    Text("\(person.voiceprintCount) voiceprints").font(Typo.caption).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                IconButton("Rename…", icon: "pencil") {
                                    newName = person.name
                                    editing = person
                                }
                                IconButton("Delete…", icon: "trash") { deleting = person }
                            }
                            .card()
                            .transition(.asymmetric(insertion: .offset(y: 10).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .motion(Motion.page, value: model.rows.map(\.id))
                }
            }
        }
        .task { await model.reload() }
        .alert("Rename", isPresented: .init(get: { editing != nil }, set: { if !$0 { editing = nil } }), presenting: editing) { person in
            TextField("Name", text: $newName)
            Button("Save") { Task { await model.rename(person.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this person?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { person in
            Button("Delete \(person.name) and Their Voiceprints", role: .destructive) { Task { await model.delete(person.id) } }
        } message: { _ in
            Text("Their voiceprints are removed from this Mac. Past meetings show the speaker's letter again.")
        }
    }
}
