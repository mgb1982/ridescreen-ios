import CoreLocation
import Foundation
import MapKit
import UIKit

/// Moving map and own navigation for the dash picture.
///  - Keeps a big Apple Maps snapshot (2.6× the visible width) around the rider; the picture pans and
///    rotates it every frame, so the map moves smoothly between GPS fixes and only a new snapshot is
///    needed when the rider nears its edge or the zoom (which follows speed) changes.
///  - Searches a destination (MKLocalSearch), asks Apple for a route (MKDirections), follows the
///    manoeuvres and recalculates when the rider leaves the route.
@MainActor
final class DashNavigator: ObservableObject {
    @Published private(set) var results: [MKMapItem] = []
    @Published private(set) var searching = false
    @Published private(set) var destinationName: String?
    @Published private(set) var routeSummary: String?
    @Published private(set) var hasFix = false

    var log: (String) -> Void = { _ in }
    var appState: () -> String = { "" }
    var onStateChange: ((DashMapState) -> Void)?

    private(set) var state = DashMapState()
    private var snapshotViewMeters: Double = 0
    private var snapshotInFlight = false
    private var snapshotCount = 0
    private var snapshotter: MKMapSnapshotter?
    private var snapshotGeneration = 0
    private var snapshotFailures = 0
    private var retryAfter = Date.distantPast
    private var destination: MKMapItem?
    private var maneuvers: [DashManeuver] = []
    private var progress = DashNavProgress()
    private var offRouteFixes = 0
    private var lastRouteAt = Date.distantPast
    private var routing = false
    private var routeDistance = 0.0
    private var routeTime = 0.0
    /// Map tiles fetched ahead of time (iOS gives no new map with the phone locked): along the route,
    /// and a block around the rider when there is none. Kept JPEG-compressed, decoded when used.
    private var cache: [(rect: MKMapRect, view: Double, jpeg: Data)] = []
    private var precaching = false
    private var precachedRoute = false
    private var ringCenter: MKMapPoint?
    private var cacheRect = MKMapRect.null
    private static let cacheView = 700.0
    private static let cacheLimit = 90

    // MARK: Location

    func update(location: CLLocation) {
        let point = MKMapPoint(location.coordinate)
        let speed = max(0, location.speed)
        if location.speed >= 0, state.fix != nil {
            let dt = location.timestamp.timeIntervalSince(state.fixTime)
            if dt > 0.3 && dt < 3 { state.accel = min(max((speed - state.speed) / dt, -4), 4) } else { state.accel = 0 }
        } else {
            state.accel = 0
        }
        if location.course >= 0 && speed > 1.5 { state.heading = location.course }
        state.fix = point
        if !hasFix { hasFix = true }
        state.fixTime = location.timestamp
        state.speed = speed
        state.viewMeters = DashGeo.viewMeters(speedKmh: speed * 3.6)
        if locked {
            useCache(at: point)
        } else if needsSnapshot(at: point) {
            snapshot(around: point)
        }
        if destination != nil && state.route.isEmpty && !routing && Date().timeIntervalSince(lastRouteAt) > 10 {
            calculateRoute(reason: "destino pendiente")
        }
        precacheIfNeeded(at: point)
        updateNavigation(at: point)
        onStateChange?(state)
    }

    private var locked: Bool { !UIApplication.shared.isProtectedDataAvailable }

    // MARK: Map cache (for the locked phone and for places without coverage)

    /// Swap in the cached tile that best centres the rider, when the current map no longer does.
    private func useCache(at p: MKMapPoint) {
        let r = state.imageRect
        if !r.isNull, state.image != nil, hypot(p.x - r.midX, p.y - r.midY) < r.width * 0.25 { return }
        guard let best = cache.min(by: { hypot(p.x - $0.rect.midX, p.y - $0.rect.midY) < hypot(p.x - $1.rect.midX, p.y - $1.rect.midY) }),
              hypot(p.x - best.rect.midX, p.y - best.rect.midY) < best.rect.width * 0.4 else {
            if state.note != "sin mapa" { state.note = "sin mapa"; log("Sin mapa guardado para esta zona") }
            return
        }
        if best.rect == state.imageRect { return }
        guard let image = UIImage(data: best.jpeg)?.cgImage else { return }
        state.image = image
        state.imageRect = best.rect
        snapshotViewMeters = best.view
        state.note = ""
    }

    /// While the phone is unlocked, fetch tiles along the route (once per route) or, without a route,
    /// a 3×3 block around the rider (again when the rider leaves it).
    private func precacheIfNeeded(at p: MKMapPoint) {
        guard !locked, !precaching else { return }
        let ppm = MKMapPointsPerMeterAtLatitude(p.coordinate.latitude)
        let side = Self.cacheView * 2.6 * ppm
        var centres: [MKMapPoint] = []
        if !state.route.isEmpty {
            guard !precachedRoute else { return }
            precachedRoute = true
            let step = side * 0.4
            var last: MKMapPoint?
            for q in state.route {
                if let l = last, hypot(q.x - l.x, q.y - l.y) < step { continue }
                centres.append(q); last = q
            }
            if let end = state.route.last, let l = last, hypot(end.x - l.x, end.y - l.y) > step * 0.3 { centres.append(end) }
        } else {
            if let c = ringCenter, hypot(p.x - c.x, p.y - c.y) < side * 0.8 { return }
            ringCenter = p
            for dy in -1...1 { for dx in -1...1 { centres.append(MKMapPoint(x: p.x + Double(dx) * side * 0.8, y: p.y + Double(dy) * side * 0.8)) } }
        }
        centres = centres.filter { c in !cache.contains { hypot(c.x - $0.rect.midX, c.y - $0.rect.midY) < side * 0.2 } }
        guard !centres.isEmpty else { return }
        precaching = true
        let started = Date()
        let total = centres.count
        Task { @MainActor [weak self] in
            var done = 0
            for c in centres {
                guard let self else { return }
                let rect = MKMapRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
                if let jpeg = await Self.tile(rect: rect) {
                    self.cache.append((rect, Self.cacheView, jpeg)); done += 1
                    if self.cache.count > Self.cacheLimit { self.cache.removeFirst(self.cache.count - Self.cacheLimit) }
                }
                if self.locked { break }
            }
            guard let self else { return }
            self.precaching = false
            let kb = self.cache.reduce(0) { $0 + $1.jpeg.count } / 1024
            self.log("Mapa guardado para usar bloqueado: \(done)/\(total) zonas en \(Int(Date().timeIntervalSince(started))) s · \(self.cache.count) en total, \(kb) KB")
        }
    }

    private static func tile(rect: MKMapRect) async -> Data? {
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = CGSize(width: 1000, height: 1000)
        options.scale = 1
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false
        let snapshotter = MKMapSnapshotter(options: options)
        return await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            snapshotter.start(with: .global(qos: .utility)) { snap, _ in
                c.resume(returning: snap?.image.jpegData(compressionQuality: 0.7))
            }
        }
    }

    private func needsSnapshot(at p: MKMapPoint) -> Bool {
        if snapshotInFlight || Date() < retryAfter { return false }
        if snapshotFailures > 0 { return true }
        if state.image == nil || state.imageRect.isNull { return true }
        if abs(snapshotViewMeters - state.viewMeters) > 1 { return true }
        // The visible map reaches ~0.6 view widths from the rider (rotated corners); the snapshot is
        // 2.6 view widths, so re-centre once the rider is 0.22 snapshot widths off its centre.
        let c = MKMapPoint(x: state.imageRect.midX, y: state.imageRect.midY)
        return hypot(p.x - c.x, p.y - c.y) > state.imageRect.width * 0.22
    }

    private func snapshot(around p: MKMapPoint) {
        snapshotInFlight = true
        snapshotGeneration += 1
        let generation = snapshotGeneration
        let view = state.viewMeters
        let ppm = MKMapPointsPerMeterAtLatitude(p.coordinate.latitude)
        let side = view * 2.6 * ppm
        let rect = MKMapRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = CGSize(width: 1000, height: 1000)
        options.scale = 1
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false
        let started = Date()
        let appState = self.appState()
        let snapshotter = MKMapSnapshotter(options: options)
        self.snapshotter = snapshotter
        // Without coverage (a tunnel) the request can hang and never call back; give up after 10 s,
        // otherwise no further map is ever requested.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.snapshotInFlight, self.snapshotGeneration == generation else { return }
            self.snapshotter?.cancel()
            self.snapshotFailed("sin respuesta en 10 s", appState: appState)
        }
        snapshotter.start(with: .global(qos: .userInitiated)) { [weak self] snap, error in
            let image = snap?.image.cgImage
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.snapshotInFlight, self.snapshotGeneration == generation else { return }
                guard let image else {
                    self.snapshotFailed(message ?? "sin imagen", appState: appState)
                    return
                }
                self.snapshotInFlight = false
                self.snapshotter = nil
                if self.snapshotFailures > 0 {
                    self.log("Mapa recuperado tras \(self.snapshotFailures) intento(s) fallido(s)")
                    self.snapshotFailures = 0
                }
                self.state.image = image
                self.state.imageRect = rect
                self.snapshotViewMeters = view
                self.snapshotCount += 1
                self.state.note = ""
                if self.snapshotCount <= 2 || appState != "app abierta" || self.snapshotCount % 20 == 0 {
                    self.log("Mapa #\(self.snapshotCount) OK (\(appState), \(Int(view)) m, \(Int(Date().timeIntervalSince(started) * 1000)) ms)")
                }
                self.onStateChange?(self.state)
            }
        }
    }

    /// Retry in 5 s (the next GPS fix after that asks again).
    private func snapshotFailed(_ reason: String, appState: String) {
        snapshotInFlight = false
        snapshotter = nil
        snapshotFailures += 1
        retryAfter = Date().addingTimeInterval(5)
        state.note = "sin mapa"
        if let fix = state.fix { useCache(at: fix) }
        if snapshotFailures == 1 || snapshotFailures % 10 == 0 {
            log("!! Mapa falló (\(appState), intento \(snapshotFailures)): \(reason) · reintento en 5 s")
        }
        onStateChange?(state)
    }

    // MARK: Destination and route

    func search(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let fix = state.fix {
            request.region = MKCoordinateRegion(center: fix.coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        searching = true
        MKLocalSearch(request: request).start { [weak self] response, error in
            let items = Array((response?.mapItems ?? []).prefix(6))
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.searching = false
                self.results = items
                if items.isEmpty { self.log("Búsqueda «\(text)»: sin resultados \(message ?? "")") }
            }
        }
    }

    func setDestination(_ item: MKMapItem) {
        destination = item
        destinationName = item.name ?? "Destino"
        results = []
        DashPlaces.remember(item)
        calculateRoute(reason: "destino")
    }

    func clearDestination() {
        destination = nil
        destinationName = nil
        routeSummary = nil
        maneuvers = []
        state.route = []
        state.nav = nil
        onStateChange?(state)
        log("Navegación quitada")
    }

    private func calculateRoute(reason: String) {
        guard let destination, let fix = state.fix, !routing else { return }
        routing = true
        lastRouteAt = Date()
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: fix.coordinate))
        request.destination = destination
        request.transportType = .automobile
        MKDirections(request: request).calculate { [weak self] response, error in
            let route = response?.routes.first
            let points: [MKMapPoint] = route.map { r in
                let poly = r.polyline
                return (0..<poly.pointCount).map { poly.points()[$0] }
            } ?? []
            let steps: [(polyline: [CLLocationCoordinate2D], instruction: String, distance: Double)] = route?.steps.map { step in
                let poly = step.polyline
                var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: poly.pointCount)
                poly.getCoordinates(&coords, range: NSRange(location: 0, length: poly.pointCount))
                return (polyline: coords, instruction: step.instructions, distance: step.distance)
            } ?? []
            let distance = route?.distance ?? 0
            let time = route?.expectedTravelTime ?? 0
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.routing = false
                guard route != nil, self.destination != nil else {
                    self.log("!! Ruta no disponible (\(reason)): \(message ?? "sin ruta")")
                    return
                }
                self.state.route = points
                self.routeDistance = distance
                self.routeTime = time
                self.precachedRoute = false
                self.maneuvers = DashManeuver.from(steps: steps)
                self.progress = DashNavProgress()
                self.offRouteFixes = 0
                let summary = String(format: "%.1f km · %d min", distance / 1000, Int((time / 60).rounded()))
                self.routeSummary = summary
                self.log("Ruta (\(reason)): \(summary) · \(self.maneuvers.count) maniobras")
                if let fix = self.state.fix { self.updateNavigation(at: fix) }
                self.onStateChange?(self.state)
            }
        }
    }

    private func updateNavigation(at p: MKMapPoint) {
        guard destination != nil, !maneuvers.isEmpty else { return }
        guard let next = progress.update(position: p, maneuvers: maneuvers) else {
            if state.nav?.turn != .arrive || state.nav?.distance != 0 {
                state.nav = DashNavInfo(instruction: "Has llegado", distance: 0, turn: .arrive, remaining: 0,
                                        destination: destinationName ?? "")
                log("Llegada a \(destinationName ?? "destino")")
            }
            return
        }
        let d = p.distance(to: next.point)
        let remaining = d + next.remainingAfter
        let arrival = routeDistance > 0 ? Date().addingTimeInterval(routeTime * min(remaining / routeDistance, 1.5)) : nil
        state.nav = DashNavInfo(instruction: next.instruction, distance: d, turn: next.turn,
                                remaining: remaining, destination: destinationName ?? "", arrival: arrival)
        // Off the route for three fixes in a row → ask Apple again (at most every 15 s).
        if DashGeo.distance(from: p, to: state.route) > 70 {
            offRouteFixes += 1
            if offRouteFixes >= 3 && Date().timeIntervalSince(lastRouteAt) > 15 {
                log("Fuera de ruta: recalculando")
                calculateRoute(reason: "recalcular")
            }
        } else {
            offRouteFixes = 0
        }
    }
}
