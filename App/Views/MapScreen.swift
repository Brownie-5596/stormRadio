import SwiftUI
import MapKit
import StormRadioCore

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    init(_ c: CLLocationCoordinate2D) { self.init(lat: c.latitude, lon: c.longitude) }
}

/// Map of active alerts, storm reports, mesoscale discussions and your monitoring area.
struct MapScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: [ActiveAlertInfo] = []
    @State private var showSheet = false
    @State private var showReports = true
    @State private var showMDs = true
    @State private var showOutOfRange = true

    private var alerts: [ActiveAlertInfo] {
        model.activeAlerts.filter { ($0.inRange || showOutOfRange) && $0.alert.geometry != nil }.prefix(150).map { $0 }
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()
                    areaContent
                    ForEach(alerts) { info in
                        let color = Theme.color(forEvent: info.alert.event)
                        ForEach(Array((info.alert.geometry?.polygons ?? []).enumerated()), id: \.offset) { _, poly in
                            MapPolygon(coordinates: poly.outer.map { $0.coordinate })
                                .foregroundStyle(color.opacity(info.inRange ? 0.25 : 0.10))
                                .stroke(color, lineWidth: info.inRange ? 2 : 1)
                        }
                    }
                    if showMDs {
                        ForEach(model.mds.filter { Date().timeIntervalSince($0.issued) < 4 * 3600 && $0.polygon.count >= 3 }) { md in
                            MapPolyline(coordinates: (md.polygon + [md.polygon[0]]).map { $0.coordinate })
                                .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            if let c = md.shape.flatMap(Geo.centroid) {
                                Annotation("MD \(md.number)", coordinate: c.coordinate) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .padding(4).background(.blue.opacity(0.8), in: Circle()).foregroundStyle(.white)
                                }
                            }
                        }
                    }
                    if showReports {
                        ForEach(model.reports.prefix(200)) { r in
                            Annotation(r.category.label, coordinate: r.point.coordinate) {
                                Image(systemName: Theme.icon(forReport: r.category))
                                    .font(.caption)
                                    .padding(5)
                                    .background(Theme.color(forReport: r.category), in: Circle())
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                .onTapGesture { pt in
                    guard let c = proxy.convert(pt, from: .local) else { return }
                    let p = GeoPoint(c)
                    selected = model.activeAlerts.filter { $0.alert.geometry.map { Geo.contains($0, p) } ?? false }
                    showSheet = !selected.isEmpty
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Storm reports", isOn: $showReports)
                        Toggle("Mesoscale discussions", isOn: $showMDs)
                        Toggle("Alerts outside my distances", isOn: $showOutOfRange)
                    } label: { Image(systemName: "square.3.layers.3d") }
                }
            }
            .sheet(isPresented: $showSheet) {
                NavigationStack {
                    List(selected) { info in
                        NavigationLink { AlertDetailView(info: info) } label: { AlertRow(info: info) }
                    }
                    .navigationTitle("Alerts here")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    @MapContentBuilder
    private var areaContent: some MapContent {
        let loc = model.profile.location
        if loc.areaMode == .polygon, loc.polygon.count >= 3 {
            MapPolyline(coordinates: (loc.polygon + [loc.polygon[0]]).map { $0.coordinate })
                .stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
        } else if let ref = model.currentReferencePoint {
            MapCircle(center: ref.coordinate, radius: loc.radiusMiles * 1609.344)
                .foregroundStyle(.clear)
                .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        }
        if loc.mode == .fixed, let p = loc.fixedPoint {
            Annotation(loc.fixedName.isEmpty ? "Fixed point" : loc.fixedName, coordinate: p.coordinate) {
                Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(.red)
            }
        }
    }
}
