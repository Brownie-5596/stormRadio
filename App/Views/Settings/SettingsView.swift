import SwiftUI
import UniformTypeIdentifiers
import StormRadioCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Active profile", selection: Binding(get: { model.settings.activeProfileID }, set: { model.switchProfile(to: $0) })) {
                        ForEach(model.settings.profiles) { p in Text(p.name).tag(p.id) }
                    }
                    NavigationLink { ProfilesView() } label: { Label("Manage profiles", systemImage: "person.2") }
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Everything below \"This profile\" is saved per profile. Switch profiles from the Radio tab too.")
                }

                Section("This profile: \(model.profile.name)") {
                    ProfileSettingsLinks(profile: model.activeProfileBinding)
                }

                Section("App") {
                    NavigationLink { DataSettingsView() } label: { Label("Data sources & polling", systemImage: "antenna.radiowaves.left.and.right") }
                    NavigationLink { ImportExportView() } label: { Label("Import / export settings", systemImage: "square.and.arrow.up.on.square") }
                    NavigationLink { SourceStatusView() } label: { Label("Source status", systemImage: "checkmark.seal") }
                    NavigationLink { AboutView() } label: { Label("Help & about", systemImage: "questionmark.circle") }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// The per-profile settings pages (also used when editing a non-active profile).
struct ProfileSettingsLinks: View {
    @Binding var profile: Profile

    var body: some View {
        NavigationLink { LocationAreaView(profile: $profile) } label: { Label("Location & area", systemImage: "location.viewfinder") }
        NavigationLink { AlertRulesView(profile: $profile) } label: { Label("Warnings & watches", systemImage: "exclamationmark.triangle") }
        NavigationLink { MessageBuilderView(profile: $profile) } label: { Label("Message builder", systemImage: "text.badge.plus") }
        NavigationLink { WordingView(options: $profile.phrasing) } label: { Label("Wording", systemImage: "textformat") }
        NavigationLink { UpdatesSettingsView(updates: $profile.updates) } label: { Label("Updates, cancels & entering warnings", systemImage: "arrow.triangle.2.circlepath") }
        NavigationLink { PathSettingsView(path: $profile.path) } label: { Label("Storm path alerts", systemImage: "arrow.right.to.line.compact") }
        NavigationLink { ReportsSettingsView(reports: $profile.reports) } label: { Label("Storm reports", systemImage: "person.wave.2") }
        NavigationLink { SPCSettingsView(spc: $profile.spc) } label: { Label("SPC: MDs, watches, outlooks", systemImage: "doc.text.magnifyingglass") }
        NavigationLink { AFDSettingsView(afd: $profile.afd) } label: { Label("Forecast discussions (AFD)", systemImage: "text.book.closed") }
        NavigationLink { VoiceSettingsView(voice: $profile.voice) } label: { Label("Voice & sounds", systemImage: "speaker.wave.2") }
        NavigationLink { InterruptSettingsView(interrupts: $profile.interrupts) } label: { Label("Priorities & interruptions", systemImage: "exclamationmark.bubble") }
        Toggle("Summary when monitoring starts", isOn: $profile.startupSummary)
    }
}

// MARK: - Profiles

struct ProfilesView: View {
    @EnvironmentObject var model: AppModel
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section {
                ForEach(model.settings.profiles) { p in
                    NavigationLink {
                        ProfileEditView(id: p.id)
                    } label: {
                        HStack {
                            Text(p.name)
                            Spacer()
                            if p.id == model.settings.activeProfileID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                    }
                    .swipeActions {
                        if model.settings.profiles.count > 1 {
                            Button(role: .destructive) { delete(p.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                        Button { duplicate(p) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }.tint(.blue)
                    }
                }
                .onMove { from, to in model.settings.profiles.move(fromOffsets: from, toOffset: to) }
            } footer: {
                Text("Swipe a profile to duplicate or delete it. Profiles are presets: Chase, Home, a quiet one, overnight…")
            }
            Section("Add a profile from a template") {
                Button("Chase (GPS, everything convective)") { add(.chase) }
                Button("Home (fixed point)") { add(.home) }
                Button("Quiet (tones, speech for tornadoes)") { add(.quiet) }
                Button("Overnight (life-threatening only)") { add(.overnight) }
            }
        }
        .navigationTitle("Profiles")
        .toolbar { EditButton() }
    }

    private func add(_ template: Profile) {
        var p = template
        p.id = UUID().uuidString
        p.name = uniqueName(template.name)
        model.settings.profiles.append(p)
    }

    private func duplicate(_ p: Profile) {
        var c = p
        c.id = UUID().uuidString
        c.name = uniqueName(p.name + " copy")
        model.settings.profiles.append(c)
    }

    private func delete(_ id: String) {
        guard model.settings.profiles.count > 1 else { return }
        if id == model.settings.activeProfileID, let other = model.settings.profiles.first(where: { $0.id != id }) {
            model.switchProfile(to: other.id)
        }
        model.settings.profiles.removeAll { $0.id == id }
    }

    private func uniqueName(_ base: String) -> String {
        var name = base
        var n = 2
        while model.settings.profiles.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        return name
    }
}

struct ProfileEditView: View {
    @EnvironmentObject var model: AppModel
    var id: String

    var body: some View {
        let binding = model.binding(for: id)
        Form {
            Section("Name") {
                TextField("Profile name", text: binding.name)
            }
            if id != model.settings.activeProfileID {
                Section {
                    Button("Make this the active profile") { model.switchProfile(to: id) }
                }
            }
            Section("Settings") {
                ProfileSettingsLinks(profile: binding)
            }
            Section {
                if let data = try? SettingsIO.encode(profile: binding.wrappedValue),
                   let url = Storage.exportFile(data, name: "StormRadio-profile-\(safeName(binding.wrappedValue.name)).json") {
                    ShareLink(item: url) { Label("Share just this profile", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle(binding.wrappedValue.name)
    }

    private func safeName(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
}

// MARK: - Import / export

struct JSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ImportExportView: View {
    @EnvironmentObject var model: AppModel
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var importMode = ImportMode.replace
    @State private var message: String?
    @State private var pending: AppSettings?

    enum ImportMode { case replace, addProfiles }

    var body: some View {
        Form {
            Section {
                if let data = try? SettingsIO.encode(model.settings),
                   let url = Storage.exportFile(data, name: "StormRadio-settings.json") {
                    ShareLink(item: url) { Label("Share settings file (AirDrop, Messages, Files…)", systemImage: "square.and.arrow.up") }
                }
                Button { showExporter = true } label: { Label("Save settings to Files / iCloud Drive", systemImage: "folder") }
            } header: {
                Text("Export")
            } footer: {
                Text("The file has every profile and setting. AirDrop it between your iPhone and iPad, or edit it on a computer with the Storm Radio settings editor (tools/settings-editor.html in the project) and import it back.")
            }

            Section {
                Button { importMode = .replace; showImporter = true } label: { Label("Import and replace all settings", systemImage: "square.and.arrow.down") }
                Button { importMode = .addProfiles; showImporter = true } label: { Label("Import profiles (keep mine)", systemImage: "plus.square.on.square") }
            } header: {
                Text("Import")
            } footer: {
                Text("Settings missing from an older file are filled in with defaults. Your settings are also saved as settings.json in Files > On My iPhone > Storm Radio.")
            }

            if let m = message {
                Section { Text(m).font(.callout) }
            }

            Section {
                Button("Reset everything to defaults", role: .destructive) { pending = .defaults }
            }
        }
        .navigationTitle("Import / export")
        .fileExporter(isPresented: $showExporter, document: JSONFile(data: (try? SettingsIO.encode(model.settings)) ?? Data()),
                      contentType: .json, defaultFilename: "StormRadio-settings") { result in
            if case .failure(let e) = result { message = "Export failed: \(e.localizedDescription)" } else { message = "Saved." }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .plainText, .data]) { result in
            switch result {
            case .failure(let e): message = "Import failed: \(e.localizedDescription)"
            case .success(let url): importFile(url)
            }
        }
        .confirmationDialog("Replace all settings?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Replace", role: .destructive) {
                if let p = pending { model.replaceSettings(p); message = "Settings replaced (\(p.profiles.count) profiles)." }
                pending = nil
            }
        }
    }

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let imported = try SettingsIO.decode(data)
            switch importMode {
            case .replace:
                pending = imported
            case .addProfiles:
                model.replaceSettings(SettingsIO.mergeProfiles(from: imported, into: model.settings))
                message = "Added/updated \(imported.profiles.count) profile(s)."
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Data sources

struct DataSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                TextField("Email or website (optional)", text: $model.settings.general.contactInfo)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Contact for NWS")
            } footer: {
                Text("The National Weather Service asks apps to identify themselves. This is only sent to api.weather.gov in the User-Agent header.")
            }
            Section {
                IntStepper(title: "NWS alerts", value: $model.settings.general.alertPollSeconds, range: 15...300, step: 5, unit: " s")
                IntStepper(title: "Storm reports", value: $model.settings.general.reportPollSeconds, range: 30...600, step: 15, unit: " s")
                IntStepper(title: "SPC products", value: $model.settings.general.productPollSeconds, range: 60...900, step: 30, unit: " s")
                IntStepper(title: "Forecast discussions", value: $model.settings.general.afdPollSeconds, range: 120...1800, step: 60, unit: " s")
                Toggle("Only download my state + neighbors", isOn: $model.settings.general.limitToNearbyStates)
            } header: {
                Text("How often to check")
            } footer: {
                Text("Limiting to nearby states saves a lot of cellular data. Turn it off if you monitor a custom area far from where you are.")
            }
            Section {
                SecureField("mPING API token", text: $model.settings.general.mpingAPIKey)
                Link("Request a free mPING API token", destination: URL(string: "https://mping.ou.edu/mping/api/v2/")!)
            } header: {
                Text("mPING")
            } footer: {
                Text("mPING reports need a token. Turn mPING on per profile under Storm reports.")
            }
            Section {
                Toggle("Post iOS notifications", isOn: $model.settings.general.postNotifications)
                Toggle("Keep app alive with silent audio", isOn: $model.settings.general.keepAliveAudio)
                Toggle("Keep screen on while monitoring", isOn: $model.settings.general.keepScreenOn)
            } header: {
                Text("Background")
            } footer: {
                Text("While monitoring, location updates keep Storm Radio running in the background. If iOS still suspends it (e.g. with a fixed location), turn on silent audio.")
            }
            Section("Location permission") {
                LabeledContent("Status", value: model.location.authorizationText)
                Button("Allow \"Always\" location") { model.location.requestAlways() }
            }
        }
        .navigationTitle("Data & polling")
    }
}

struct SourceStatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            if model.sourceStatus.isEmpty { Text("Start monitoring to see source status.").foregroundStyle(.secondary) }
            ForEach(model.sourceStatus.keys.sorted(), id: \.self) { k in
                let s = model.sourceStatus[k]!
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: s.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(s.ok ? .green : .orange)
                        Text(k).font(.headline)
                        Spacer()
                        Text("\(s.itemCount)").foregroundStyle(.secondary)
                    }
                    if let t = s.lastSuccess { Text("Last success \(t.ago)").font(.caption).foregroundStyle(.secondary) }
                    if let e = s.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                }
            }
            if let info = model.pointInfo {
                Section("Your NWS location") {
                    LabeledContent("Office", value: info.cwa)
                    LabeledContent("County", value: info.countyUGC ?? "–")
                    LabeledContent("Zone", value: info.zoneUGC ?? "–")
                    LabeledContent("Near", value: "\(info.city ?? "–"), \(info.state ?? "")")
                }
            }
        }
        .navigationTitle("Source status")
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section("How it works") {
                Text("Storm Radio checks the National Weather Service, SPC, NWS storm reports (via Iowa Environmental Mesonet), SpotterNetwork and mPING, then reads only what matters to you, based on the active profile.")
                Text("Warnings are tracked across updates, so you hear when one is upgraded, gets new hail or wind info, a tornado is observed, it's extended, part of it is cancelled, or it expires.")
                Text("Distances are measured to the nearest edge of the warning (change that in Wording). \"In path\" alerts use the storm motion in the NWS warning.")
            }
            Section("Background use") {
                Text("Keep monitoring on and leave the app running (it can be in the background or the phone locked). Speech plays through CarPlay or Bluetooth like a navigation app. Force-quitting the app stops it.")
            }
            Section("Data sources") {
                Link("api.weather.gov", destination: URL(string: "https://www.weather.gov/documentation/services-web-api")!)
                Link("Storm Prediction Center", destination: URL(string: "https://www.spc.noaa.gov")!)
                Link("Iowa Environmental Mesonet", destination: URL(string: "https://mesonet.agron.iastate.edu")!)
                Link("SpotterNetwork", destination: URL(string: "https://www.spotternetwork.org")!)
                Link("mPING", destination: URL(string: "https://mping.ou.edu")!)
            }
            Section {
                Text("Not an official warning system. Always have more than one way to get warnings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Help & about")
    }
}
