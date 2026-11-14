import MM2TApp
import SwiftUI

struct VocabularyView: View {
    enum Filter: Hashable, CaseIterable { case all, learned, manual }

    let store: SettingsStore
    @State private var filter = Filter.all
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var pendingDelete: [String] = []
    @State private var editor: Editor?

    private struct Editor {
        let term: String?
    }

    private var terms: [String] {
        store.settings.vocabulary.reversed().filter { term in
            let matchesSource = filter == .all || store.settings.source(of: term) == (filter == .learned ? .learned : .manual)
            let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return matchesSource && (search.isEmpty || term.localizedStandardContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                SearchField(text: $query).frame(maxWidth: 240)
                PillButton("Add terms", icon: "plus", kind: .primary) { editor = Editor(term: nil) }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        Segmented(options: Filter.allCases, selection: $filter, title: title)
                        Picker("Source", selection: $filter) {
                            ForEach(Filter.allCases, id: \.self) { Text(title($0)).tag($0) }
                        }
                        .labelsHidden()
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 28, height: 28)
                        .help("When you save a transcript correction, mm2t automatically adds the names and terms you corrected to your vocabulary.")
                        .accessibilityLabel("When you save a transcript correction, mm2t automatically adds the names and terms you corrected to your vocabulary.")
                }
                selectionBar
            }
            .padding(.horizontal, 24)
            if terms.isEmpty {
                VStack(spacing: 12) {
                    EmptyState(icon: "book-2", title: !query.isEmpty ? "No results" : filter == .learned ? "Nothing learned yet" : "No terms yet")
                    if !query.isEmpty {
                        PillButton("Clear search") { query = "" }
                    } else if filter != .all {
                        PillButton("Show all terms") { filter = .all }
                    } else {
                        PillButton("Add terms", icon: "plus") { editor = Editor(term: nil) }
                    }
                }
                .padding(.bottom, 24)
            } else {
                FadingScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                        ForEach(terms, id: \.self) { term in
                            VocabularyTile(
                                term: term,
                                learned: store.settings.source(of: term) == .learned,
                                selected: selected.contains(term),
                                toggle: {
                                    if selected.contains(term) { selected.remove(term) }
                                    else { selected.insert(term) }
                                },
                                edit: { editor = Editor(term: term) },
                                remove: { pendingDelete = [term] }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .onChange(of: query) { _, _ in selected.removeAll() }
        .onChange(of: filter) { _, _ in selected.removeAll() }
        .onChange(of: store.settings.vocabulary) { _, vocabulary in selected.formIntersection(vocabulary) }
        .disabled(editor != nil)
        .accessibilityHidden(editor != nil)
        .overlay {
            if let editor {
                ZStack {
                    Color.black.opacity(0.28)
                        .onTapGesture { self.editor = nil }
                    VocabularyEditor(store: store, term: editor.term) { self.editor = nil }
                        .background(Palette.window, in: RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
                        .padding(16)
                }
            }
        }
        .confirmationDialog("Delete \(pendingDelete.count) terms?", isPresented: Binding(
            get: { !pendingDelete.isEmpty },
            set: { if !$0 { pendingDelete = [] } }
        ), titleVisibility: .visible) {
            Button("Delete \(pendingDelete.count) terms", role: .destructive) {
                store.settings.removeVocabulary(pendingDelete)
                selected.subtract(pendingDelete)
                pendingDelete = []
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("This cannot be undone. Deleted learned terms will not be learned again automatically. Existing transcripts are not changed.")
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Button {
                if selected.count == terms.count { selected.removeAll() }
                else { selected = Set(terms) }
            } label: {
                Image(systemName: selected.isEmpty ? "square" : selected.count == terms.count ? "checkmark.square.fill" : "minus.square.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(selected.isEmpty ? Palette.secondary : Palette.orange)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(terms.isEmpty)
            .accessibilityLabel("Select all results")
            .accessibilityValue(selected.isEmpty ? Text("None selected") : Text("\(selected.count) selected"))
            if selected.isEmpty {
                Text("\(terms.count) terms").font(Typo.caption).foregroundStyle(Palette.secondary)
            } else {
                Text("\(selected.count) selected").font(Typo.captionStrong)
            }
            Spacer(minLength: 0)
            if !selected.isEmpty {
                PillButton("Deselect all") { selected.removeAll() }
                PillButton("Delete", icon: "trash", kind: .danger) {
                    pendingDelete = terms.filter { selected.contains($0) }
                }
            }
        }
        .frame(height: 38)
    }

    private func title(_ filter: Filter) -> String {
        let settings = store.settings
        switch filter {
        case .all: return String(localized: "All \(settings.vocabulary.count)")
        case .learned: return String(localized: "Learned from corrections \(settings.learnedVocabulary.count)")
        case .manual: return String(localized: "Manually added \(settings.vocabulary.count - settings.learnedVocabulary.count)")
        }
    }
}

private struct VocabularyTile: View {
    let term: String
    let learned: Bool
    let selected: Bool
    let toggle: () -> Void
    let edit: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    private var source: LocalizedStringKey { learned ? "Learned from corrections" : "Manually added" }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? Palette.orange : Palette.muted)
                    Text(verbatim: term)
                        .font(Typo.bodyStrong)
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: term))
            .accessibilityLabel(Text(verbatim: term))
            .accessibilityValue(selected ? Text("Selected") : Text("Not selected"))
            Image(systemName: learned ? "sparkles" : "text.cursor")
                .font(.system(size: 11))
                .foregroundStyle(learned ? Palette.orange.opacity(0.75) : Palette.muted)
                .frame(width: 14)
                .help(Text(source))
                .accessibilityLabel(source)
            IconButton("Edit", icon: "pencil", action: edit)
                .opacity(hovering ? 1 : 0.55)
                .padding(.trailing, 4)
        }
        .frame(minHeight: 48)
        .background(selected ? Palette.orangeSoft : hovering ? Palette.hover : Palette.tonal,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .motion(Motion.select, value: selected)
        .contextMenu {
            Button("Edit", action: edit)
            Button("Delete…", role: .destructive, action: remove)
        }
    }
}

private struct VocabularyEditor: View {
    let store: SettingsStore
    let term: String?
    let dismiss: () -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(store: SettingsStore, term: String?, dismiss: @escaping () -> Void) {
        self.store = store
        self.term = term
        self.dismiss = dismiss
        _draft = State(initialValue: term ?? "")
    }

    private var cleaned: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var splits: Bool { cleaned.contains { $0.isNewline || $0 == "," || $0 == "，" } }
    private var valid: Bool {
        guard !cleaned.isEmpty else { return false }
        guard let term else { return cleaned.contains { !$0.isWhitespace && $0 != "," && $0 != "，" } }
        guard !splits, store.settings.vocabulary.contains(term) else { return false }
        if cleaned == term { return true }
        var trial = store.settings
        return trial.renameVocabulary(term, to: cleaned)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(term == nil ? "Add terms" : "Edit term").font(Typo.heading)
            if term == nil {
                Text("Separate terms with commas or new lines.")
                    .font(Typo.caption).foregroundStyle(Palette.secondary)
                TextEditor(text: $draft)
                    .font(Typo.body).focused($focused)
                    .frame(height: 110)
                    .accessibilityLabel("Terms")
            } else {
                FieldBox {
                    TextField("Term", text: $draft).focused($focused).onSubmit(save)
                }
                if !cleaned.isEmpty && !valid {
                    Text(splits ? "One term at a time" : "Already in your vocabulary")
                        .font(Typo.caption).foregroundStyle(Palette.danger)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(term == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func save() {
        guard valid else { return }
        if let term { store.settings.renameVocabulary(term, to: cleaned) }
        else { store.settings.addVocabulary(draft, source: .manual) }
        dismiss()
    }
}
