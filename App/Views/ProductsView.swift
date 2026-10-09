import SwiftUI
import MapKit
import StormRadioCore

/// Browse SPC and NWS products: mesoscale discussions, watches, outlooks, forecast discussions and storm reports.
struct ProductsView: View {
    @EnvironmentObject var model: AppModel
    @State private var section: Kind = .mds

    enum Kind: String, CaseIterable {
        case mds = "MDs", watches = "Watches", outlooks = "Outlooks", afd = "AFD", reports = "Reports"
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Products", selection: $section) {
                    ForEach(Kind.allCases, id: \.self) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                switch section {
                case .mds: mdList
                case .watches: watchList
                case .outlooks: outlookList
                case .afd: afdList
                case .reports: reportList
                }

                if let t = model.productsUpdated {
                    Text("Updated \(t.ago)").font(.caption).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Products")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.productsLoading {
                        ProgressView()
                    } else {
                        Button { Task { await model.refreshProducts() } } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .refreshable { await model.refreshProducts() }
            .task {
                if model.productsUpdated == nil && model.mds.isEmpty && model.outlooks.isEmpty { await model.refreshProducts() }
            }
        }
    }

    // MARK: Lists

    @ViewBuilder private var mdList: some View {
        let recent = model.mds.filter { Date().timeIntervalSince($0.issued) < 12 * 3600 }
        if recent.isEmpty { empty("No mesoscale discussions in the last 12 hours.") }
        ForEach(recent) { md in
            NavigationLink { MDDetailView(md: md) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("MD \(md.number)").font(.headline)
                        Spacer()
                        Text(md.issued.ago).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(md.areasAffected).font(.subheadline)
                    HStack(spacing: 6) {
                        if !md.concerning.isEmpty { Text(md.concerning.replacingOccurrences(of: "...", with: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        if let p = md.watchProbability { Pill(text: "Watch \(p)%", color: p >= 60 ? .red : p >= 40 ? .orange : .secondary) }
                    }
                    if let d = distanceText(md.shape) { Text(d).font(.caption).foregroundStyle(.blue) }
                }
            }
        }
    }

    @ViewBuilder private var watchList: some View {
        let recent = model.watches.filter { Date().timeIntervalSince($0.issued) < 18 * 3600 }
        if recent.isEmpty { empty("No SPC watches issued in the last 18 hours.") }
        ForEach(recent) { w in
            NavigationLink { WatchDetailView(watch: w) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Circle().fill(w.type.contains("Tornado") ? Color.red : Color.pink).frame(width: 10, height: 10)
                        Text("\(w.type) \(w.number)").font(.headline)
                        if w.isPDS { Pill(text: "PDS", color: .purple) }
                        Spacer()
                        Text(w.issued.ago).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(w.areas.joined(separator: ", ")).font(.subheadline).lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder private var outlookList: some View {
        let days = model.outlooks.keys.sorted()
        if days.isEmpty { empty("Outlooks haven't been downloaded yet. Pull down to refresh.") }
        ForEach(days, id: \.self) { d in
            if let o = model.outlooks[d] {
                NavigationLink { OutlookDetailView(outlook: o) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Day \(d) convective outlook").font(.headline)
                            Text("Highest: \(o.maxCategory.label)").font(.subheadline)
                            Text("Issued \(o.issued.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(o.maxCategory.rawValue).font(.caption.bold()).padding(6)
                            .background(categoryColor(o.maxCategory).opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    @ViewBuilder private var afdList: some View {
        let offices = model.afds.keys.sorted()
        if offices.isEmpty {
            empty(model.profile.afd.enabled ? "No forecast discussion yet. It needs your location (or a fixed point) to find your NWS office, or add offices in Settings › Forecast discussions."
                                            : "Forecast discussions are turned off for this profile (Settings › Forecast discussions).")
        }
        ForEach(offices, id: \.self) { o in
            if let afd = model.afds[o] {
                NavigationLink { AFDDetailView(afd: afd) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NWS \(StormMonitor.officeName(from: afd.rawText) ?? o)").font(.headline)
                        Text("\(afd.sections.count) sections · issued \(afd.issued.ago)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var reportList: some View {
        let reports = model.reports
        if reports.isEmpty { empty("No storm reports in your area in the last 3 hours.") }
        ForEach(reports.prefix(100)) { r in
            NavigationLink { ReportDetailView(report: r) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Theme.icon(forReport: r.category)).foregroundStyle(Theme.color(forReport: r.category)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ReportPhraser(settings: model.profile.reports, phrasing: model.profile.phrasing).title(r, from: model.currentReferencePoint))
                            .font(.subheadline.weight(.semibold))
                        Text("\(r.source.label) · \(r.place ?? "") · \(r.eventTime.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).listRowSeparator(.hidden)
    }

    private func distanceText(_ shape: GeoShape?) -> String? {
        guard let s = shape, let ref = model.currentReferencePoint, let d = Geo.distance(from: ref, to: s) else { return nil }
        if d.inside { return "Includes your location" }
        return "\(Int(d.miles.rounded())) mi \(Compass.abbreviation(for: Geo.bearing(from: ref, to: d.nearest))) of you"
    }
}

func categoryColor(_ c: OutlookCategory) -> Color {
    switch c {
    case .high: return .pink
    case .mdt: return .red
    case .enh: return .orange
    case .slgt: return .yellow
    case .mrgl: return .green
    case .tstm: return .mint
    case .none: return .gray
    }
}

// MARK: - Shared pieces

/// Remote image with loading/error states; tap to view full screen (pinch to zoom).
struct ProductImage: View {
    let url: URL
    @State private var full = false

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { full = true }
            case .failure:
                Label("Image not available", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            default:
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .fullScreenCover(isPresented: $full) {
            ZoomableImage(url: url) { full = false }
        }
    }
}

struct ZoomableImage: View {
    let url: URL
    var close: () -> Void
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { img in
                img.resizable().scaledToFit()
                    .scaleEffect(scale * pinch)
                    .gesture(MagnificationGesture().updating($pinch) { v, s, _ in s = v }.onEnded { v in scale = max(1, min(5, scale * v)) })
                    .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
            } placeholder: { ProgressView() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.85))
            }
            .padding()
        }
    }
}

struct ShapeMap: View {
    let ring: [GeoPoint]
    var color: Color = .blue
    var reference: GeoPoint?

    var body: some View {
        let center = Geo.centroid(GeoShape(ring: ring)) ?? GeoPoint(lat: 38, lon: -97)
        let b = Geo.bounds(ring + (reference.map { [$0] } ?? []))
        let span = b.map { MKCoordinateSpan(latitudeDelta: max(1, ($0.maxLat - $0.minLat) * 1.4), longitudeDelta: max(1, ($0.maxLon - $0.minLon) * 1.4)) }
            ?? MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
        Map(initialPosition: .region(MKCoordinateRegion(center: center.coordinate, span: span))) {
            MapPolygon(coordinates: ring.map { $0.coordinate }).foregroundStyle(color.opacity(0.2)).stroke(color, lineWidth: 2)
            if let r = reference {
                Annotation("You", coordinate: r.coordinate) { Image(systemName: "location.circle.fill").foregroundStyle(.blue) }
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Detail views

struct MDDetailView: View {
    @EnvironmentObject var model: AppModel
    let md: MesoscaleDiscussion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Mesoscale Discussion \(md.number)").font(.title3.bold())
                Text(md.areasAffected).font(.headline)
                Text("Concerning: \(md.concerning.replacingOccurrences(of: "...", with: " · "))").font(.subheadline)
                HStack(spacing: 8) {
                    if let p = md.watchProbability { Pill(text: "Watch probability \(p)%", color: p >= 60 ? .red : .orange) }
                    Text("Issued \(md.issued.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        model.speech.speakNow(Announcement(date: Date(), category: .summary, title: "MD \(md.number)",
                                                           spokenText: md.announcement(from: model.currentReferencePoint, compass: model.profile.phrasing.compass, readSummary: true),
                                                           priority: 5, notify: false))
                    } label: { Label("Read summary", systemImage: "speaker.wave.2.fill") }
                        .buttonStyle(.borderedProminent)
                    if let link = md.link { Link(destination: link) { Label("SPC page", systemImage: "safari") }.buttonStyle(.bordered) }
                }
                if let img = md.imageURL { ProductImage(url: img) }
                if md.polygon.count >= 3 { ShapeMap(ring: md.polygon, color: .blue, reference: model.currentReferencePoint) }
                if let t = md.peakTornado { LabeledContent("Peak tornado", value: t) }
                if let w = md.peakWind { LabeledContent("Peak wind", value: w) }
                if let h = md.peakHail { LabeledContent("Peak hail", value: h) }
                GroupBox("Full text") {
                    ReadableText(md.rawText, sourceID: "md-\(md.id)", title: "MD \(md.number)", speech: model.speech)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WatchDetailView: View {
    @EnvironmentObject var model: AppModel
    let watch: SPCWatch

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("\(watch.type) \(watch.number)").font(.title3.bold())
                    if watch.isPDS { Pill(text: "PDS", color: .purple) }
                }
                Text(watch.areas.joined(separator: ", ")).font(.headline)
                if !watch.effective.isEmpty { Text(watch.effective).font(.subheadline) }
                HStack {
                    Button {
                        model.speech.speakNow(Announcement(date: Date(), category: .summary, title: "\(watch.type) \(watch.number)",
                                                           spokenText: watch.announcement(readThreats: true), priority: 5, notify: false))
                    } label: { Label("Read summary", systemImage: "speaker.wave.2.fill") }
                        .buttonStyle(.borderedProminent)
                    if let link = watch.link { Link(destination: link) { Label("SPC page", systemImage: "safari") }.buttonStyle(.bordered) }
                }
                if let img = watch.imageURL { ProductImage(url: img) }
                if !watch.threats.isEmpty {
                    GroupBox("Primary threats") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(watch.threats, id: \.self) { t in Text("• \(t)").frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }
                }
                GroupBox("Full text") {
                    ReadableText(watch.rawText, sourceID: "ww-\(watch.id)", title: "\(watch.type) \(watch.number)", speech: model.speech)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct OutlookDetailView: View {
    @EnvironmentObject var model: AppModel
    let outlook: OutlookSummary
    @State private var imageIndex = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Day \(outlook.day) Convective Outlook").font(.title3.bold())
                Text("Highest risk: \(outlook.maxCategory.label)").font(.headline)
                HStack {
                    Button { model.readOutlook(day: outlook.day) } label: { Label("Read summary", systemImage: "speaker.wave.2.fill") }
                        .buttonStyle(.borderedProminent)
                    if let link = outlook.link { Link(destination: link) { Label("SPC page", systemImage: "safari") }.buttonStyle(.bordered) }
                }
                let images = outlook.imageLinks
                if !images.isEmpty {
                    Picker("Map", selection: $imageIndex) {
                        ForEach(images.indices, id: \.self) { i in Text(images[i].0).tag(i) }
                    }
                    .pickerStyle(.segmented)
                    ProductImage(url: images[min(imageIndex, images.count - 1)].1).id(imageIndex)
                    Text("SPC's current Day \(outlook.day) graphics.").font(.caption2).foregroundStyle(.secondary)
                }
                GroupBox("Full text") {
                    ReadableText(outlook.rawText, sourceID: "otlk-\(outlook.id)", title: "Day \(outlook.day) outlook", speech: model.speech)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AFDDetailView: View {
    @EnvironmentObject var model: AppModel
    let afd: AreaForecastDiscussion

    var body: some View {
        let name = StormMonitor.officeName(from: afd.rawText) ?? afd.office
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Area Forecast Discussion").font(.title3.bold())
                Text("NWS \(name) · \(afd.issued.formatted(date: .abbreviated, time: .shortened))").font(.subheadline)
                HStack {
                    Button { model.readAFD() } label: { Label("Read my sections", systemImage: "speaker.wave.2.fill") }
                        .buttonStyle(.borderedProminent)
                    if let link = afd.link { Link(destination: link) { Label("NWS page", systemImage: "safari") }.buttonStyle(.bordered) }
                }
                ForEach(afd.sections, id: \.name) { s in
                    DisclosureGroup {
                        ReadableText(s.text, sourceID: "afd-\(afd.id)-\(s.name)", title: "\(name) AFD \(s.name.capitalized)", speech: model.speech)
                            .padding(.top, 6)
                    } label: {
                        Text(s.name.capitalized).font(.headline)
                    }
                    Divider()
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ReportDetailView: View {
    @EnvironmentObject var model: AppModel
    let report: StormReport

    var body: some View {
        let phr = ReportPhraser(settings: model.profile.reports, phrasing: model.profile.phrasing)
        let spoken = phr.compose(report, from: model.currentReferencePoint, now: Date())
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(phr.title(report, from: model.currentReferencePoint)).font(.title3.bold())
                Button {
                    model.speech.speakNow(Announcement(date: Date(), category: .report, title: report.category.label, spokenText: spoken, priority: 5, notify: false))
                } label: { Label("Read it", systemImage: "speaker.wave.2.fill") }
                    .buttonStyle(.borderedProminent)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("Source").foregroundStyle(.secondary); Text(report.source.label) }
                    GridRow { Text("Type").foregroundStyle(.secondary); Text(report.typeText) }
                    if let m = report.magnitude { GridRow { Text("Magnitude").foregroundStyle(.secondary); Text("\(String(format: "%g", m)) \(report.unit ?? "")") } }
                    if let w = report.reporter { GridRow { Text("Reported by").foregroundStyle(.secondary); Text(w) } }
                    if let p = report.place { GridRow { Text("Location").foregroundStyle(.secondary); Text(p) } }
                    GridRow { Text("Happened").foregroundStyle(.secondary); Text(report.eventTime.formatted(date: .omitted, time: .shortened)) }
                    if let r = report.releasedTime { GridRow { Text("Released").foregroundStyle(.secondary); Text(r.formatted(date: .omitted, time: .shortened)) } }
                }
                .font(.subheadline)
                if let rem = report.remark, !rem.isEmpty { GroupBox("Remarks") { Text(rem).frame(maxWidth: .infinity, alignment: .leading) } }
                Map(initialPosition: .region(MKCoordinateRegion(center: report.point.coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000))) {
                    Marker(report.category.label, systemImage: Theme.icon(forReport: report.category), coordinate: report.point.coordinate)
                        .tint(Theme.color(forReport: report.category))
                    UserAnnotation()
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if let link = report.webLink { Link("Open source website", destination: link) }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
