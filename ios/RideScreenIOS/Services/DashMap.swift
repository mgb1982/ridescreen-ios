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
    /// Change of speed between the last two fixes (m/s², clamped); used to show the speed about a
    /// second ahead of iOS's filtered value.
    var accel: Double = 0
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
    /// Estimated arrival, from Apple's travel time scaled to the distance left.
    var arrival: Date? = nil
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


extension DashMapState {
    /// Speed to show now: the last fix's speed pushed forward by the measured acceleration for up to
    /// 1.5 s, which hides most of the lag of iOS's filtered speed. Nil when the fix is stale.
    func speedKmh(at now: Date) -> Double? {
        guard fix != nil else { return nil }
        let age = now.timeIntervalSince(fixTime)
        guard age < 5 else { return nil }
        let ahead = min(max(age, 0), 1.5)
        return max(0, speed + accel * ahead) * 3.6
    }
}

/// Destinations used before (most recent first) and the ones starred as favourites, kept on this
/// phone. Favourites are also offered to Siri and Shortcuts ("Llévame a Casa con RideScreen").
struct DashPlace: Codable, Equatable, Identifiable {
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var favourite = false
    var id: String { String(format: "%.5f,%.5f", latitude, longitude) }

    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        item.name = name
        return item
    }
}

enum DashPlaces {
    private static let key = "dash.places"
    private static let maxRecent = 8

    static var all: [DashPlace] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([DashPlace].self, from: data) else { return [] }
            return list
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
            RideScreenShortcuts.updateAppShortcutParameters()   // Siri learns the new names
        }
    }
    static var favourites: [DashPlace] { all.filter(\.favourite) }

    /// Moves the place to the top; keeps every favourite and the latest non-favourites.
    static func remember(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(c) else { return }
        var place = DashPlace(name: item.name ?? "Destino", address: item.placemark.title ?? "",
                              latitude: c.latitude, longitude: c.longitude)
        var list = all
        if let old = list.first(where: { $0.id == place.id }) { place.favourite = old.favourite; if place.address.isEmpty { place.address = old.address } }
        list.removeAll { $0.id == place.id }
        list.insert(place, at: 0)
        var recent = 0
        list = list.filter { $0.favourite || { recent += 1; return recent <= maxRecent }() }
        all = list
    }

    static func toggleFavourite(_ id: String) {
        var list = all
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].favourite.toggle()
        all = list
    }

    static func rename(_ id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var list = all
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].name = clean
        all = list
    }

    static func remove(_ id: String) { all = all.filter { $0.id != id } }
}
