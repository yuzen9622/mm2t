import MM2TApp
import MM2TProviders
import SwiftUI

struct CollabAccountSettings: View {
    let account: CollabAccount
    var showsPlan = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let user = account.user {
                HStack(spacing: 12) {
                    AccountAvatar(name: user.name, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: user.name).font(Typo.bodyStrong)
                        Text(verbatim: user.email).foregroundStyle(Palette.secondary)
                        if showsPlan, let name = account.planName {
                            Text(verbatim: name).font(Typo.captionStrong).foregroundStyle(Palette.secondary)
                        }
                    }
                    Spacer()
                    PillButton("Sign Out") { Task { await account.signOut() } }
                        .disabled(account.busy)
                }
                if let quota = account.quota { SharedMeetingsQuota(quota: quota) }
            } else {
                HStack(spacing: 12) {
                    AccountAvatar(name: nil, size: 40)
                    AccountSignInButtons(account: account)
                    Spacer(minLength: 0)
                }
            }
            AccountErrorLine(account: account)
        }
        .task(id: account.user?.id) {
            if account.user != nil { await account.refreshProfile() }
        }
    }
}

struct SharedMeetingsQuota: View {
    let quota: CollabProfile.Quota

    private var fraction: Double {
        guard quota.limit > 0 else { return 0 }
        return min(1, max(0, Double(quota.used) / Double(quota.limit)))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Shared meetings this month")
                Spacer(minLength: 8)
                Text("\(quota.used) / \(quota.limit)")
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary)
                    .fixedSize()
            }
            GeometryReader { bar in
                Capsule().fill(Palette.tonal)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Palette.orange).frame(width: bar.size.width * fraction)
                    }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct AccountSignInButtons: View {
    let account: CollabAccount

    var body: some View {
        HStack(spacing: 8) {
            PillButton("Sign in with Google", icon: "brand-google") { Task { await account.signIn(.google) } }
            PillButton("Sign in with Apple", icon: "brand-apple") { Task { await account.signIn(.apple) } }
        }
        .disabled(account.busy)
    }
}

struct AccountErrorLine: View {
    let account: CollabAccount

    var body: some View {
        if let error = account.error {
            Text(verbatim: error.collabMessage).font(Typo.caption).foregroundStyle(Palette.danger)
        }
    }
}
