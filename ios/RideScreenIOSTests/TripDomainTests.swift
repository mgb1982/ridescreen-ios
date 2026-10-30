import XCTest
@testable import RideScreenIOS

final class TripProcessorTests: XCTestCase {
    func testRejectsInvalidAccuracyAndStaleFixes() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(GPSFixFilter.rejectionReason(for: fix(now, accuracy: -1), now: now), .invalidAccuracy)
        XCTAssertEqual(GPSFixFilter.rejectionReason(for: fix(now, accuracy: 50.01), now: now), .inaccurate)
        XCTAssertEqual(GPSFixFilter.rejectionReason(for: fix(now.addingTimeInterval(-10.1)), now: now), .stale)
    }

    func testAcceptsFixAtTenSecondBoundary() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(GPSFixFilter.rejectionReason(for: fix(now.addingTimeInterval(-10)), now: now))
    }

    func testUsesLocationSpeedWhenValidAndCalculatesWhenInvalid() {
        var tracker = TripTracker(startedAt: Date(timeIntervalSince1970: 100))
        let first = fix(Date(timeIntervalSince1970: 100), speed: 2)
        let second = fix(Date(timeIntervalSince1970: 104), speed: -1)
        _ = tracker.ingest(first, now: first.timestamp, segmentDistanceMeters: 0)
        let result = tracker.ingest(second, now: second.timestamp, segmentDistanceMeters: 8)
        guard case .accepted(_, _, let speed) = result else { return XCTFail("Expected accepted point") }
        XCTAssertEqual(speed, 2, accuracy: 0.001)
    }

    func testDoesNotAccumulateDistanceBelowHalfMeterPerSecond() {
        var tracker = TripTracker(startedAt: Date(timeIntervalSince1970: 100))
        let first = fix(Date(timeIntervalSince1970: 100), speed: 0.2)
        let second = fix(Date(timeIntervalSince1970: 110), speed: 0.49)
        _ = tracker.ingest(first, now: first.timestamp, segmentDistanceMeters: 0)
        let result = tracker.ingest(second, now: second.timestamp, segmentDistanceMeters: 30)
        guard case .accepted(_, let distance, _) = result else { return XCTFail("Expected accepted point") }
        XCTAssertEqual(distance, 0, accuracy: 0.001)
        XCTAssertEqual(tracker.trip.distanceMeters, 0, accuracy: 0.001)
    }

    func testAccumulatesDistanceAndTracksMaximumSpeed() {
        var tracker = TripTracker(startedAt: Date(timeIntervalSince1970: 100))
        for (index, speed) in [3.0, 10.0, 6.0].enumerated() {
            let date = Date(timeIntervalSince1970: 100 + Double(index + 1))
            _ = tracker.ingest(fix(date, speed: speed), now: date, segmentDistanceMeters: 5)
        }
        XCTAssertEqual(tracker.trip.distanceMeters, 15, accuracy: 0.001)
        XCTAssertEqual(tracker.trip.maximumSpeedMetersPerSecond, 10, accuracy: 0.001)
    }

    private func fix(_ date: Date, accuracy: Double = 5, speed: Double = 1) -> GPSFix {
        GPSFix(latitude: 41, longitude: 2, altitudeMeters: 120, timestamp: date,
               speedMetersPerSecond: speed, horizontalAccuracyMeters: accuracy)
    }
}

final class TripJournalStoreTests: XCTestCase {
    func testIncrementalJournalCanBeRecoveredAndFinalized() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let point = TripPoint(latitude: 41, longitude: 2, altitudeMeters: 120,
                              timestamp: start.addingTimeInterval(5), speedMetersPerSecond: 4,
                              horizontalAccuracyMeters: 6)
        let firstProcess = TripJournalStore(directoryURL: directory)
        try await firstProcess.begin(id: "test-trip", startedAt: start)
        try await firstProcess.append(point: point, distanceMeters: 20,
                                      movingTimeMilliseconds: 5_000, maximumSpeedMetersPerSecond: 4)
        try await firstProcess.flush()

        let restartedProcess = TripJournalStore(directoryURL: directory)
        let pending = try await restartedProcess.pendingTrips()
        XCTAssertEqual(pending.first?.points.count, 1)
        let restored = try await restartedProcess.resume(id: "test-trip")
        XCTAssertEqual(restored.points.count, 1)

        let completed = RecordedTrip(id: "test-trip", startedAt: start, endedAt: start.addingTimeInterval(8),
                                     distanceMeters: 20, movingTimeMilliseconds: 5_000,
                                     maximumSpeedMetersPerSecond: 4, points: [point])
        try await restartedProcess.finish(completed)

        let saved = try await restartedProcess.completedTrips()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.points.first?.altitudeMeters, 120)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("test-trip.jsonl").path))
    }

    func testCanDiscardAnInterruptedJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripJournalStore(directoryURL: directory)
        try await store.begin(id: "discard-me", startedAt: Date())
        try await store.discardPending(id: "discard-me")
        let pending = try await store.pendingTrips()
        XCTAssertTrue(pending.isEmpty)
    }
}

final class TripGPXExporterTests: XCTestCase {
    func testExportsGPX11AltitudeUTCAndSpeedExtension() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let trip = RecordedTrip(
            id: "gpx", startedAt: start, endedAt: start.addingTimeInterval(10),
            distanceMeters: 100, movingTimeMilliseconds: 10_000, maximumSpeedMetersPerSecond: 5,
            points: [TripPoint(latitude: 41.123456, longitude: 2.123456, altitudeMeters: 123.4,
                               timestamp: start.addingTimeInterval(5), speedMetersPerSecond: 4.2,
                               horizontalAccuracyMeters: 4)]
        )
        let xml = TripGPXExporter.xml(for: trip)
        XCTAssertTrue(xml.contains("<gpx version=\"1.1\""))
        XCTAssertTrue(xml.contains("<ele>123.400000</ele>"))
        XCTAssertTrue(xml.contains("<rs:speed unit=\"m/s\">4.200000</rs:speed>"))
        XCTAssertTrue(xml.contains("2023-11-14T22:13:25"))
    }
}
