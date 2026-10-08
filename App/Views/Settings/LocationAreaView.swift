import SwiftUI
import MapKit
import CoreLocation
import StormRadioCore

struct LocationAreaView: View {
    @EnvironmentObject var model: AppModel
    @Binding var profile: Profile
    @State private var search = ""
    @State private var searchMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Listen from", selection: $profile.location.mode) {
                    ForEach(LocationMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Where you are")
            } footer: {
                Text("GPS follows you while chasing (and enables \"you entered a warning\"). A fixed point listens to one place, like home or a target town.")
            }

            if profile.location.mode == .fixed {
                Section("Fixed point") {
                    TextField("Name (e.g. Home)", text: $profile.location.fixedName)
                    if let p = profile.location.fixedPoint {
                        LabeledContent("Point", value: String(format: "%.4f, %.4f", p.lat, p.lon))
                    } else {
                        Text("Not set — GPS is used until you pick a point.").foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("Search a town or address", text: $search)
                            .onSubmit(geocode)
                        Button("Find", action: geocode).disabled(search.isEmpty)
                    }
                    if let m = searchMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                    Button {
                        if let l = model.location.location {
                            profile.location.fixedPoint = GeoPoint(l.coordinate)
                        }
                    } label: { Label("Use my current location", systemImage: "location") }
                        .disabled(model.location.location == nil)
                    NavigationLink {
                        AreaEditorView(location: $profile.location, editing: .point)
                    } label: { Label("Pick on map", systemImage: "mappin.and.ellipse") }
                }
            }

            Section {
                Picker("Area type", selection: $profile.location.areaMode) {
                    ForEach(AreaMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                if profile.location.areaMode == .radius {
                    MilesField(title: "Radius", miles: $profile.location.radiusMiles, range: 5...400, zeroLabel: nil)
                } else {
                    TextField("Area name (optional)", text: $profile.location.polygonName)
                    LabeledContent("Points", value: "\(profile.location.polygon.count)")
                    NavigationLink {
                        AreaEditorView(location: $profile.location, editing: .polygon)
                    } label: { Label(profile.location.polygon.count >= 3 ? "Edit polygon / box" : "Draw polygon / box", systemImage: "pencil.and.outline") }
                }
            } header: {
                Text("Monitoring area")
            } footer: {
                if profile.location.areaMode == .radius {
                    Text("The outer limit. Each warning type also has its own distance (Warnings & watches) — the smaller one wins, so a Special Weather Statement 100 miles away stays quiet.")
                } else {
                    Text("Anything touching the polygon is announced (per-type distances are not used in polygon mode). Distances and directions are still spoken from your GPS position or fixed point.")
                }
            }
        }
        .navigationTitle("Location & area")
    }

    private func geocode() {
        let q = search
        searchMessage = "Searching…"
        CLGeocoder().geocodeAddressString(q) { places, error in
            DispatchQueue.main.async {
                guard let p = places?.first, let loc = p.location else {
                    searchMessage = error?.localizedDescription ?? "Not found"
                    return
                }
                profile.location.fixedPoint = GeoPoint(loc.coordinate)
                if profile.location.fixedName.isEmpty { profile.location.fixedName = p.locality ?? q }
                searchMessage = "Set to \(p.locality ?? q), \(p.administrativeArea ?? "")"
            }
        }
    }
}

/// Map editor for the fixed point or the custom polygon / box.
struct AreaEditorView: View {
    enum Editing { case point, polygon }
    enum DrawShape: String, CaseIterable { case polygon = "Polygon", box = "Box" }

    @EnvironmentObject var model: AppModel
    @Binding var location: LocationSettings
    var editing: Editing
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var shape: DrawShape = .polygon
    @State private var boxStart: GeoPoint?

    var body: some View {
        VStack(spacing: 0) {
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()
                    if editing == .point, let p = location.fixedPoint {
                        Annotation("Fixed point", coordinate: p.coordinate) {
                            Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.red)
                        }
                    }
                    if editing == .polygon {
                        if location.polygon.count >= 3 {
                            MapPolygon(coordinates: location.polygon.map { $0.coordinate })
                                .foregroundStyle(.orange.opacity(0.2))
                                .stroke(.orange, lineWidth: 2)
                        } else if location.polygon.count == 2 {
                            MapPolyline(coordinates: location.polygon.map { $0.coordinate }).stroke(.orange, lineWidth: 2)
                        }
                        ForEach(Array(location.polygon.enumerated()), id: \.offset) { i, p in
                            Annotation("\(i + 1)", coordinate: p.coordinate) {
                                Circle().fill(.orange).frame(width: 12, height: 12)
                            }
                        }
                        if let b = boxStart {
                            Annotation("Corner", coordinate: b.coordinate) {
                                Image(systemName: "plus.circle.fill").foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .onTapGesture { pt in
                    guard let c = proxy.convert(pt, from: .local) else { return }
                    tapped(GeoPoint(c))
                }
            }
            controls
        }
        .navigationTitle(editing == .point ? "Pick fixed point" : "Draw area")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if editing == .point, let p = location.fixedPoint {
                camera = .region(MKCoordinateRegion(center: p.coordinate, latitudinalMeters: 80_000, longitudinalMeters: 80_000))
            } else if editing == .polygon, let c = Geo.centroid(GeoShape(ring: location.polygon)), location.polygon.count >= 3 {
                camera = .region(MKCoordinateRegion(center: c.coordinate, latitudinalMeters: 400_000, longitudinalMeters: 400_000))
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if editing == .point {
                Text("Tap the map to set the point.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Picker("Shape", selection: $shape) {
                    ForEach(DrawShape.allCases, id: \.self) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                Text(shape == .polygon ? "Tap to add corners in order." : "Tap two opposite corners of the box.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Undo") { if !location.polygon.isEmpty { location.polygon.removeLast() } }
                        .disabled(location.polygon.isEmpty)
                    Spacer()
                    Button("Clear", role: .destructive) { location.polygon.removeAll(); boxStart = nil }
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private func tapped(_ p: GeoPoint) {
        switch editing {
        case .point:
            location.fixedPoint = p
        case .polygon:
            if shape == .polygon {
                location.polygon.append(p)
            } else if let a = boxStart {
                location.polygon = [
                    GeoPoint(lat: max(a.lat, p.lat), lon: min(a.lon, p.lon)), GeoPoint(lat: max(a.lat, p.lat), lon: max(a.lon, p.lon)),
                    GeoPoint(lat: min(a.lat, p.lat), lon: max(a.lon, p.lon)), GeoPoint(lat: min(a.lat, p.lat), lon: min(a.lon, p.lon)),
                ]
                boxStart = nil
            } else {
                boxStart = p
                location.polygon.removeAll()
            }
        }
    }
}
