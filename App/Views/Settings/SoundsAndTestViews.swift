import SwiftUI
import UIKit
import UniformTypeIdentifiers
import StormRadioCore

/// Built-in tones plus your own sound files.
struct SoundsView: View {
    @EnvironmentObject var model: AppModel
    @State private var importing = false
    @State private var message: String?
    @State private var renaming: CustomSound?
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                Button { importing = true } label: { Label("Add a sound file…", systemImage: "plus.circle.fill") }
                if model.sounds.sounds.isEmpty {
                    Text("No custom sounds yet.").foregroundStyle(.secondary)
                }
                ForEach(model.sounds.sounds) { s in
                    HStack {
                        Button { model.speech.preview(tone: s.tone) } label: { Image(systemName: "play.circle.fill").font(.title3) }
                            .buttonStyle(.borderless)
                        Text(s.name)
                        Spacer()
                        Text((s.fileName as NSString).pathExtension.uppercased()).font(.caption2).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { model.sounds.delete(s) } label: { Label("Delete", systemImage: "trash") }
                        Button { newName = s.name; renaming = s } label: { Label("Rename", systemImage: "pencil") }.tint(.blue)
                    }
                }
                if let m = message { Text(m).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("My sounds")
            } footer: {
                Text("Add m4a, mp3, wav, caf or aiff files (a voice memo, a siren, a NOAA tone…). They also live in Files › On My iPhone › Storm Radio › Sounds, so you can drop files in there too. Pick them per warning type in Warnings & watches. Sound files aren't included in exported settings — add them on each device (same file name).")
            }

            Section {
                ForEach(ToneID.builtIn.filter { $0 != .none }, id: \.self) { t in
                    Button { model.speech.preview(tone: t) } label: { Label(t.label, systemImage: "play.circle") }
                }
            } header: {
                Text("Built-in sounds")
            }

            Section {
                VStack(alignment: .leading) {
                    Text("Cut custom sounds off after \(Int(model.profile.voice.customSoundMaxSeconds)) s")
                    Slider(value: model.activeProfileBinding.voice.customSoundMaxSeconds, in: 2...60, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("Sound volume")
                    Slider(value: model.activeProfileBinding.voice.toneVolume, in: 0.05...1)
                }
            } footer: {
                Text("These are saved in the active profile (\(model.profile.name)).")
            }
        }
        .navigationTitle("Sounds")
        .onAppear { model.sounds.reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .failure(let e): message = e.localizedDescription
            case .success(let urls):
                var added: [String] = []
                for u in urls {
                    do { added.append(try model.sounds.importFile(u).name) } catch { message = error.localizedDescription }
                }
                if !added.isEmpty {
                    message = "Added \(added.joined(separator: ", "))."
                    if let first = added.first, let s = model.sounds.sounds.first(where: { $0.name == first }) { model.speech.preview(tone: s.tone) }
                }
            }
        }
        .alert("Rename sound", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let s = renaming { model.sounds.rename(s, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Warning types using the old name will fall back to the double beep until you pick it again.")
        }
    }
}

/// Plays sample announcements through the real radio queue, using the active profile's settings.
struct TestAlertsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                ForEach(samples, id: \.0) { item in
                    Button { play(item.1()) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0)
                            let a = item.1()
                            Text("\(a.mode.label)\(a.mode.playsTone ? " · \(a.tone.label)" : "") · priority \(a.priority)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Uses the sound, announce mode, priority and wording from the active profile (\(model.profile.name)), so you hear exactly what a real one would sound like.")
            }
            Section {
                Button("Report, then a tornado warning 2 s later") {
                    play(sampleReport())
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        play(sampleAlert(event: "Tornado Warning"))
                    }
                }
            } header: {
                Text("Interruptions")
            } footer: {
                Text("Shows whether a tornado warning cuts off a storm report with your current priority settings.")
            }
            Section {
                Button("Stop", role: .destructive) { model.speech.stopAll() }
            }
        }
        .navigationTitle("Test alerts")
    }

    private var samples: [(String, () -> Announcement)] {
        [
            ("Tornado warning", { sampleAlert(event: "Tornado Warning") }),
            ("Severe thunderstorm warning", { sampleAlert(event: "Severe Thunderstorm Warning") }),
            ("Flash flood warning", { sampleAlert(event: "Flash Flood Warning") }),
            ("Special weather statement", { sampleAlert(event: "Special Weather Statement") }),
            ("Tornado watch", { sampleAlert(event: "Tornado Watch") }),
            ("Storm in your path", { samplePath() }),
            ("Hail report", { sampleReport() }),
            ("Mesoscale discussion", { sampleMD() }),
        ]
    }

    private func play(_ a: Announcement) {
        var x = a
        x.id = UUID().uuidString
        model.speech.enqueue(x)
    }

    private func sampleAlert(event: String) -> Announcement {
        var (a, ctx) = SampleAlert.make()
        a.event = event
        switch event {
        case "Tornado Warning":
            a.thunderstormDamage = .none
            a.maxWindMPH = nil
            a.maxHailInches = 1.0
            a.hailBasis = .radarIndicated
            a.tornadoDetection = .radarIndicated
            a.description = a.description.replacingOccurrences(of: "SOURCE...NWS employee.", with: "SOURCE...Radar indicated rotation.")
        case "Flash Flood Warning":
            a.thunderstormDamage = .none
            a.maxWindMPH = nil
            a.maxHailInches = nil
            a.flashFloodDetection = .radarIndicated
        case "Special Weather Statement", "Tornado Watch":
            a.thunderstormDamage = .none
            a.maxWindMPH = nil
            a.maxHailInches = nil
            a.motion = nil
        default: break
        }
        ctx.path = nil
        let rule = model.profile.rule(for: event)
        let ph = AlertPhraser(options: model.profile.phrasing, template: model.profile.template)
        return Announcement(date: Date(), category: .warning, title: "Test: \(event)", spokenText: "Test. " + ph.compose(a, ctx),
                            mode: rule.mode == .off || rule.mode == .notifyOnly ? .speak : rule.mode, tone: rule.tone,
                            priority: rule.priority, canInterrupt: rule.canInterrupt, notify: false, kind: event)
    }

    private func samplePath() -> Announcement {
        let (a, ctx) = SampleAlert.make()
        let ph = AlertPhraser(options: model.profile.phrasing, template: model.profile.template)
        let path = PathResult(inPath: true, etaMinutes: 12, offTrackMiles: 1, arrival: Date().addingTimeInterval(12 * 60))
        let p = model.profile.path
        return Announcement(date: Date(), category: .path, title: "Test: in path", spokenText: "Test. " + ph.pathText(a, path: path, ctx),
                            mode: p.mode == .off || p.mode == .notifyOnly ? .speak : p.mode, tone: p.tone, priority: p.priority,
                            canInterrupt: true, notify: false)
    }

    private func sampleReport() -> Announcement {
        let r = StormReport(id: "test", source: .spotterNetwork, category: .hail, typeText: "hail", magnitude: 1.75, unit: "Inch",
                            reporter: "Test Spotter", point: Geo.destination(from: model.currentReferencePoint ?? GeoPoint(lat: 35.2, lon: -97.4), bearingDegrees: 240, miles: 7),
                            eventTime: Date().addingTimeInterval(-4 * 60))
        let rule = model.profile.reports.rule(for: .hail)
        let text = ReportPhraser(settings: model.profile.reports, phrasing: model.profile.phrasing).compose(r, from: model.currentReferencePoint, now: Date())
        return Announcement(date: Date(), category: .report, title: "Test: hail report", spokenText: "Test. " + text,
                            mode: rule.mode == .off || rule.mode == .notifyOnly ? .speak : rule.mode, tone: rule.tone, priority: rule.priority,
                            notify: false, kind: ReportCategory.hail.rawValue)
    }

    private func sampleMD() -> Announcement {
        let spc = model.profile.spc
        let text = "Test. S P C Mesoscale Discussion 1234 for central Oklahoma. Concerning severe potential, tornado watch likely. Probability of watch issuance, 80 percent. It is 25 miles to your west."
        return Announcement(date: Date(), category: .md, title: "Test: MD", spokenText: text,
                            mode: spc.mdMode == .off || spc.mdMode == .notifyOnly ? .speak : spc.mdMode, tone: spc.mdTone, priority: spc.mdPriority, notify: false)
    }
}

struct UpdatesView: View {
    @EnvironmentObject var model: AppModel
    @State private var copied = false

    var body: some View {
        let u = model.updates
        Form {
            Section("This app") {
                LabeledContent("Installed", value: "\(u.installedVersion) (build \(u.installedBuild))")
                if let l = u.latest {
                    LabeledContent("Latest", value: "\(l.version) (build \(l.build))")
                    if u.updateAvailable {
                        Label("An update is available", systemImage: "arrow.down.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("You're up to date", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                    if !l.notes.isEmpty { Text(l.notes).font(.caption).foregroundStyle(.secondary) }
                }
                if let e = u.error { Text(e).font(.caption).foregroundStyle(.orange) }
                Button {
                    Task { await u.check(force: true) }
                } label: {
                    if u.checking { ProgressView() } else { Label("Check now", systemImage: "arrow.clockwise") }
                }
            }
            Section {
                Button { u.addSource(app: "sidestore") } label: { Label("Add to SideStore", systemImage: "plus.app") }
                Button { u.addSource(app: "altstore") } label: { Label("Add to AltStore", systemImage: "plus.app") }
                Button {
                    UIPasteboard.general.string = UpdateChecker.sourceURL.absoluteString
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy source link", systemImage: "doc.on.doc") }
            } header: {
                Text("One-tap updates (recommended)")
            } footer: {
                Text("SideStore and AltStore can install Storm Radio from a \"source\" and show an Update button whenever a new build is published — no downloading files. SideStore also re-signs on the phone itself, so no computer is needed after setup.")
            }
            Section {
                Link(destination: UpdateChecker.ipaURL) { Label("Download latest StormRadio.ipa", systemImage: "arrow.down.doc") }
                Link(destination: UpdateChecker.releasePage) { Label("Open the release page", systemImage: "safari") }
            } header: {
                Text("Sideloadly")
            } footer: {
                Text("With Sideloadly, install the new .ipa over the old app (don't delete it first) to keep your settings. This link never changes.")
            }
        }
        .navigationTitle("App updates")
        .task { await u.check() }
    }
}
