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
                if let plan = account.plan { PlanUsage(plan: plan, account: account) }
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

    var body: some View {
        UsageBar(title: "Shared meetings this month", value: String(localized: "\(quota.used) / \(quota.limit)"),
                 fraction: UsageBar.fraction(used: quota.used, limit: quota.limit))
    }
}

struct PlanUsage: View {
    let plan: CollabPlan
    let account: CollabAccount
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UsageBar.transcription(plan: plan)
            if let limit = plan.asksLimit {
                UsageBar(title: "AI questions this month", value: String(localized: "\(plan.asksUsed) / \(limit)"),
                         fraction: UsageBar.fraction(used: plan.asksUsed, limit: limit))
            }
            if plan.status == "past_due" {
                Text("Payment didn't go through.").font(Typo.caption).foregroundStyle(Palette.danger)
            }
            HStack {
                changeDate.font(Typo.caption).foregroundStyle(Palette.secondary)
                Spacer(minLength: 8)
                PillButton("Manage Account") {
                    Task { await account.openAccountPage { openURL($0) } }
                }
                .disabled(account.busy)
            }
        }
    }

    private var changeDate: Text {
        if let change = plan.scheduledChange {
            let name = CollabPlan.displayName(for: change.plan) ?? change.plan
            return Text("Changes to \(name) on \(change.at.formatted(date: .abbreviated, time: .omitted))")
        }
        return Text("Resets on \(plan.periodEnd.formatted(date: .abbreviated, time: .omitted))")
    }
}

struct UsageBar: View {
    let title: LocalizedStringKey
    let value: String
    let fraction: Double

    static func fraction(used: Int, limit: Int) -> Double {
        guard limit > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(limit)))
    }

    static func transcription(plan: CollabPlan) -> Self {
        Self(title: "Transcription this month", value: String(localized: "\(plan.usedMinutes) / \(plan.minutesLimit) min"),
             fraction: fraction(used: plan.usedMinutes, limit: plan.minutesLimit))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(verbatim: value)
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
