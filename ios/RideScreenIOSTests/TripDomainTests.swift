import XCTest
@testable import RideScreenIOS

final class TripProcessorTests: XCTestCase {
    func testPKEReadFramesAndReplyParsing() {
        XCTAssertEqual(String(data: PKEProtocol.frame(code: "placeholder", command: "008"), encoding: .utf8), "*BT,placeholder,10,008#")
        XCTAssertEqual(PKEProtocol.voltage("*AT,redacted,10,008,01020304,126,0#"), 12.6)
        XCTAssertEqual(PKEProtocol.challenge("*AT,redacted,10,008,01020304,126,0#"), Data([1, 2, 3, 4]))
        XCTAssertEqual(PKEProtocol.locked("*AT,redacted,10,001,7,1#"), true)
        XCTAssertEqual(PKEProtocol.locked("*AT,redacted,10,001,7,2#"), false)
        XCTAssertNil(PKEProtocol.locked("*AT,redacted,10,001,1,1#"))
    }

    /// Synthetic McuID/code (not a real bike). Expected values were computed with an independent
    /// AES-128/ECB implementation following Android's PkeUnlock.derive (same key, XOR of the last
    /// four bytes with the challenge, 15-byte zero-padded code block).
    func testPKEDeriveKnownVectorMatchesAndroidAlgorithm() {
        let mcu = "00112233445566778899AABBCCDDEEFF"
        let challenge = Data([1, 2, 3, 4])
        let cipher = PKEProtocol.derive(code: "12345678", mcuID: mcu, challenge: challenge)
        XCTAssertEqual(cipher?.map { String(format: "%02X", $0) }.joined(), "64CC87EC467F68388B397F9041A30202")
        // Codes longer than 15 bytes are truncated to 15, like on Android.
        let long = PKEProtocol.derive(code: "1234567890123456789", mcuID: mcu, challenge: challenge)
        XCTAssertEqual(long?.map { String(format: "%02X", $0) }.joined(), "9EFCDBFC16462E8F7A74317E21405559")
        XCTAssertEqual(
            String(data: PKEProtocol.actionFrame(code: "12345678", action: .unlock, cipher: cipher!), encoding: .utf8),
            "*BT,12345678,10,001,2,64CC87EC467F68388B397F9041A30202#"
        )
    }

    func testPKERejectsMalformedCredentialAndChallenge() {
        XCTAssertFalse(PKEProtocol.validMcuID("not-a-device-id"))
        XCTAssertNil(PKEProtocol.challenge("*AT,redacted,10,008,not-hex,126,0#"))
        XCTAssertNil(PKEProtocol.derive(code: "placeholder", mcuID: "not-a-device-id", challenge: Data([1, 2, 3, 4])))
    }

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
        let startingFix = fix(Date(timeIntervalSince1970: 100), speed: 0)
        _ = tracker.ingest(startingFix, now: startingFix.timestamp, segmentDistanceMeters: 0)
        for (index, speed) in [3.0, 10.0, 6.0].enumerated() {
            let date = Date(timeIntervalSince1970: 101 + Double(index))
            _ = tracker.ingest(fix(date, speed: speed), now: date, segmentDistanceMeters: 5)
        }
        XCTAssertEqual(tracker.trip.distanceMeters, 15, accuracy: 0.001)
        XCTAssertEqual(tracker.trip.maximumSpeedMetersPerSecond, 10, accuracy: 0.001)
    }

    func testIgnoresAbsurdColdStartSpeedAndRejectsTeleportJumps() {
        var tracker = TripTracker(startedAt: Date(timeIntervalSince1970: 100))
        let first = fix(Date(timeIntervalSince1970: 100), speed: 300)
        let result = tracker.ingest(first, now: first.timestamp, segmentDistanceMeters: 0)
        guard case .accepted(_, _, let speed) = result else { return XCTFail("Expected accepted point") }
        XCTAssertEqual(speed, 0, accuracy: 0.001)
        XCTAssertEqual(tracker.trip.maximumSpeedMetersPerSecond, 0, accuracy: 0.001)

        let jump = fix(Date(timeIntervalSince1970: 101), speed: 3)
        XCTAssertEqual(tracker.ingest(jump, now: jump.timestamp, segmentDistanceMeters: 900), .rejected(.implausibleSpeed))
        XCTAssertEqual(tracker.trip.distanceMeters, 0, accuracy: 0.001)

        let coldStartSpike = fix(Date(timeIntervalSince1970: 101), speed: 34.17)
        let spikeResult = tracker.ingest(coldStartSpike, now: coldStartSpike.timestamp, segmentDistanceMeters: 2)
        guard case .accepted(_, _, let spikeSpeed) = spikeResult else { return XCTFail("Expected accepted location with filtered speed") }
        XCTAssertEqual(spikeSpeed, 0, accuracy: 0.001)
        XCTAssertEqual(tracker.trip.maximumSpeedMetersPerSecond, 0, accuracy: 0.001)
    }

    func testResolvedDistanceFallsBackToStoredPoints() {
        // 0.001 degrees of latitude is about 111 m.
        let points = [
            TripPoint(latitude: 41.000, longitude: 2, altitudeMeters: 0, timestamp: Date(timeIntervalSince1970: 1), speedMetersPerSecond: 1, horizontalAccuracyMeters: 5),
            TripPoint(latitude: 41.001, longitude: 2, altitudeMeters: 0, timestamp: Date(timeIntervalSince1970: 2), speedMetersPerSecond: 1, horizontalAccuracyMeters: 5),
            TripPoint(latitude: 41.002, longitude: 2, altitudeMeters: 0, timestamp: Date(timeIntervalSince1970: 3), speedMetersPerSecond: 1, horizontalAccuracyMeters: 5),
        ]
        XCTAssertEqual(TripGeometry.distanceMeters(points), 222.4, accuracy: 1)
        XCTAssertEqual(TripGeometry.resolvedDistance(stored: 0, points: points), 222.4, accuracy: 1)
        XCTAssertEqual(TripGeometry.resolvedDistance(stored: 150, points: points), 150, accuracy: 0.001)
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

final class TripStatsTests: XCTestCase {
    func testDistanceCountsOnlyTripsStartedThatDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 14 Nov 2023, 22:13 UTC
        let today = trip(start: now.addingTimeInterval(-3_600), meters: 5_000)
        let yesterday = trip(start: now.addingTimeInterval(-86_400), meters: 9_000)
        XCTAssertEqual(TripStats.distanceMeters(on: now, trips: [today, yesterday], calendar: calendar), 5_000, accuracy: 0.001)
        XCTAssertEqual(TripStats.totalDistanceMeters([today, yesterday]), 14_000, accuracy: 0.001)
        XCTAssertEqual(TripStats.totalDistanceMeters([]), 0, accuracy: 0.001)
    }

    func testDistanceSummariesFallBackToStoredRouteWhenSavedDistanceIsZero() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var trip = self.trip(start: start, meters: 0)
        trip.points = [
            TripPoint(latitude: 41, longitude: 2, altitudeMeters: 0,
                      timestamp: start, speedMetersPerSecond: 1, horizontalAccuracyMeters: 5),
            TripPoint(latitude: 41.001, longitude: 2, altitudeMeters: 0,
                      timestamp: start.addingTimeInterval(1), speedMetersPerSecond: 1, horizontalAccuracyMeters: 5)
        ]

        XCTAssertEqual(TripStats.totalDistanceMeters([trip]), 111.2, accuracy: 1)
        XCTAssertEqual(TripStats.distanceMeters(on: start, trips: [trip]), 111.2, accuracy: 1)
    }

    private func trip(start: Date, meters: Double) -> RecordedTrip {
        RecordedTrip(
            id: UUID().uuidString,
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            distanceMeters: meters,
            movingTimeMilliseconds: 600_000,
            maximumSpeedMetersPerSecond: 10,
            points: []
        )
    }
}


/// Byte layout must match the Android EasyConn implementation (PxcFrame.kt / EasyConnProber.kt).
final class PXCWireCodecTests: XCTestCase {
    func testMdnsRespondFrameMatchesAndroidLayout() throws {
        let json = #"{"phoneType":"Android"}"#
        let frame = try PXCWireCodec.encodeControl(command: 0x7000_0010, payload: Data(json.utf8))
        let total = UInt32(16 + json.utf8.count)
        XCTAssertEqual(Array(frame.prefix(4)), [0x10, 0x00, 0x00, 0x70])
        XCTAssertEqual(Array(frame[4..<8]), [UInt8(total & 0xFF), UInt8(total >> 8 & 0xFF), 0, 0])
        let magic = 0x7000_0010 ^ total
        XCTAssertEqual(Array(frame[8..<12]), [UInt8(magic & 0xFF), UInt8(magic >> 8 & 0xFF), UInt8(magic >> 16 & 0xFF), UInt8(magic >> 24)])
        XCTAssertEqual(Array(frame[12..<16]), [0, 0, 0, 0])
        XCTAssertEqual(String(decoding: frame.suffix(from: 16), as: UTF8.self), json)
    }

    func testControlFrameRoundTripAndPartialBuffers() throws {
        let encoded = try PXCWireCodec.encodeControl(command: 0x7000_0011, payload: Data(#"{"status":true}"#.utf8))
        var buffer = encoded.prefix(10)
        XCTAssertNil(try PXCWireCodec.takeControlFrame(from: &buffer))
        buffer = Data(encoded.dropLast())
        XCTAssertNil(try PXCWireCodec.takeControlFrame(from: &buffer))
        buffer = encoded + encoded
        let first = try XCTUnwrap(PXCWireCodec.takeControlFrame(from: &buffer))
        XCTAssertEqual(first.command, 0x7000_0011)
        XCTAssertEqual(String(decoding: first.payload, as: UTF8.self), #"{"status":true}"#)
        XCTAssertEqual(buffer.count, encoded.count)
    }

    func testControlFrameWithBadMagicThrows() throws {
        var encoded = try PXCWireCodec.encodeControl(command: 0x7000_0000)
        encoded[8] ^= 0xFF
        XCTAssertThrowsError(try PXCWireCodec.takeControlFrame(from: &encoded)) { error in
            XCTAssertEqual(error as? PXCWireError, .invalidControlMagic)
        }
    }

    func testMediaRequestAndRawVideoFrame() throws {
        var buffer = Data([114, 0, 2, 0, 7, 0, 0, 0, 0xAA, 0xBB, 0x01])
        let request = try XCTUnwrap(PXCWireCodec.takeMediaRequest(from: &buffer))
        XCTAssertEqual(request.command, 114)
        XCTAssertEqual(request.token, 7)
        XCTAssertEqual(request.payload, Data([0xAA, 0xBB]))
        XCTAssertEqual(buffer, Data([0x01]))
        let raw = try PXCWireCodec.encodeRawVideoFrame(Data([0, 0, 0, 1, 0x65]))
        XCTAssertEqual(Array(raw), [5, 0, 0, 0, 0, 0, 0, 1, 0x65])
    }
}

final class MirrorQRTests: XCTestCase {
    func testParsesCarbitProjectionLink() {
        let qr = MirrorQR.parse("https://www.carbit.com.cn/download?modelid=21340&ssid=ZT66TEST&pwd=12345678&action=1")
        XCTAssertEqual(qr, MirrorQR(ssid: "ZT66TEST", password: "12345678", modelID: "21340"))
    }

    func testRejectsKeylessPairingCode() {
        XCTAssertNil(MirrorQR.parse("125;010;000000000000000;AA;BB;;;CC;;DD"))
        XCTAssertNil(MirrorQR.parse("https://example.com/?action=8&mac=00:11:22:33:44:55"))
    }
}
