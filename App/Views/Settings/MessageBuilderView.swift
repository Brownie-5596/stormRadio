import SwiftUI
import StormRadioCore

/// Sample alert used to preview the message builder (the example from the original request).
enum SampleAlert {
    static func make(now: Date = Date()) -> (WeatherAlert, AlertContext) {
        var a = WeatherAlert(id: "sample", event: "Severe Thunderstorm Warning")
        let issued = now.addingTimeInterval(-6 * 60)
        let end = now.addingTimeInterval(50 * 60)
        a.vtec = [VTEC(productClass: "O", action: .new, office: "KOUN", phenomena: "SV", significance: "W", eventNumber: 1, begin: issued, end: end)]
        a.sent = issued
        a.ends = end
        a.expires = end
        a.senderName = "NWS Norman OK"
        a.areaDesc = "Cleveland, OK; McClain, OK"
        a.ugc = ["OKC027", "OKC087"]
        a.thunderstormDamage = .considerable
        a.maxWindMPH = 60
        a.windBasis = .radarIndicated
        a.maxHailInches = 2.0
        a.hailBasis = .observed
        a.nwsHeadline = "SEVERE THUNDERSTORM WARNING IN EFFECT UNTIL 730 PM CDT FOR CLEVELAND AND MCCLAIN COUNTIES"
        a.description = """
        At 640 PM CDT, a severe thunderstorm was located near Blanchard, moving northeast at 30 mph.

        HAZARD...60 mph wind gusts and hen egg size hail.

        SOURCE...NWS employee.

        IMPACT...People and animals outdoors will be injured.

        Locations impacted include...
        Norman, Moore, Noble, Blanchard, Newcastle, and Goldsby.
        """
        a.instruction = "For your protection move to an interior room on the lowest floor of a building. Large hail and damaging winds are imminent."
        let ring = [GeoPoint(lat: 35.30, lon: -97.55), GeoPoint(lat: 35.30, lon: -97.25), GeoPoint(lat: 35.05, lon: -97.25), GeoPoint(lat: 35.05, lon: -97.55)]
        a.geometry = GeoShape(ring: ring)
        let user = Geo.destination(from: GeoPoint(lat: 35.05, lon: -97.55), bearingDegrees: 225, miles: 6)
        let stormNow = GeoPoint(lat: 35.10, lon: -97.62)
        a.motion = StormMotion(time: now, fromDegrees: 225, speedKnots: 26, points: [stormNow])
        let path = StormPath.evaluate(motion: a.motion!, point: user, now: now, halfWidthMiles: 50)
        return (a, AlertContext(reference: user, now: now, path: path, verb: .issued))
    }
}

struct MessageBuilderView: View {
    @EnvironmentObject var model: AppModel
    @Binding var profile: Profile

    private var preview: String {
        let (a, ctx) = SampleAlert.make()
        return AlertPhraser(options: profile.phrasing, template: profile.template).compose(a, ctx)
    }

    var body: some View {
        List {
            Section {
                Text(preview).font(.callout)
                Button {
                    model.speech.speakNow(Announcement(date: Date(), category: .system, title: "Preview", spokenText: preview, notify: false))
                } label: { Label("Speak preview", systemImage: "speaker.wave.2.fill") }
            } header: {
                Text("Preview (sample warning)")
            } footer: {
                Text("Sample: considerable severe thunderstorm warning 6 miles away, radar-indicated 60 mph wind, observed 2\" hail.")
            }

            Section {
                Toggle("Use my own text format", isOn: $profile.template.useCustomFormat)
            }

            if profile.template.useCustomFormat {
                Section {
                    TextEditor(text: $profile.template.customFormat)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Text format")
                } footer: {
                    Text("Placeholders: {a} {tags} {event} {verb} {issuedAgo} {distance} {office} {threats} {source} {hazardText} {storm} {motion} {expires} {expiresIn} {expiresAt} {cities} {counties} {path} {headline} {instructions}. Empty ones disappear and punctuation is cleaned up.")
                }
            } else {
                Section {
                    ForEach($profile.template.blocks) { $block in
                        Toggle(isOn: $block.enabled) {
                            Text(block.kind.label)
                        }
                    }
                    .onMove { from, to in profile.template.blocks.move(fromOffsets: from, toOffset: to) }
                } header: {
                    HStack {
                        Text("Building blocks")
                        Spacer()
                        EditButton().font(.caption)
                    }
                } footer: {
                    Text("Tap Edit and drag to reorder. The type, tags, office, \"issued ago\" and distance blocks form the opening sentence; every other block is its own sentence, in this order.")
                }
                Section {
                    Button("Restore default blocks") { profile.template.blocks = MessageTemplate.standard.blocks }
                }
            }
        }
        .navigationTitle("Message builder")
    }
}

struct WordingView: View {
    @Binding var options: PhraseOptions

    var body: some View {
        Form {
            Section {
                Picker("Measure distance to", selection: $options.distanceMeasure) {
                    ForEach(DistanceMeasure.allCases, id: \.self) { m in Text(m.label).tag(m) }
                }
                Picker("Directions", selection: $options.compass) {
                    Text("8-point (northeast)").tag(CompassStyle.eight)
                    Text("16-point (east-northeast)").tag(CompassStyle.sixteen)
                }
            } header: {
                Text("Distance & direction")
            }
            Section {
                IntStepper(title: "Say \"issued X ago\" if older than", value: $options.issuedAgoMinMinutes, range: -1...60, unit: " min")
                IntStepper(title: "…but not if older than", value: $options.issuedAgoMaxMinutes, range: 0...1440, step: 15, unit: " min")
            } header: {
                Text("Issued time")
            } footer: {
                Text("-1 turns \"issued X minutes ago\" off. You can also turn its block off in the message builder.")
            }
            Section("Expiration") {
                Toggle("Time remaining (\"in 50 minutes\")", isOn: $options.expiresRelative)
                Toggle("Clock time (\"at 7:30\")", isOn: $options.expiresClock)
                Toggle("Say AM / PM", isOn: $options.sayAMPM)
                Toggle("24-hour clock", isOn: $options.use24Hour)
            }
            Section("Threats") {
                Picker("Hail size", selection: $options.hailStyle) {
                    Text("2 inch, hen egg size").tag(HailStyle.inchesAndObject)
                    Text("2 inch").tag(HailStyle.inches)
                    Text("hen egg size").tag(HailStyle.object)
                }
                Toggle("Say how it was detected (radar / observed)", isOn: $options.sayThreatBasis)
            }
            Section("Lists") {
                IntStepper(title: "Max cities", value: $options.maxCities, range: 0...20)
                IntStepper(title: "Max counties", value: $options.maxCounties, range: 0...20)
            }
        }
        .navigationTitle("Wording")
    }
}
