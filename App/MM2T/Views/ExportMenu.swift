import AppKit
import MM2TApp
import MM2TCore
import SwiftUI
import UniformTypeIdentifiers

struct ExportMenu: View {
    let model: MeetingDetailModel
    @State private var open = false
    @State private var view = TranscriptView.raw
    @State private var format = Format.markdown
    @State private var includeTranslation = false
    @State private var failure: String?

    private enum Format: String {
        case markdown = "md", word = "docx", text = "txt", subtitles = "srt"

        var title: String {
            switch self {
            case .markdown: "Markdown"
            case .word: "Word"
            case .text: String(localized: "Plain text")
            case .subtitles: String(localized: "Subtitles")
            }
        }
    }

    private var formats: [Format] {
        view.document == nil ? [.markdown, .word, .text, .subtitles] : [.markdown, .word]
    }

    var body: some View {
        IconButton("Export", icon: "upload", isOn: open) {
            view = model.selectedView
            if !formats.contains(format) { format = .markdown }
            open = true
        }
        .disabled(model.meeting == nil)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Export").font(Typo.title)
                HStack {
                    Text("Content")
                    Spacer()
                    Dropdown(label: "Content", options: TranscriptView.allCases.map {
                        DropdownOption(id: $0, title: Copy.view(for: $0))
                    }, selection: $view)
                }
                HStack {
                    Text("File format")
                    Spacer()
                    Dropdown(label: "File format", options: formats.map {
                        DropdownOption(id: $0, title: $0.title, trailing: "." + $0.rawValue)
                    }, selection: $format)
                }
                if view == .cleaned, model.meeting?.currentTranslation != nil {
                    Toggle("Include translation", isOn: $includeTranslation)
                        .toggleStyle(SwitchStyle())
                        .accessibilityRepresentation { Toggle("Include translation", isOn: $includeTranslation).toggleStyle(.switch) }
                }
                HStack {
                    Spacer()
                    PillButton("Export…", icon: "download", kind: .primary, action: save)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .font(Typo.body)
            .padding(20)
            .frame(width: 320)
            .background(Palette.panel)
            .dropdownLayer()
            .onChange(of: view) { if !formats.contains(format) { format = .markdown } }
        }
        .alert("Couldn’t export file", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: { Text(failure ?? "") }
    }

    private func save() {
        let text = format == .subtitles ? model.subtitles(view, includeTranslation: includeTranslation)
            : model.export(view, as: format == .text ? .plainText : .markdown, includeTranslation: includeTranslation)
        guard let text else { return }
        open = false
        let panel = NSSavePanel()
        let ext = format.rawValue
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? UTType(importedAs: "org.mm2t." + ext)]
        let title = (model.meeting?.metadata.title ?? "mm2t").replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(title) - \(Copy.view(for: view)).\(ext)"
        WindowSharing.exclude(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = format == .word ? try MeetingMarkdown.wordData(text, style: .meetingDocument) : Data(text.utf8)
            try data.write(to: url, options: .atomic)
        } catch { failure = error.localizedDescription }
    }
}
