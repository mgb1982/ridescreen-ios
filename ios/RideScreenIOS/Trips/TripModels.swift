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
