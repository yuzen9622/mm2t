import SwiftUI

struct AccountAvatar: View {
    let name: String?
    let size: CGFloat

    private var initials: String {
        (name ?? "").split(whereSeparator: \.isWhitespace).prefix(2)
            .compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        let initials = initials
        Circle()
            .fill(initials.isEmpty ? Palette.tonal : Palette.orangeSoft)
            .frame(width: size, height: size)
            .overlay {
                if initials.isEmpty {
                    Icon("user", size: size * 0.55).foregroundStyle(Palette.secondary)
                } else {
                    Text(verbatim: initials)
                        .font(Typo.captionStrong(size: size * 0.4))
                        .foregroundStyle(Palette.orange)
                }
            }
            .accessibilityHidden(true)
    }
}
