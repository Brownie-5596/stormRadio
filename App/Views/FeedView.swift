import SwiftUI
import StormRadioCore

/// The notification center: everything the radio announced (or would have), newest first.
struct FeedView: View {
    @EnvironmentObject var model: AppModel
    @State private var hidden: Set<AnnouncementCategory> = []
    @State private var search = ""
    @State private var path = NavigationPath()
    @State private var confirmClear = false

    private var items: [Announcement] {
        model.feed.filter { a in
            !hidden.contains(a.category) &&
                (search.isEmpty || a.title.localizedCaseInsensitiveContains(search) || a.spokenText.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if items.isEmpty {
                    ContentUnavailableView("Nothing yet", systemImage: "tray",
                                           description: Text("Announcements show up here, even ones that were only a tone or silent."))
                }
                ForEach(items) { a in
                    NavigationLink(value: a.id) { FeedRow(a: a) }
                        .swipeActions(edge: .leading) {
                            Button { model.say(a) } label: { Label("Speak", systemImage: "speaker.wave.2") }.tint(.blue)
                        }
                }
                .onDelete { idx in
                    model.deleteFeedItems(Set(idx.map { items[$0].id }))
                }
            }
            .listStyle(.plain)
            .searchable(text: $search)
            .navigationTitle("Feed")
            .navigationDestination(for: String.self) { id in
                if let a = model.feed.first(where: { $0.id == id }) { AnnouncementDetailView(a: a) } else { Text("Removed") }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(AnnouncementCategory.allCases, id: \.self) { c in
                            Button {
                                if hidden.contains(c) { hidden.remove(c) } else { hidden.insert(c) }
                            } label: {
                                if hidden.contains(c) { Text(c.label) } else { Label(c.label, systemImage: "checkmark") }
                            }
                        }
                        Divider()
                        Button("Show all") { hidden.removeAll() }
                    } label: {
                        Label("Filter", systemImage: hidden.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                }
            }
            .confirmationDialog("Clear the whole feed?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear feed", role: .destructive) { model.clearFeed() }
            }
            .onChange(of: model.openAnnouncementID) { _, id in
                guard let id else { return }
                path = NavigationPath()
                path.append(id)
                model.openAnnouncementID = nil
            }
        }
    }
}

struct FeedRow: View {
    var a: Announcement

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Theme.icon(for: a))
                .foregroundStyle(Theme.color(for: a))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(a.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Spacer()
                    Text(a.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
                Text(a.spokenText).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                HStack(spacing: 6) {
                    Pill(text: a.category.label, color: Theme.color(for: a))
                    if a.mode == .tone { Pill(text: "tone only") }
                    if a.mode == .notifyOnly { Pill(text: "silent") }
                    if a.priority >= 8 { Pill(text: "P\(a.priority)", color: .red) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct AnnouncementDetailView: View {
    @EnvironmentObject var model: AppModel
    var a: Announcement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: Theme.icon(for: a)).foregroundStyle(Theme.color(for: a)).font(.title2)
                    Text(a.title).font(.title3.bold())
                }
                Text("\(a.date.formatted(date: .abbreviated, time: .standard)) · \(a.category.label) · priority \(a.priority)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { model.say(a) } label: { Label("Speak", systemImage: "speaker.wave.2.fill") }
                        .buttonStyle(.borderedProminent)
                    if let link = a.link {
                        Link(destination: link) { Label("Open", systemImage: "safari") }
                            .buttonStyle(.bordered)
                    }
                    ShareLink(item: a.title + "\n\n" + a.spokenText + "\n\n" + a.detailText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
                GroupBox("What was said") {
                    Text(a.spokenText).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                if !a.detailText.isEmpty && a.detailText != a.spokenText {
                    GroupBox("Full text") {
                        ReadableText(a.detailText, sourceID: "feed-\(a.id)", title: a.title, speech: model.speech)
                    }
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AlertDetailView: View {
    @EnvironmentObject var model: AppModel
    var info: ActiveAlertInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(info.title).font(.title3.bold())
                HStack(spacing: 6) {
                    Pill(text: info.inRange ? "In range" : "Out of range", color: info.inRange ? .green : .secondary)
                    Pill(text: "Risk \(info.risk) – \(RiskIndex.label(info.risk))", color: Theme.riskColor(info.risk))
                    if info.inside { Pill(text: "You're inside", color: .red) }
                }
                if let p = info.path, let eta = p.etaMinutes {
                    Label("In the storm's path — arrival in about \(Int(eta)) min", systemImage: "arrow.right.to.line.compact")
                        .foregroundStyle(.red)
                }
                HStack {
                    Button { model.readAlert(info) } label: { Label("Read it", systemImage: "speaker.wave.2.fill") }
                        .buttonStyle(.borderedProminent)
                    if let link = info.alert.webLink {
                        Link(destination: link) { Label("Event page", systemImage: "safari") }.buttonStyle(.bordered)
                    }
                }
                detailGrid
                if let h = info.alert.nwsHeadline { GroupBox("Headline") { Text(h).frame(maxWidth: .infinity, alignment: .leading) } }
                GroupBox("Full text") {
                    ReadableText(([info.alert.description] + [info.alert.instruction ?? ""]).filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                 sourceID: "alert-\(info.alert.id)", title: info.alert.event, speech: model.speech)
                }
                GroupBox("Areas") { Text(info.alert.areaDesc).font(.footnote).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var detailGrid: some View {
        let a = info.alert
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            if let h = a.maxHailInches { row("Hail", "\(String(format: "%.2f", h))\" (\(a.hailBasis.rawValue.lowercased()))") }
            if let w = a.maxWindMPH { row("Wind", "\(w) mph (\(a.windBasis.rawValue.lowercased()))") }
            if a.tornadoDetection != .unknown { row("Tornado", a.tornadoDetection.rawValue.lowercased()) }
            if a.thunderstormDamage != .none { row("Damage threat", a.thunderstormDamage.spoken) }
            if a.tornadoDamage != .none { row("Tornado damage", a.tornadoDamage.spoken) }
            if let s = a.sourceText { row("Source", s) }
            if let m = a.motion { row("Motion", "\(Compass.abbreviation(for: m.headingDegrees)) at \(Int(m.speedMPH)) mph") }
            if let t = a.issuedTime { row("Issued", t.formatted(date: .omitted, time: .shortened)) }
            if let t = a.sent { row("Last update", t.formatted(date: .omitted, time: .shortened)) }
            if let t = a.endTime { row("Expires", t.formatted(date: .omitted, time: .shortened)) }
            row("Office", a.senderName)
        }
        .font(.subheadline)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v)
        }
    }
}
