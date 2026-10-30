import Foundation

enum GPSFixFilter {
    static let maximumHorizontalAccuracyMeters = 50.0
    static let maximumAgeSeconds = 10.0

    static func rejectionReason(for fix: GPSFix, now: Date) -> GPSFixRejection? {
        guard fix.horizontalAccuracyMeters >= 0 else { return .invalidAccuracy }
        guard fix.horizontalAccuracyMeters <= maximumHorizontalAccuracyMeters else { return .inaccurate }

        let age = now.timeIntervalSince(fix.timestamp)
        guard age <= maximumAgeSeconds else { return .stale }
        guard age >= -maximumAgeSeconds else { return .futureTimestamp }

        guard fix.latitude.isFinite,
              fix.longitude.isFinite,
              (-90.0...90.0).contains(fix.latitude),
              (-180.0...180.0).contains(fix.longitude),
              fix.altitudeMeters.isFinite else {
            return .invalidCoordinate
        }
        return nil
    }
}

/// Pure trip processing. The platform adapter supplies the segment distance calculated with
/// CLLocation.distance(from:); no CoreLocation object crosses into this domain type.
struct TripTracker: Sendable {
    static let minimumMovingSpeedMetersPerSecond = 0.5

    private(set) var trip: RecordedTrip
    private(set) var currentSpeedMetersPerSecond = 0.0
    private(set) var lastAcceptedFix: GPSFix?

    init(id: String = UUID().uuidString, startedAt: Date = Date()) {
        trip = RecordedTrip(
            id: id,
            startedAt: startedAt,
            endedAt: nil,
            distanceMeters: 0,
            movingTimeMilliseconds: 0,
            maximumSpeedMetersPerSecond: 0,
            points: []
        )
    }

    init(restoring trip: RecordedTrip) {
        self.trip = trip
        if let last = trip.points.last {
            lastAcceptedFix = GPSFix(
                latitude: last.latitude,
                longitude: last.longitude,
                altitudeMeters: last.altitudeMeters,
                timestamp: last.timestamp,
                speedMetersPerSecond: last.speedMetersPerSecond,
                horizontalAccuracyMeters: last.horizontalAccuracyMeters
            )
            currentSpeedMetersPerSecond = last.speedMetersPerSecond
        }
    }

    mutating func ingest(
        _ fix: GPSFix,
        now: Date = Date(),
        segmentDistanceMeters: Double?
    ) -> TripUpdate {
        if let reason = GPSFixFilter.rejectionReason(for: fix, now: now) {
            return .rejected(reason)
        }

        let previous = lastAcceptedFix
        let interval = previous.map { fix.timestamp.timeIntervalSince($0.timestamp) } ?? 0
        let segmentDistance = segmentDistanceMeters.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        } ?? 0

        let speed: Double
        if fix.speedMetersPerSecond.isFinite && fix.speedMetersPerSecond >= 0 {
            speed = fix.speedMetersPerSecond
        } else if interval > 0 {
            speed = segmentDistance / interval
        } else {
            speed = 0
        }

        let point = TripPoint(fix: fix, speedMetersPerSecond: speed)
        let distanceAdded = speed >= Self.minimumMovingSpeedMetersPerSecond ? segmentDistance : 0

        if distanceAdded > 0 {
            trip.distanceMeters += distanceAdded
            trip.movingTimeMilliseconds += Int64((max(0, interval) * 1_000).rounded())
        }

        trip.maximumSpeedMetersPerSecond = max(trip.maximumSpeedMetersPerSecond, speed)
        trip.points.append(point)
        lastAcceptedFix = fix
        currentSpeedMetersPerSecond = speed

        return .accepted(
            point: point,
            distanceAddedMeters: distanceAdded,
            currentSpeedMetersPerSecond: speed
        )
    }

    func liveMetrics(now: Date = Date()) -> TripLiveMetrics {
        TripLiveMetrics(
            elapsedSeconds: max(0, now.timeIntervalSince(trip.startedAt)),
            distanceMeters: trip.distanceMeters,
            currentSpeedMetersPerSecond: currentSpeedMetersPerSecond,
            maximumSpeedMetersPerSecond: trip.maximumSpeedMetersPerSecond,
            pointCount: trip.points.count
        )
    }

    func completed(at date: Date = Date()) -> RecordedTrip {
        var result = trip
        result.endedAt = date
        return result
    }
}
