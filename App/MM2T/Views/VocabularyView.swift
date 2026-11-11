import MM2TApp
import SwiftUI

struct VocabularyView: View {
    let store: SettingsStore
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: Text("Vocabulary")) {}
            TextEditor(text: $text)
                .font(Typo.body)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("One term per line").foregroundStyle(Palette.muted).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .card()
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .onAppear { text = store.settings.vocabulary.joined(separator: "\n") }
        .onChange(of: text) { _, text in store.settings.vocabulary = AppSettings.vocabulary(from: text) }
    }
}
