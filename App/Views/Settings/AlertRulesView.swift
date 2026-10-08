import SwiftUI
import StormRadioCore

/// Per-warning-type settings: on/off, how it's announced, sound, distance, priority, interrupts.
struct AlertRulesView: View {
    @Binding var profile: Profile
    @State private var newEvent = ""

    private var customEvents: [String] {
        profile.alertRules.keys.filter { ProductCatalog.group(for: $0) == nil }.sorted()
    }

    var body: some View {
        Form {
            ForEach(ProductCatalog.groups, id: \.self) { group in
                Section(group) {
                    ForEach(ProductCatalog.entries.filter { $0.group == group }, id: \.event) { entry in
                        row(entry.event)
                    }
                }
            }
            Section {
                ForEach(customEvents, id: \.self) { e in row(e) }
                    .onDelete { idx in
                        let keys = idx.map { customEvents[$0] }
                        for k in keys { profile.alertRules.removeValue(forKey: k) }
                    }
                HStack {
                    TextField("Exact NWS event name, e.g. Lake Effect Snow Warning", text: $newEvent)
                    Button("Add") {
                        let e = newEvent.trimmingCharacters(in: .whitespaces)
                        guard !e.isEmpty else { return }
                        profile.alertRules[e] = profile.alertRules[e] ?? ProductRule()
                        newEvent = ""
                    }
                }
            } header: {
                Text("Other event types")
            } footer: {
                Text("Add any NWS event name exactly as the NWS writes it.")
            }
            Section {
                NavigationLink {
                    ProductRuleEditor(title: "All other alerts", rule: $profile.otherAlertsRule)
                } label: {
                    RuleSummaryRow(title: "Everything not listed", rule: profile.otherAlertsRule)
                }
            } footer: {
                Text("Used for any NWS alert type that isn't listed above.")
            }
        }
        .navigationTitle("Warnings & watches")
    }

    @ViewBuilder
    private func row(_ event: String) -> some View {
        let binding = Binding<ProductRule>(
            get: { profile.alertRules[event] ?? ProductCatalog.defaultRules[event] ?? ProductRule() },
            set: { profile.alertRules[event] = $0 })
        NavigationLink {
            ProductRuleEditor(title: event, rule: binding)
        } label: {
            RuleSummaryRow(title: event, rule: binding.wrappedValue)
        }
    }
}

struct RuleSummaryRow: View {
    var title: String
    var rule: ProductRule

    var body: some View {
        HStack {
            Circle().fill(Theme.color(forEvent: title)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if rule.enabled && rule.mode != .off {
                    Text("\(rule.mode.label) · \(rule.maxDistanceMiles == 0 ? "inside only" : "\(Int(rule.maxDistanceMiles)) mi") · P\(rule.priority)\(rule.canInterrupt ? " · interrupts" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Off").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .opacity(rule.enabled ? 1 : 0.55)
    }
}

struct ProductRuleEditor: View {
    var title: String
    @Binding var rule: ProductRule

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $rule.enabled)
                ModePicker(mode: $rule.mode)
                TonePicker(tone: $rule.tone)
            } footer: {
                Text("\"Tone only\" plays the sound without reading it. \"Silent\" only adds it to the feed (and a notification).")
            }
            Section {
                MilesField(title: "Announce within", miles: $rule.maxDistanceMiles)
            } footer: {
                Text("Measured from you to the nearest edge of the alert. 0 = only when you're inside it.")
            }
            Section {
                PriorityStepper(priority: $rule.priority)
                Toggle("Can interrupt other messages", isOn: $rule.canInterrupt)
            } footer: {
                Text("Higher priority is read first. With interrupting on, this cuts off a less important message being read (see Priorities & interruptions). PDS, destructive and emergency tags raise the priority.")
            }
            Section("Changes") {
                Toggle("Announce updates", isOn: $rule.announceUpdates)
                Toggle("Announce cancel / expire", isOn: $rule.announceEnding)
                Toggle("iOS notification", isOn: $rule.notify)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
