import Combine
import CoreLocation
import Foundation

@MainActor
final class TripLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    var onLocation: ((GPSFix, Double?) -> Bool)?
    var onAuthorizationChanged: ((CLAuthorizationStatus) -> Void)?
    var onError: ((String) -> Void)?

    private let manager: CLLocationManager
    private var lastAcceptedLocation: CLLocation?

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
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        lastAcceptedLocation = nil
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
