import Foundation

/// Totals shown on the home screen.
enum TripStats {
    static func totalDistanceMeters(_ trips: [RecordedTrip]) -> Double {
        trips.reduce(0) { $0 + max(0, $1.distanceMeters) }
    }

    /// Distance of the trips that started on the same calendar day as `day`.
    static func distanceMeters(on day: Date, trips: [RecordedTrip], calendar: Calendar = .current) -> Double {
        trips
            .filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
            .reduce(0) { $0 + max(0, $1.distanceMeters) }
    }
}
