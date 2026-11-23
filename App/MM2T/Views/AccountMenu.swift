import MM2TApp
import SwiftUI

struct AccountMenuButton: View {
    let app: AppController
    @Environment(\.openURL) private var openURL
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let account = app.collabAccount
        let user = account?.user
        let settings = app.settings.settings
        let usesPlan = settings.transcriptionService == .mm2t || settings.summaryService == .mm2t
        let subtitle = user.map { usesPlan ? planName : $0.email } ?? settings.transcriptionService.connection.title
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                AccountAvatar(name: user?.name, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: user?.name ?? "mm2t").font(Typo.bodyStrong).lineLimit(1)
                    Text(verbatim: subtitle).font(Typo.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Icon("selector", size: 14).foregroundStyle(Palette.secondary)
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(open ? Palette.selected : hovering ? Palette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
        .motion(Motion.select, value: open)
        .accessibilityLabel("Account and settings")
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                if let user {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: user.email).foregroundStyle(Palette.secondary)
                        if let quota = account?.quota { SharedMeetingsQuota(quota: quota) }
                    }
                    .font(Typo.caption)
                    .padding(8)
                    Divider()
                }
                if account != nil { row("Account", icon: "user-circle") { showSettings(.account) } }
                row("Settings", icon: "settings") { showSettings(.general) }
                row("Models and services", icon: "sparkles") { showSettings(.models) }
                row("Help", icon: "help-circle") { openURL(AppLinks.help) }
                if let account {
                    Divider()
                    Group {
                        if user != nil {
                            row("Sign Out", icon: "logout") { Task { await account.signOut() } }
                        } else {
                            row("Sign in with Google", icon: "brand-google") { Task { await account.signIn(.google) } }
                            row("Sign in with Apple", icon: "brand-apple") { Task { await account.signIn(.apple) } }
                        }
                    }
                    .disabled(account.busy)
                }
            }
            .padding(8)
            .frame(width: 240)
            .background(Palette.panel)
            .dropdownLayer()
        }
        .onChange(of: open) { _, isOpen in
            if isOpen, let account, account.user != nil {
                Task { await account.refreshProfile() }
            }
        }
    }

    private func showSettings(_ section: SettingsSection) {
        MainNavigation.shared.settingsSection = section
        MainNavigation.shared.settingsOpen = true
    }

    private func row(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        AccountMenuRow(title: title, icon: icon) {
            open = false
            action()
        }
    }
}

private struct AccountMenuRow: View {
    let title: LocalizedStringKey
    let icon: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Icon(icon, size: 16).foregroundStyle(Palette.secondary)
                Text(title).font(Typo.body).foregroundStyle(Palette.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(hovering && enabled ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: hovering)
    }
}
