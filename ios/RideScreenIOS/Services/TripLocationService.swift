import Combine
import CoreLocation
import Foundation

@MainActor
final class TripLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var latestSpeedKmh: Double?

    var onLocation: ((GPSFix, Double?) -> Bool)?
    var onAuthorizationChanged: ((CLAuthorizationStatus) -> Void)?
    var onError: ((String) -> Void)?

    private let manager: CLLocationManager
    private var lastAcceptedLocation: CLLocation?
    private var latestLocation: CLLocation?
    private var safetyMonitoring = false

    override init() {
        manager = CLLocationManager()
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.distanceFilter = kCLDistanceFilterNone
    }

    var servicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func startUpdating(backgroundAllowed: Bool) {
        let canRunInBackground = backgroundAllowed && authorizationStatus == .authorizedAlways
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = canRunInBackground
        manager.showsBackgroundLocationIndicator = canRunInBackground
        manager.startUpdatingLocation()
    }

    func stopUpdating() {
        if !safetyMonitoring { manager.stopUpdatingLocation() }
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        lastAcceptedLocation = nil
    }

    func startSafetyMonitoring() {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
        safetyMonitoring = true
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        manager.startUpdatingLocation()
    }

    func stopSafetyMonitoring() {
        safetyMonitoring = false
        guard !manager.allowsBackgroundLocationUpdates else { return }
        manager.stopUpdatingLocation()
    }

    func freshSpeedKmh(maxAge: TimeInterval = 10, now: Date = Date()) -> Double? {
        guard let latestLocation, now.timeIntervalSince(latestLocation.timestamp) <= maxAge,
              latestLocation.speed >= 0, latestLocation.horizontalAccuracy >= 0,
              latestLocation.horizontalAccuracy <= 50 else { return nil }
        return latestLocation.speed * 3.6
    }

    func restorePreviousPoint(_ point: TripPoint?) {
        guard let point else {
            lastAcceptedLocation = nil
            return
        }
        lastAcceptedLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
            altitude: point.altitudeMeters,
            horizontalAccuracy: point.horizontalAccuracyMeters,
            verticalAccuracy: -1,
            course: -1,
            speed: point.speedMetersPerSecond,
            timestamp: point.timestamp
        )
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        onAuthorizationChanged?(authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            latestLocation = location
            latestSpeedKmh = location.speed >= 0 && location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 50
                ? location.speed * 3.6 : nil
            let fix = GPSFix(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitudeMeters: location.altitude,
                timestamp: location.timestamp,
                speedMetersPerSecond: location.speed,
                horizontalAccuracyMeters: location.horizontalAccuracy
            )
            let segmentDistance = lastAcceptedLocation.map { $0.distance(from: location) }
            if onLocation?(fix, segmentDistance) == true {
                lastAcceptedLocation = location
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onError?(error.localizedDescription)
    }
}

