import CoreLocation
import MapKit
import XCTest
@testable import RideScreenIOS

final class DashMapTests: XCTestCase {
    private func coord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func testTurnClassification() {
        XCTAssertEqual(DashTurn.classify(delta: 5), .straight)
        XCTAssertEqual(DashTurn.classify(delta: 40), .slightRight)
        XCTAssertEqual(DashTurn.classify(delta: -90), .left)
        XCTAssertEqual(DashTurn.classify(delta: 270), .left)       // = −90
        XCTAssertEqual(DashTurn.classify(delta: 150), .sharpRight)
        XCTAssertEqual(DashTurn.classify(delta: 178), .uTurn)
    }

    func testBearingAndNormalize() {
        XCTAssertEqual(DashGeo.bearing(coord(41, 2), coord(41.01, 2)), 0, accuracy: 0.5)
        XCTAssertEqual(DashGeo.bearing(coord(41, 2), coord(41, 2.01)), 90, accuracy: 0.5)
        XCTAssertEqual(DashGeo.normalize(350), -10, accuracy: 1e-9)
        XCTAssertEqual(DashGeo.normalize(-200), 160, accuracy: 1e-9)
    }

    func testDistanceToPolyline() {
        let a = MKMapPoint(coord(41, 2)), b = MKMapPoint(coord(41, 2.01))
        let p = MKMapPoint(coord(41.0009, 2.005))      // ~100 m north of the segment's middle
        XCTAssertEqual(DashGeo.distance(from: p, to: [a, b]), 100, accuracy: 3)
        XCTAssertEqual(DashGeo.distance(from: a, to: [a, b]), 0, accuracy: 0.01)
    }

    func testManeuversFromSteps() {
        // Depart north 1 km, turn right (east) 2 km, arrive.
        let start = coord(41, 2), corner = coord(41.009, 2), end = coord(41.009, 2.024)
        let steps: [(polyline: [CLLocationCoordinate2D], instruction: String, distance: Double)] = [
            ([start], "", 0),
            ([start, corner], "Sigue recto", 1_000),
            ([corner, end], "Gira a la derecha", 2_000),
            ([end], "Has llegado", 0),
        ]
        let m = DashManeuver.from(steps: steps)
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(m[1].turn, .right)
        XCTAssertEqual(m[1].remainingAfter, 2_000, accuracy: 0.1)
        XCTAssertEqual(m[2].turn, .arrive)
        XCTAssertEqual(m[2].remainingAfter, 0)
        XCTAssertEqual(m[2].point.x, MKMapPoint(end).x, accuracy: 1)
    }

    func testProgressAdvancesWhenReached() {
        let a = MKMapPoint(coord(41, 2)), b = MKMapPoint(coord(41.01, 2))
        let ms = [DashManeuver(point: a, instruction: "A", turn: .right, remainingAfter: 1_000),
                  DashManeuver(point: b, instruction: "B", turn: .arrive, remainingAfter: 0)]
        var p = DashNavProgress()
        XCTAssertEqual(p.update(position: MKMapPoint(coord(40.99, 2)), maneuvers: ms)?.instruction, "A")
        XCTAssertEqual(p.update(position: a, maneuvers: ms)?.instruction, "B")
        XCTAssertNil(p.update(position: b, maneuvers: ms))
    }

    func testPositionExtrapolation() {
        var s = DashMapState()
        let fix = MKMapPoint(coord(41, 2))
        s.fix = fix; s.fixTime = Date(timeIntervalSince1970: 0); s.speed = 10; s.heading = 90
        let later = s.position(at: Date(timeIntervalSince1970: 1))!
        XCTAssertEqual(fix.distance(to: later), 10, accuracy: 0.2)
        XCTAssertGreaterThan(later.x, fix.x)                         // moved east
        let capped = s.position(at: Date(timeIntervalSince1970: 10))!
        XCTAssertEqual(fix.distance(to: capped), 30, accuracy: 0.5)  // ≤ 3 s of extrapolation
    }

    func testProjectionIsHeadingUp() {
        let rider = MKMapPoint(coord(41, 2))
        let east = MKMapPoint(x: rider.x + 100, y: rider.y)
        // Riding east: a point east of the rider must appear straight above the anchor.
        let q = DashPicture.project(east, rider: rider, heading: 90, pixelsPerMapPoint: 1, anchor: .zero)
        XCTAssertEqual(q.x, 0, accuracy: 1e-6)
        XCTAssertEqual(q.y, -100, accuracy: 1e-6)
    }

    func testDistanceFormatting() {
        XCTAssertEqual(DashPicture.formatDistance(347), "350 m")
        XCTAssertTrue(DashPicture.formatDistance(12_345).hasSuffix(" km"))
    }
}
