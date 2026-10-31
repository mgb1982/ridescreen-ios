import Foundation

struct GPSFix: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double
    let timestamp: Date
    let speedMetersPerSecond: Double
    let horizontalAccuracyMeters: Double
}

enum GPSFixRejection: String, Equatable, Sendable {
    case invalidAccuracy
    case inaccurate
    case stale
    case futureTimestamp
    case invalidCoordinate
    case implausibleSpeed
}

struct TripPoint: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double
    let timestamp: Date
    let speedMetersPerSecond: Double
    let horizontalAccuracyMeters: Double

    init(
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double,
        timestamp: Date,
        speedMetersPerSecond: Double,
        horizontalAccuracyMeters: Double
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.timestamp = timestamp
        self.speedMetersPerSecond = speedMetersPerSecond
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
    }

    init(fix: GPSFix, speedMetersPerSecond: Double) {
        latitude = fix.latitude
        longitude = fix.longitude
        altitudeMeters = fix.altitudeMeters
        timestamp = fix.timestamp
        self.speedMetersPerSecond = speedMetersPerSecond
        horizontalAccuracyMeters = fix.horizontalAccuracyMeters
    }
}

struct RecordedTrip: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let startedAt: Date
    var endedAt: Date?
    var distanceMeters: Double
    var movingTimeMilliseconds: Int64
    var maximumSpeedMetersPerSecond: Double
    var points: [TripPoint]

    var elapsedDuration: TimeInterval {
        max(0, (endedAt ?? Date()).timeIntervalSince(startedAt))
    }

    var pointCount: Int { points.count }

    var movingTime: TimeInterval {
        Double(movingTimeMilliseconds) / 1_000
    }
}

struct TripLiveMetrics: Equatable, Sendable {
    let elapsedSeconds: TimeInterval
    let distanceMeters: Double
    let currentSpeedMetersPerSecond: Double
    let maximumSpeedMetersPerSecond: Double
    let pointCount: Int
}

enum TripUpdate: Equatable, Sendable {
    case accepted(point: TripPoint, distanceAddedMeters: Double, currentSpeedMetersPerSecond: Double)
    case rejected(GPSFixRejection)

    var wasAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// Distance along a recorded route, computed from the stored points themselves.
enum TripGeometry {
    private static let earthRadiusMeters = 6_371_000.0

    static func distanceMeters(_ points: [TripPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            total += haversine(a.latitude, a.longitude, b.latitude, b.longitude)
        }
        return total
    }

    /// The stored total is trusted when it is positive; if it was lost (0) the route gives the distance.
    static func resolvedDistance(stored: Double, points: [TripPoint]) -> Double {
        stored > 0 ? stored : distanceMeters(points)
    }

    private static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad
        let dLon = (lon2 - lon1) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * rad) * cos(lat2 * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }
}
