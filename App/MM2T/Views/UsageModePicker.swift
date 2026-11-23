import MM2TApp
import SwiftUI

extension UsageChoice {
    var title: LocalizedStringKey {
        switch self {
        case .signIn: "Plan"
        case .ownKeys: "Own API keys"
        case .ownServer: "Local and self-hosted"
        }
    }

    var icon: String {
        switch self {
        case .signIn: "sparkles"
        case .ownKeys: "key"
        case .ownServer: "server"
        }
    }
}

struct UsageModePicker: View {
    let selection: UsageChoice
    let select: (UsageChoice) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(UsageChoice.allCases, id: \.self) { choice in
                UsageModeCard(choice: choice, selected: choice == selection) { select(choice) }
            }
        }
    }
}

private struct UsageModeCard: View {
    let choice: UsageChoice
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        Button(action: action) {
            VStack(spacing: 4) {
                Icon(choice.icon, size: 20).foregroundStyle(selected ? Palette.orange : Palette.secondary)
                Text(choice.title).font(Typo.bodyStrong).multilineTextAlignment(.center)
                if !choice.isAvailable { ComingSoonBadge() }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background(hovering ? Palette.hover : Palette.panel, in: shape)
            .overlay { shape.strokeBorder(Palette.orange, lineWidth: selected ? 1.5 : 0) }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Icon("check", size: 16).foregroundStyle(Palette.orange).padding(8)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(Pressable())
        .focusEffectDisabled()
        .disabled(!choice.isAvailable)
        .opacity(choice.isAvailable ? 1 : 0.5)
        .onHover { hovering = $0 && choice.isAvailable }
        .motion(Motion.touch, value: hovering)
        .motion(Motion.select, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ComingSoonBadge: View {
    var body: some View {
        Text("Coming soon")
            .font(Typo.caption)
            .foregroundStyle(Palette.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Palette.tonal, in: Capsule())
    }
}
