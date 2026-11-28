import MM2TApp
import SwiftUI

struct AssistantFilingCard: View {
    let model: AssistantModel
    let turn: UUID
    let proposal: FolderProposal

    @State private var rows: [FolderProposal.Row]?
    @State private var expanded = true
    @State private var applying = false
    @State private var message: LocalizedStringKey?

    private var creating: Bool { proposal.destination == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(Palette.orange)
                Text(creating ? LocalizedStringKey("Create folder and move meetings") : "Move meetings into folder")
                    .font(Typo.heading)
                Text("Awaiting confirmation")
                    .font(Typo.captionStrong).foregroundStyle(Palette.text)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.orangeSoft, in: RoundedRectangle(cornerRadius: 5))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: proposal.name).font(Typo.title).textSelection(.enabled)
                Text(creating ? LocalizedStringKey("New folder") : "Existing folder")
                    .font(Typo.caption).foregroundStyle(Palette.secondary)
            }
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12)
                    Text("Meetings to move (\(proposal.meetings.count))").font(Typo.bodyStrong)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            if expanded {
                if let rows {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "doc.text").foregroundStyle(Palette.secondary)
                                Text(verbatim: row.title).font(Typo.body).frame(maxWidth: .infinity, alignment: .leading)
                                Text(row.date, format: .dateTime.year().month().day()).font(Typo.caption)
                                    .foregroundStyle(Palette.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .padding(.vertical, 7)
                        }
                    }.padding(.leading, 19)
                } else if message == nil { ProgressView().controlSize(.small) }
            }
            if let message {
                Text(message).font(Typo.caption).foregroundStyle(Palette.danger)
            }
            HStack {
                Button("Skip") { model.dismissFiling(proposal.name, turn: turn) }
                    .buttonStyle(FilingButtonStyle(primary: false))
                Spacer()
                Button {
                    guard let rows, !applying else { return }
                    applying = true
                    Task { @MainActor in
                        defer { applying = false }
                        do { try await model.approveFiling(proposal.name, turn: turn, preview: rows) }
                        catch AssistantModel.FilingApproval.saveFailed { message = "Couldn’t save. Try again." }
                        catch { stale() }
                    }
                } label: {
                    Text(creating ? LocalizedStringKey("Create and move \(proposal.meetings.count)") : "Move \(proposal.meetings.count) meetings")
                }
                .buttonStyle(FilingButtonStyle(primary: true))
                .disabled(rows == nil || applying)
            }
        }
        .foregroundStyle(Palette.text)
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay { RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.tonal) }
        .task {
            do { rows = try await model.filingPreview(proposal.name, turn: turn) }
            catch { stale() }
        }
    }

    private func stale() {
        rows = nil
        message = "This filing proposal changed. Ask the assistant to prepare it again."
    }
}

private struct FilingButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Typo.bodyStrong)
            .padding(.horizontal, 15).frame(minHeight: 34)
            .foregroundStyle(primary ? Palette.card : Palette.text)
            .background(primary ? Palette.text : Palette.tonal, in: RoundedRectangle(cornerRadius: Radius.control))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
