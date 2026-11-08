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
    /// Map tiles fetched ahead of time (iOS gives no new map with the phone locked), kept on disk so
    /// they add up ride after ride. See [DashTileStore].
    let tiles = DashTileStore()
    private var precaching = false
    private var precachedRoute = false
    private var ringCenter: MKMapPoint?
    @Published private(set) var areaProgress: String?
    private var areaTask: Task<Void, Never>?
    /// Detail zoom (city) and wide zoom (around it, and highway).
    static let detailView = 700.0
    static let wideView = 1600.0

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

    /// Swap in the stored tile that best covers the rider (detail first, then wide), when the current
    /// map no longer does.
    private func useCache(at p: MKMapPoint) {
        let r = state.imageRect
        if !r.isNull, state.image != nil, hypot(p.x - r.midX, p.y - r.midY) < r.width * 0.25 { return }
        guard let best = tiles.best(for: p) else {
            if state.note != "sin mapa" { state.note = "sin mapa"; log("Sin mapa guardado para esta zona") }
            return
        }
        if MKMapRectEqualToRect(best.rect, state.imageRect) { return }
        guard let image = tiles.image(best) else { return }
        state.image = image
        state.imageRect = best.rect
        snapshotViewMeters = best.view
        state.note = ""
    }

    /// While the phone is unlocked: tiles along the route (once per route, both zooms), or without a
    /// route a detailed 3×3 block around the rider plus a wide 5×5 ring (~20 km), again when the rider
    /// leaves it. Tiles already on disk are skipped.
    private func precacheIfNeeded(at p: MKMapPoint) {
        guard !locked, !precaching, areaTask == nil else { return }
        let ppm = MKMapPointsPerMeterAtLatitude(p.coordinate.latitude)
        let detail = Self.detailView * 2.6 * ppm, wide = Self.wideView * 2.6 * ppm
        var jobs: [(MKMapPoint, Double)] = []
        if !state.route.isEmpty {
            guard !precachedRoute else { return }
            precachedRoute = true
            jobs = Self.along(state.route, step: detail * 0.4).map { ($0, Self.detailView) }
                 + Self.along(state.route, step: wide * 0.4).map { ($0, Self.wideView) }
        } else {
            if let c = ringCenter, hypot(p.x - c.x, p.y - c.y) < detail * 0.8 { return }
            ringCenter = p
            jobs = Self.grid(around: p, half: 1, step: detail * 0.8).map { ($0, Self.detailView) }
                 + Self.grid(around: p, half: 2, step: wide * 0.8).map { ($0, Self.wideView) }
        }
        runJobs(jobs, label: "Mapa guardado para usar bloqueado", stopWhenLocked: true)
    }

    /// "Guardar mapa de esta zona": a square of the given radius, at a zoom that keeps it to a few
    /// hundred tiles. Meant for home Wi‑Fi before a trip out of the usual area.
    func downloadArea(radiusKm: Double) {
        guard let p = state.fix, areaTask == nil else { return }
        let view = radiusKm <= 10 ? Self.wideView : (radiusKm <= 25 ? 2600.0 : 4000.0)
        let ppm = MKMapPointsPerMeterAtLatitude(p.coordinate.latitude)
        let step = view * 2.6 * ppm * 0.8
        let half = Int((radiusKm * 1000 * ppm / step).rounded(.up))
        let jobs = Self.grid(around: p, half: half, step: step).map { ($0, view) }
        log("Guardando mapa de \(Int(radiusKm)) km alrededor: \(jobs.count) zonas")
        runJobs(jobs, label: "Mapa de la zona guardado", stopWhenLocked: false, manual: true)
    }

    func cancelAreaDownload() { areaTask?.cancel() }

    private func runJobs(_ jobs: [(MKMapPoint, Double)], label: String, stopWhenLocked: Bool, manual: Bool = false) {
        let todo = jobs.filter { !tiles.has(centre: $0.0, view: $0.1) }
        guard !todo.isEmpty else { return }
        precaching = true
        let started = Date()
        let task = Task { @MainActor [weak self] in
            var done = 0
            for (i, (c, view)) in todo.enumerated() {
                guard let self, !Task.isCancelled else { break }
                if stopWhenLocked && self.locked { break }
                let ppm = MKMapPointsPerMeterAtLatitude(c.coordinate.latitude)
                let side = view * 2.6 * ppm
                let rect = MKMapRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
                if let jpeg = await Self.tile(rect: rect) { self.tiles.add(rect: rect, view: view, jpeg: jpeg); done += 1 }
                if manual { self.areaProgress = "\(i + 1)/\(todo.count)" }
            }
            guard let self else { return }
            self.precaching = false
            if manual { self.areaTask = nil; self.areaProgress = nil }
            self.log("\(label): \(done)/\(todo.count) zonas en \(Int(Date().timeIntervalSince(started))) s · \(self.tiles.summary)")
        }
        if manual { areaTask = task }
    }

    private static func along(_ route: [MKMapPoint], step: Double) -> [MKMapPoint] {
        var out: [MKMapPoint] = []
        var last: MKMapPoint?
        for q in route {
            if let l = last, hypot(q.x - l.x, q.y - l.y) < step { continue }
            out.append(q); last = q
        }
        if let end = route.last, let l = last, hypot(end.x - l.x, end.y - l.y) > step * 0.3 { out.append(end) }
        return out
    }

    private static func grid(around p: MKMapPoint, half: Int, step: Double) -> [MKMapPoint] {
        var out: [MKMapPoint] = []
        for dy in -half...half { for dx in -half...half { out.append(MKMapPoint(x: p.x + Double(dx) * step, y: p.y + Double(dy) * step)) } }
        // Nearest first, so a cancelled or interrupted download still covers the middle.
        return out.sorted { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }
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

/// Map tiles on disk (Caches/dash-map), named by zoom and map rect, so they survive app restarts and
/// add up ride after ride. Oldest are removed past [limitBytes]. iOS may clear Caches when storage is
/// short; then they are simply fetched again.
final class DashTileStore {
    struct Tile { let rect: MKMapRect; let view: Double; let url: URL; var size: Int; var date: Date }
    static let limitBytes = 200 * 1024 * 1024
    private(set) var items: [Tile] = []
    private let dir: URL

    init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dash-map")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        for url in files {
            let p = url.deletingPathExtension().lastPathComponent.split(separator: "_").compactMap { Double($0) }
            guard p.count == 4, let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            items.append(Tile(rect: MKMapRect(x: p[1], y: p[2], width: p[3], height: p[3]), view: p[0], url: url,
                              size: v.fileSize ?? 0, date: v.contentModificationDate ?? .distantPast))
        }
    }

    var bytes: Int { items.reduce(0) { $0 + $1.size } }
    var summary: String { "\(items.count) zonas en el móvil, \(bytes / 1_048_576) MB" }

    func has(centre c: MKMapPoint, view: Double) -> Bool {
        items.contains { $0.view == view && hypot(c.x - $0.rect.midX, c.y - $0.rect.midY) < $0.rect.width * 0.2 }
    }

    func best(for p: MKMapPoint) -> Tile? {
        func off(_ t: Tile) -> Double { hypot(p.x - t.rect.midX, p.y - t.rect.midY) / t.rect.width }
        let fitting = items.filter { off($0) < 0.4 }
        // Sharpest zoom that covers the rider; among equals, the best centred.
        return fitting.min { ($0.view, off($0)) < ($1.view, off($1)) }
    }

    func image(_ t: Tile) -> CGImage? {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: t.url.path)
        guard let data = try? Data(contentsOf: t.url) else { return nil }
        return UIImage(data: data)?.cgImage
    }

    func add(rect: MKMapRect, view: Double, jpeg: Data) {
        let name = String(format: "%.0f_%.1f_%.1f_%.1f.jpg", view, rect.minX, rect.minY, rect.width)
        let url = dir.appendingPathComponent(name)
        guard (try? jpeg.write(to: url)) != nil else { return }
        items.append(Tile(rect: rect, view: view, url: url, size: jpeg.count, date: Date()))
        var total = bytes
        guard total > Self.limitBytes else { return }
        items.sort { $0.date < $1.date }
        while total > Self.limitBytes, let old = items.first {
            try? FileManager.default.removeItem(at: old.url)
            total -= old.size
            items.removeFirst()
        }
    }

    func clear() {
        for t in items { try? FileManager.default.removeItem(at: t.url) }
        items = []
    }
}
