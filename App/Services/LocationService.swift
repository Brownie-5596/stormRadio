import CoreLocation
import Combine

/// Wraps CLLocationManager. Continuous background updates also keep the app running while you drive.
@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var location: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    var onUpdate: ((CLLocation) -> Void)?

    private let manager = CLLocationManager()
    private(set) var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    var authorizationText: String {
        switch authorization {
        case .notDetermined: return "Not asked yet"
        case .restricted: return "Restricted"
        case .denied: return "Denied — enable in iOS Settings"
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While using (background OK while monitoring)"
        @unknown default: return "Unknown"
        }
    }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    /// `precise` = GPS mode (driving). Otherwise coarse updates that mainly keep the app alive.
    func start(precise: Bool) {
        requestPermission()
        manager.desiredAccuracy = precise ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyKilometer
        manager.distanceFilter = precise ? 75 : 500
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
        running = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        running = false
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.location = loc
            self.lastError = nil
            self.onUpdate?(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let text = error.localizedDescription
        Task { @MainActor in self.lastError = text }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if self.running, status == .authorizedAlways || status == .authorizedWhenInUse {
                self.manager.allowsBackgroundLocationUpdates = true
                self.manager.showsBackgroundLocationIndicator = true
                self.manager.startUpdatingLocation()
            }
        }
    }
}
