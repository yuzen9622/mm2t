import SwiftUI

struct AboutView: View {
    private let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: "mm2t \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(Typo.title)
                Text("Licensed under AGPL-3.0.")
                Text("Third-party notices").font(Typo.heading).padding(.top, 12)
                Text(notices).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}
