import CoreGraphics
import CoreLocation
import Foundation
import MapKit

/// Everything the dash picture needs to draw the moving map and the next manoeuvre.
/// A value type, handed from the main actor to the encoder thread under a lock.
struct DashMapState {
    /// Big Apple Maps snapshot around the rider and the map rect it covers.
    var image: CGImage?
    var imageRect = MKMapRect.null
    /// Last GPS fix, used to extrapolate the position between fixes (smooth at 10 fps).
    var fix: MKMapPoint?
    var fixTime = Date.distantPast
    var speed: Double = 0          // m/s
    var heading: Double = 0        // degrees, 0 = north
    /// Metres across the visible map (zoom follows speed).
    var viewMeters: Double = 600
    /// Route polyline, if navigating.
    var route: [MKMapPoint] = []
    var nav: DashNavInfo?
    var note = "mapa: esperando ubicación"

    /// Position now, extrapolated along the heading for up to 3 s after the fix was measured
    /// ([fixTime] is the fix's own timestamp; iOS delivers fixes about a second late).
    func position(at now: Date) -> MKMapPoint? {
        guard let fix else { return nil }
        let dt = min(max(now.timeIntervalSince(fixTime), 0), 3)
        guard speed > 1, dt > 0 else { return fix }
        let meters = speed * dt
        let ppm = MKMapPointsPerMeterAtLatitude(fix.coordinate.latitude)
        let rad = heading * .pi / 180
        // Map points grow east (x) and south (y).
        return MKMapPoint(x: fix.x + sin(rad) * meters * ppm, y: fix.y - cos(rad) * meters * ppm)
    }
}

struct DashNavInfo: Equatable {
    var instruction: String
    var distance: Double       // metres to the next manoeuvre
    var turn: DashTurn
    var remaining: Double      // metres to the destination
    var destination: String
}

enum DashTurn: Equatable {
    case straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn, arrive

    /// SF Symbol for the dash arrow.
    var symbol: String {
        switch self {
        case .straight: return "arrow.up"
        case .slightLeft: return "arrow.up.left"
        case .left, .sharpLeft: return "arrow.turn.up.left"
        case .slightRight: return "arrow.up.right"
        case .right, .sharpRight: return "arrow.turn.up.right"
        case .uTurn: return "arrow.uturn.down"
        case .arrive: return "flag.checkered"
        }
    }

    /// From the change of direction at the manoeuvre (degrees, positive = to the right).
    static func classify(delta: Double) -> DashTurn {
        let d = DashGeo.normalize(delta)
        switch abs(d) {
        case ..<20: return .straight
        case ..<55: return d > 0 ? .slightRight : .slightLeft
        case ..<135: return d > 0 ? .right : .left
        case ..<165: return d > 0 ? .sharpRight : .sharpLeft
        default: return .uTurn
        }
    }
}

enum DashGeo {
    /// Bearing from a to b, degrees clockwise from north.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let Δλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Angle to −180…180.
    static func normalize(_ a: Double) -> Double {
        var v = a.truncatingRemainder(dividingBy: 360)
        if v > 180 { v -= 360 }
        if v < -180 { v += 360 }
        return v
    }

    /// Distance in metres from p to the polyline (nearest segment).
    static func distance(from p: MKMapPoint, to line: [MKMapPoint]) -> Double {
        guard line.count > 1 else { return line.first.map { p.distance(to: $0) } ?? .infinity }
        var best = Double.infinity
        for i in 0..<(line.count - 1) {
            let a = line[i], b = line[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 : 0
            t = min(max(t, 0), 1)
            let q = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
            best = min(best, p.distance(to: q))
        }
        return best
    }

    /// Visible map width (metres) for a speed: closer in town, wider on the road.
    static func viewMeters(speedKmh: Double) -> Double {
        switch speedKmh {
        case ..<35: return 500
        case ..<75: return 900
        default: return 1_600
        }
    }
}

/// A manoeuvre of the route: where it is, what to show.
struct DashManeuver {
    let point: MKMapPoint
    let instruction: String
    let turn: DashTurn
    /// Route distance from this manoeuvre to the destination (0 for the arrival).
    let remainingAfter: Double

    /// Builds manoeuvres from MapKit route steps (first step = departure, skipped).
    static func from(steps: [(polyline: [CLLocationCoordinate2D], instruction: String, distance: Double)]) -> [DashManeuver] {
        guard steps.count > 1 else { return [] }
        var out: [DashManeuver] = []
        var remaining = steps.dropFirst().reduce(0) { $0 + $1.distance }
        for i in 1..<steps.count {
            let step = steps[i]
            guard let at = step.polyline.first else { continue }
            let isLast = i == steps.count - 1
            var turn = DashTurn.straight
            if isLast {
                turn = .arrive
            } else if let before = steps[i - 1].polyline.dropLast().last ?? steps[i - 1].polyline.first,
                      let after = step.polyline.dropFirst().first {
                let inBearing = bearing(before, at)
                let outBearing = bearing(at, after)
                turn = DashTurn.classify(delta: outBearing - inBearing)
            }
            // Distance from this manoeuvre to the destination = this step and every later one.
            out.append(DashManeuver(point: MKMapPoint(isLast ? (step.polyline.last ?? at) : at),
                                    instruction: step.instruction.isEmpty ? "—" : step.instruction,
                                    turn: turn, remainingAfter: isLast ? 0 : max(0, remaining)))
            remaining -= step.distance
        }
        return out
    }

    private static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        DashGeo.bearing(a, b)
    }
}

/// Tracks progress along the manoeuvres: advances when the rider reaches or passes one.
struct DashNavProgress {
    private(set) var index = 0
    private var closest = Double.infinity

    mutating func update(position: MKMapPoint, maneuvers: [DashManeuver]) -> DashManeuver? {
        guard index < maneuvers.count else { return nil }
        let d = position.distance(to: maneuvers[index].point)
        // Reached it, or got within 50 m and is now moving away.
        if d < 25 || (closest < 50 && d > closest + 30) {
            index += 1
            closest = .infinity
            return index < maneuvers.count ? maneuvers[index] : nil
        }
        closest = min(closest, d)
        return maneuvers[index]
    }
}
