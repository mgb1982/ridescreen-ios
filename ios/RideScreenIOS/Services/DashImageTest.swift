import CoreLocation
import Foundation
import MapKit
import UIKit

/// Field test: RideScreen's own picture on the dash, also with the phone locked.
/// Keeps the app alive with background location (the way navigation apps do), draws speed, clock
/// and an Apple Maps snapshot, encodes it and serves it over [DashLink]. Logs every app-state
/// change and whether the encoder and map snapshots keep working in the background.
@MainActor
final class DashImageTest: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var lines: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var streaming = false
    @Published private(set) var framesSent = 0

    private var link: DashLink?
    private var source: DashPictureSource?
    private let location = CLLocationManager()
    private var lastLocation: CLLocation?
    private var mapTimer: Timer?
    private var uiTimer: Timer?
    private var startDate = Date()
    private var appState = "app abierta"
    private var observers: [NSObjectProtocol] = []
    private var snapshotInFlight = false

    var logText: String { lines.joined(separator: "\n") }

    override init() {
        super.init()
        location.delegate = self
        // Here location mostly keeps the app alive with the phone locked; it also feeds the speed on the
        // picture and a 900 m map snapshot every 10 s. Ten-metre accuracy is plenty for both and lets
        // iOS spend less on the GNSS than "best" (audit 11 Nov 2026). No distance filter: the speed must
        // keep updating while stopped.
        location.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        location.activityType = .automotiveNavigation
    }

    func start(host: String) {
        guard !isRunning else { return }
        lines = []
        startDate = Date()
        framesSent = 0
        isRunning = true
        let device = UIDevice.current
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log("RideScreen iOS · imagen propia · build \(build) · \(device.systemName) \(device.systemVersion)")

        guard let wifi = MirrorLinkTester.wifiIPv4() else {
            log("!! Sin IPv4 de Wi‑Fi: únete antes al Wi‑Fi de la moto (ZT…)")
            isRunning = false
            return
        }
        let target = host.trimmingCharacters(in: .whitespaces).isEmpty ? wifi.gatewayGuess : host.trimmingCharacters(in: .whitespaces)
        log("Wi‑Fi \(wifi.address) · cuadro \(target)")

        startLocation()
        observeAppState()

        let pixels = UIScreen.main.nativeBounds.size
        let logger: (String) -> Void = { [weak self] text in Task { @MainActor in self?.log(text) } }
        let src = DashPictureSource(log: logger)
        source = src
        let link = DashLink(source: src, screenPixels: (Int(pixels.width), Int(pixels.height)), log: logger)
        link.onStreamingChanged = { [weak self] on in Task { @MainActor in self?.setStreaming(on) } }
        self.link = link
        link.start(host: target)

        mapTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMap() }
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickUI() }
        }
    }

    func stop() {
        guard isRunning else { return }
        link?.stop(); link = nil
        source?.stop(); source = nil
        mapTimer?.invalidate(); mapTimer = nil
        uiTimer?.invalidate(); uiTimer = nil
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        isRunning = false
        streaming = false
        log("Prueba detenida · \(framesSent) imágenes enviadas")
    }

    // MARK: State

    private func setStreaming(_ on: Bool) {
        guard streaming != on else { return }
        streaming = on
        log(on ? "*** El cuadro está recibiendo imagen ***" : "El cuadro dejó de recibir imagen")
    }

    private func tickUI() {
        framesSent = link?.sentCount ?? framesSent
        source?.update(speedKmh: lastLocation.flatMap { $0.speed >= 0 ? $0.speed * 3.6 : nil }, appState: appState)
    }

    private func observeAppState() {
        let nc = NotificationCenter.default
        func watch(_ name: Notification.Name, _ state: String) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.appState = state
                    self.log("App: \(state) · imágenes enviadas \(self.link?.sentCount ?? 0)")
                    self.tickUI()
                }
            })
        }
        watch(UIApplication.didEnterBackgroundNotification, "segundo plano")
        watch(UIApplication.willEnterForegroundNotification, "app abierta")
        watch(UIApplication.protectedDataWillBecomeUnavailableNotification, "móvil bloqueado")
        watch(UIApplication.protectedDataDidBecomeAvailableNotification, "desbloqueado")
    }

    // MARK: Location

    private func startLocation() {
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestWhenInUseAuthorization()
        case .denied, .restricted:
            log("!! Ubicación denegada: sin ella iOS suspende la app al bloquear el móvil")
        default:
            break
        }
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
        log("Ubicación en segundo plano activada (mantiene viva la app con el móvil bloqueado)")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            let first = self.lastLocation == nil
            self.lastLocation = last
            if first { self.log("Primera ubicación ±\(Int(last.horizontalAccuracy)) m"); self.refreshMap() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.log("Permiso de ubicación: \(Self.describe(status))") }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.log("Ubicación: error \(error.localizedDescription)") }
    }

    private static func describe(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .authorizedAlways: return "siempre"
        case .authorizedWhenInUse: return "al usar la app"
        case .denied: return "denegado"
        case .restricted: return "restringido"
        default: return "sin decidir"
        }
    }

    // MARK: Map

    /// Apple Maps snapshot around the rider every 10 s. Whether this works with the phone locked is
    /// part of the test, so successes and failures are logged with the app state.
    private func refreshMap() {
        guard isRunning, !snapshotInFlight, let here = lastLocation else { return }
        snapshotInFlight = true
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 900, longitudinalMeters: 1_330)
        options.size = CGSize(width: 370, height: 250)
        options.scale = 1
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        options.pointOfInterestFilter = .excludingAll
        let state = appState
        MKMapSnapshotter(options: options).start(with: .global(qos: .utility)) { [weak self] snapshot, error in
            let image = snapshot?.image.cgImage
            let message = error.map { "\($0.localizedDescription)" }
            Task { @MainActor in
                guard let self else { return }
                self.snapshotInFlight = false
                let clock = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                if let image {
                    self.source?.setMap(image, note: "mapa \(clock) · \(state)")
                    if self.mapLogCount < 3 || state != "app abierta" {
                        self.mapLogCount += 1
                        self.log("Mapa OK (\(state))")
                    }
                } else {
                    self.source?.setMap(nil, note: "mapa: falló (\(state))")
                    self.log("!! Mapa falló (\(state)): \(message ?? "sin imagen")")
                }
            }
        }
    }

    private var mapLogCount = 0

    // MARK: Log

    func log(_ text: String) {
        let t = Date().timeIntervalSince(startDate)
        lines.append(String(format: "%6.1fs ", t) + text)
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
    }
}
