import AppKit
import MM2TApp
import MM2TCore
import SwiftUI
import UniformTypeIdentifiers

/// The apps whose mic use brings up the recording prompt: the built-in call apps, which can only
/// be switched off, then the ones the prompt learned or the user added, which can also be removed.
struct PromptAppRules: View {
    let store: SettingsStore
    @State private var problem: LocalizedStringKey?

    private var rules: DetectionRules { store.settings.detectionRules }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apps")
                Spacer()
                PillButton("Add App…", icon: "plus", action: chooseApp)
            }
            ForEach(DetectionPolicy.callApps, id: \.name) { app in
                Toggle(isOn: Binding(
                    get: { app.bundleIDs.allSatisfy { rules.app($0)?.prompts != false } },
                    set: { on in
                        for id in app.bundleIDs {
                            if on {
                                store.settings.detectionRules.remove(id, from: \.apps)
                            } else {
                                store.settings.detectionRules.set(DetectionRule(key: id, name: app.name, prompts: false), in: \.apps)
                            }
                        }
                    })) {
                    Text(verbatim: app.name)
                }
            }
            ForEach(rules.apps.filter { DetectionPolicy.callApp($0.key) == nil }, id: \.key) { rule in
                PromptRuleRow(rule: rule, list: \.apps, store: store)
            }
            if let problem {
                Text(problem).font(Typo.caption).foregroundStyle(Palette.danger)
            }
        }
        .motion(Motion.reveal, value: rules.apps)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        guard !MeetingDetector.browsers.contains(id) else {
            problem = "Browsers are covered by the websites below."
            return
        }
        problem = nil
        let name = FileManager.default.displayName(atPath: url.path)
        store.settings.detectionRules.set(
            DetectionRule(key: id, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name, prompts: true), in: \.apps)
    }
}

/// The websites whose mic use brings up the prompt while their browser is frontmost: the meeting
/// platforms first, then the sites the prompt learned or the user added.
struct PromptSiteRules: View {
    let store: SettingsStore
    @State private var text = ""

    private var rules: DetectionRules { store.settings.detectionRules }
    private var domain: String? { DetectionPolicy.domain(from: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Websites")
            ForEach(MeetingPlatform.allCases, id: \.self) { platform in
                let key = DetectionPolicy.siteDomain(platform)
                Toggle(isOn: Binding(
                    get: { DetectionPolicy.decision(for: platform, rules: rules) == .prompt },
                    set: { on in
                        if on {
                            store.settings.detectionRules.remove(key, from: \.sites)
                        } else {
                            store.settings.detectionRules.set(DetectionRule(key: key, name: key, prompts: false), in: \.sites)
                        }
                    })) {
                    HStack(spacing: 8) {
                        Text(verbatim: platform.displayName)
                        Text(verbatim: key).font(Typo.caption).foregroundStyle(Palette.secondary)
                    }
                }
            }
            ForEach(rules.sites.filter { key in !MeetingPlatform.allCases.contains { DetectionPolicy.siteDomain($0) == key.key } },
                    id: \.key) { rule in
                PromptRuleRow(rule: rule, list: \.sites, store: store)
            }
            HStack(spacing: 8) {
                FieldBox {
                    TextField("Website", text: $text, prompt: Text(verbatim: "example.com"))
                        .onSubmit(add)
                }
                PillButton("Add", action: add).disabled(domain == nil)
            }
            if !text.isEmpty, domain == nil {
                Text("Enter a website address, like example.com.").font(Typo.caption).foregroundStyle(Palette.danger)
            }
        }
        .motion(Motion.reveal, value: rules.sites)
    }

    private func add() {
        guard let domain else { return }
        store.settings.detectionRules.set(DetectionRule(key: domain, name: domain, prompts: true), in: \.sites)
        text = ""
    }
}

/// A learned or hand-added entry: its switch is prompt or don't prompt, and it can be removed.
private struct PromptRuleRow: View {
    let rule: DetectionRule
    let list: WritableKeyPath<DetectionRules, [DetectionRule]>
    let store: SettingsStore

    var body: some View {
        Toggle(isOn: Binding(
            get: { rule.prompts },
            set: { on in
                var changed = rule
                changed.prompts = on
                store.settings.detectionRules.set(changed, in: list)
            })) {
            HStack(spacing: 8) {
                Text(verbatim: rule.name)
                Spacer()
                IconButton("Remove", icon: "x") { store.settings.detectionRules.remove(rule.key, from: list) }
            }
        }
    }
}
