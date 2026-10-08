import SwiftUI
import AVFoundation
import StormRadioCore

struct UpdatesSettingsView: View {
    @Binding var updates: UpdateSettings

    var body: some View {
        Form {
            Section {
                Toggle("Threat changes", isOn: $updates.threatChanges)
                Toggle("Re-read the whole warning when it gets worse", isOn: $updates.fullMessageOnUpgrade)
                Toggle("Time extended / shortened", isOn: $updates.extensions)
                Toggle("Area reduced", isOn: $updates.areaReduced)
                if updates.areaReduced {
                    IntStepper(title: "Only if reduced by at least", value: $updates.areaReducedMinPercent, range: 5...90, step: 5, unit: "%")
                }
                Toggle("Area expanded / counties added", isOn: $updates.areaExpanded)
                Toggle("Routine updates with no change", isOn: $updates.routineUpdates)
            } header: {
                Text("Updates to warnings you've heard")
            } footer: {
                Text("Threat changes: hail or wind size, \"now observed\", tornado now indicated/observed, considerable/destructive tags, PDS or emergency.")
            }
            Section("Endings") {
                Toggle("Cancelled (whole or part)", isOn: $updates.cancellations)
                Toggle("Say why it was cancelled", isOn: $updates.cancelReason)
                Toggle("Expired / allowed to expire", isOn: $updates.expirations)
            }
            Section {
                Toggle("An existing alert comes into range", isOn: $updates.cameIntoRange)
                Toggle("An alert moves out of range", isOn: $updates.wentOutOfRange)
                Toggle("You entered a warning", isOn: $updates.enteredWarning)
                Toggle("Include threats when entering", isOn: $updates.enteredWarningDetails)
                Toggle("You left a warning", isOn: $updates.leftWarning)
            } header: {
                Text("Moving around")
            } footer: {
                Text("Entering and leaving warnings needs GPS mode. Speech plays through CarPlay / Bluetooth like a navigation app.")
            }
        }
        .navigationTitle("Updates & changes")
    }
}

struct PathSettingsView: View {
    @Binding var path: PathSettings

    var body: some View {
        Form {
            Section {
                Toggle("Tell me when a storm is headed my way", isOn: $path.enabled)
            } footer: {
                Text("Uses the storm location and motion the NWS puts in each warning to estimate if and when it reaches you.")
            }
            Section {
                Stepper(value: $path.minimumRisk, in: 1...5) {
                    VStack(alignment: .leading) {
                        Text("Minimum risk: \(path.minimumRisk) (\(RiskIndex.label(path.minimumRisk)))")
                        Text(riskHelp(path.minimumRisk)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                IntListField(title: "Warn at (minutes out)", values: $path.leadTimesMinutes)
                MilesField(title: "Path width (each side)", miles: $path.pathHalfWidthMiles, range: 1...20, zeroLabel: nil)
                Toggle("Only when I'm inside the warning", isOn: $path.onlyInsideWarning)
            } header: {
                Text("When to warn")
            } footer: {
                Text("Example: 30, 15, 5 announces once when the storm is 30 minutes away, again at 15, and again at 5.")
            }
            Section("How") {
                ModePicker(mode: $path.mode)
                TonePicker(tone: $path.tone)
                PriorityStepper(priority: $path.priority)
            }
        }
        .navigationTitle("Storm path alerts")
    }

    private func riskHelp(_ r: Int) -> String {
        switch r {
        case 1: return "Any severe storm"
        case 2: return "1.25\"+ hail, 70 mph, or tornado possible"
        case 3: return "2\"+ hail, 80 mph, or considerable"
        case 4: return "Tornado warnings, destructive, 2.75\"+ hail"
        default: return "Observed tornado, PDS or emergency only"
        }
    }
}

struct InterruptSettingsView: View {
    @Binding var interrupts: InterruptSettings

    var body: some View {
        Form {
            Section {
                Toggle("Allow interruptions", isOn: $interrupts.enabled)
                PriorityStepper(title: "Minimum priority to interrupt", priority: $interrupts.minimumPriority)
                IntStepper(title: "Must be higher by at least", value: $interrupts.minimumGap, range: 1...9)
                Toggle("Re-read the interrupted message after", isOn: $interrupts.resumeInterrupted)
            } footer: {
                Text("A new message can cut off the one being read if its type allows interrupting (set per warning type), its priority is at least the minimum, and it beats the current one by the gap. Example: a tornado warning (9) interrupts a storm report (4).")
            }
            Section {
                IntStepper(title: "PDS", value: $interrupts.pdsBoost, range: 0...5, unit: " +")
                IntStepper(title: "Destructive", value: $interrupts.destructiveBoost, range: 0...5, unit: " +")
                IntStepper(title: "Considerable", value: $interrupts.considerableBoost, range: 0...5, unit: " +")
                IntStepper(title: "Observed tornado", value: $interrupts.observedTornadoBoost, range: 0...5, unit: " +")
                Toggle("Emergencies are always top priority (10)", isOn: $interrupts.emergencyAlwaysTop)
            } header: {
                Text("Tag boosts")
            } footer: {
                Text("Added to the warning type's priority (max 10). PDS, emergency and boosted warnings can always interrupt.")
            }
        }
        .navigationTitle("Priorities")
    }
}

struct ReportsSettingsView: View {
    @Binding var reports: ReportSettings

    var body: some View {
        Form {
            Section {
                Toggle("Storm reports", isOn: $reports.enabled)
            }
            Section {
                ForEach(ReportSource.allCases, id: \.self) { s in
                    Toggle(s.label, isOn: Binding(get: { reports.sourceEnabled(s) }, set: { reports.sources[s.rawValue] = $0 }))
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("mPING needs a free API token (Settings > Data sources). NWS reports come from the Iowa Environmental Mesonet feed of Local Storm Reports.")
            }
            Section {
                MilesField(title: "Within", miles: $reports.maxDistanceMiles, range: 1...200, zeroLabel: nil)
                IntStepper(title: "Ignore if it happened more than", value: $reports.maxAgeMinutes, range: 5...240, step: 5, unit: " min ago")
                IntStepper(title: "Call it \"delayed\" if released", value: $reports.delayedNoteMinutes, range: 5...120, step: 5, unit: " min late")
            } header: {
                Text("Which reports")
            } footer: {
                Text("Reports often come out well after they happened. Old ones are skipped, and late ones are read with the time they actually happened.")
            }
            Section("Wording") {
                Toggle("Say the source (\"SpotterNetwork report\")", isOn: $reports.saySource)
                Toggle("Say who reported it", isOn: $reports.sayReporter)
                Toggle("Read remarks", isOn: $reports.sayRemarks)
            }
            Section("Report types") {
                ForEach(ReportCategory.allCases, id: \.self) { c in
                    let binding = Binding<ReportRule>(get: { reports.rule(for: c) }, set: { reports.categories[c.rawValue] = $0 })
                    NavigationLink {
                        ReportRuleEditor(category: c, rule: binding)
                    } label: {
                        HStack {
                            Image(systemName: Theme.icon(forReport: c)).foregroundStyle(Theme.color(forReport: c)).frame(width: 24)
                            VStack(alignment: .leading) {
                                Text(c.label)
                                Text(binding.wrappedValue.enabled ? binding.wrappedValue.mode.label : "Off").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Storm reports")
    }
}

struct ReportRuleEditor: View {
    var category: ReportCategory
    @Binding var rule: ReportRule

    var body: some View {
        Form {
            Toggle("Enabled", isOn: $rule.enabled)
            ModePicker(mode: $rule.mode)
            TonePicker(tone: $rule.tone)
            PriorityStepper(priority: $rule.priority)
            if category == .hail {
                Stepper(value: $rule.minMagnitude, in: 0...4, step: 0.25) {
                    LabeledContent("Minimum hail size", value: rule.minMagnitude == 0 ? "any" : String(format: "%.2f\"", rule.minMagnitude))
                }
            }
            if category == .windGust {
                Stepper(value: $rule.minMagnitude, in: 0...120, step: 5) {
                    LabeledContent("Minimum gust", value: rule.minMagnitude == 0 ? "any" : "\(Int(rule.minMagnitude)) mph")
                }
            }
        }
        .navigationTitle(category.label)
    }
}

struct SPCSettingsView: View {
    @Binding var spc: SPCSettings

    var body: some View {
        Form {
            Section {
                Toggle("Announce new MDs", isOn: $spc.mdEnabled)
                Toggle("Nationwide (any MD)", isOn: $spc.mdNationwide)
                if !spc.mdNationwide { MilesField(title: "Only within", miles: $spc.mdMaxDistanceMiles, range: 10...800, zeroLabel: nil) }
                ModePicker(mode: $spc.mdMode)
                TonePicker(tone: $spc.mdTone)
                PriorityStepper(priority: $spc.mdPriority)
                Toggle("Also read the summary", isOn: $spc.mdReadSummary)
            } header: {
                Text("Mesoscale discussions")
            } footer: {
                Text("Says the MD number, area, what it's about, watch probability and how far it is from you. Use the Latest MD button to hear the summary any time.")
            }
            Section {
                Toggle("Announce new SPC watches", isOn: $spc.watchEnabled)
                ModePicker(mode: $spc.watchMode)
                TonePicker(tone: $spc.watchTone)
                PriorityStepper(priority: $spc.watchPriority)
                Toggle("Read primary threats", isOn: $spc.watchReadThreats)
            } header: {
                Text("Watches (nationwide)")
            } footer: {
                Text("Every tornado / severe thunderstorm watch SPC issues, including PDS. Watches covering you are also announced through Warnings & watches.")
            }
            Section {
                Toggle("Announce new outlooks", isOn: $spc.outlookEnabled)
                ForEach(1...3, id: \.self) { d in
                    Toggle("Day \(d)", isOn: Binding(
                        get: { spc.outlookDays.contains(d) },
                        set: { on in
                            if on { if !spc.outlookDays.contains(d) { spc.outlookDays.append(d) } } else { spc.outlookDays.removeAll { $0 == d } }
                            spc.outlookDays.sort()
                        }))
                }
                Picker("Only if highest risk is at least", selection: $spc.outlookMinimumRisk) {
                    ForEach(OutlookCategory.allCases, id: \.self) { c in Text(c.label).tag(c) }
                }
                Toggle("Say the risk at my location", isOn: $spc.outlookSayMyRisk)
                Toggle("Read the summary", isOn: $spc.outlookReadSummary)
                ModePicker(mode: $spc.outlookMode)
                TonePicker(tone: $spc.outlookTone)
                PriorityStepper(priority: $spc.outlookPriority)
            } header: {
                Text("Convective outlooks")
            }
        }
        .navigationTitle("SPC products")
    }
}

struct AFDSettingsView: View {
    @Binding var afd: AFDSettings
    static let commonSections = ["UPDATE", "KEY MESSAGES", "SYNOPSIS", "DISCUSSION", "NEAR TERM", "SHORT TERM", "LONG TERM", "AVIATION", "FIRE WEATHER", "HYDROLOGY"]

    var body: some View {
        Form {
            Section {
                Toggle("Announce new AFDs", isOn: $afd.enabled)
                Toggle("My local NWS office", isOn: $afd.includeLocalOffice)
                StringListField(title: "Other offices", placeholder: "OUN, ICT, TSA", values: $afd.extraOffices)
                ModePicker(mode: $afd.mode)
                TonePicker(tone: $afd.tone)
                PriorityStepper(priority: $afd.priority)
            } footer: {
                Text("Office codes are the 3-letter NWS office IDs (Norman = OUN, Wichita = ICT, Tulsa = TSA).")
            }
            Section {
                ForEach(Self.commonSections, id: \.self) { s in
                    Toggle(s.capitalized, isOn: toggle(s, in: $afd.readSectionsOnIssue))
                }
            } header: {
                Text("Read automatically when issued")
            } footer: {
                Text("None selected = just say a new AFD is out.")
            }
            Section("Read with the AFD button") {
                ForEach(Self.commonSections, id: \.self) { s in
                    Toggle(s.capitalized, isOn: toggle(s, in: $afd.readSectionsOnDemand))
                }
            }
        }
        .navigationTitle("Forecast discussions")
    }

    private func toggle(_ name: String, in list: Binding<[String]>) -> Binding<Bool> {
        Binding(get: { list.wrappedValue.contains(name) }, set: { on in
            if on { if !list.wrappedValue.contains(name) { list.wrappedValue.append(name) } } else { list.wrappedValue.removeAll { $0 == name } }
        })
    }
}

struct VoiceSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var voice: VoiceSettings

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    var body: some View {
        Form {
            Section("Speech") {
                VStack(alignment: .leading) {
                    Text("Speed: \(String(format: "%.2f", voice.rate))")
                    Slider(value: $voice.rate, in: 0.3...0.65)
                }
                VStack(alignment: .leading) {
                    Text("Pitch: \(String(format: "%.2f", voice.pitch))")
                    Slider(value: $voice.pitch, in: 0.6...1.6)
                }
                VStack(alignment: .leading) {
                    Text("Voice volume")
                    Slider(value: $voice.volume, in: 0.1...1)
                }
                Picker("Voice", selection: $voice.voiceIdentifier) {
                    Text("System default").tag("")
                    ForEach(voices, id: \.identifier) { v in
                        Text("\(v.name) (\(v.language))\(v.quality == .enhanced ? " · enhanced" : v.quality == .premium ? " · premium" : "")").tag(v.identifier)
                    }
                }
                Button {
                    model.speech.speakNow(Announcement(date: Date(), category: .system, title: "Voice test",
                                                       spokenText: "A tornado warning was issued 8 miles to the southwest. A tornado was indicated by radar. It expires in 35 minutes.",
                                                       notify: false))
                } label: { Label("Test voice", systemImage: "play.circle") }
            }
            Section {
                VStack(alignment: .leading) {
                    Text("Tone volume")
                    Slider(value: $voice.toneVolume, in: 0.05...1)
                }
                ForEach(ToneID.allCases.filter { $0 != .none }, id: \.self) { t in
                    Button { model.speech.preview(tone: t) } label: { Label(t.label, systemImage: "play.circle") }
                }
            } header: {
                Text("Sounds")
            } footer: {
                Text("Pick a sound per warning type (Warnings & watches) and per report type. Better voices: iOS Settings > Accessibility > Spoken Content > Voices.")
            }
            Section("Other audio") {
                Toggle("Lower music while speaking", isOn: $voice.duckOtherAudio)
                Toggle("Pause podcasts / navigation voice", isOn: $voice.interruptSpokenAudio)
                VStack(alignment: .leading) {
                    Text("Pause between messages: \(String(format: "%.1f", voice.gapSeconds)) s")
                    Slider(value: $voice.gapSeconds, in: 0...3, step: 0.1)
                }
            }
        }
        .navigationTitle("Voice & sounds")
    }
}
