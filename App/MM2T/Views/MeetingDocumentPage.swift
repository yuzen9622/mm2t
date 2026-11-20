import AppKit
import MM2TApp
import MM2TCore
import SwiftUI

struct MeetingDocumentPage: View {
    let kind: MeetingDocumentKind
    let model: MeetingDetailModel
    let presentation: MeetingPresentation
    let todoKey: String?
    @State private var showsTasks = false

    var body: some View {
        let available = presentation.meeting.editedMarkdown(kind) != nil || (kind == .summary
            ? presentation.meeting.outputs.summary != nil : presentation.meeting.outputs.digests != nil)
        let markdown = model.export(kind.view, as: .markdown) ?? ""
        ScrollViewReader { proxy in
            FadingScrollView(ground: Palette.window) {
                VStack(alignment: .leading, spacing: 18) {
                    InlineMeetingDocument(markdown: markdown, editable: model.canEditSpeakers) {
                        model.updateDocument($0, kind: kind)
                    }
                    if let failure = model.documentSaveFailure(kind) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Couldn’t save document").font(Typo.bodyStrong)
                                Text(failure).font(Typo.caption)
                            }
                            Spacer()
                            PillButton("Retry") { model.retryDocumentSave(kind) }
                        }.foregroundStyle(Palette.danger)
                    }
                    if available {
                        if kind == .summary, let rows = presentation.summary?.actionItems, !rows.isEmpty {
                            Divider().padding(.top, 8)
                            DisclosureGroup("Manage action items", isExpanded: $showsTasks) {
                                TodoSection(title: Copy.presentationLabels.actionItems, rows: rows, model: model, highlight: todoKey)
                                    .padding(.top, 8)
                            }
                            .font(Typo.bodyStrong)
                            .tint(Palette.secondary)
                        }
                    } else {
                        Text(Copy.presentationLabels.notGenerated).foregroundStyle(Palette.secondary)
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 8)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .task(id: todoKey) {
                if kind == .summary, let todoKey {
                    showsTasks = true
                    await Task.yield()
                    proxy.scrollTo(todoKey, anchor: .center)
                }
            }
        }
    }
}
