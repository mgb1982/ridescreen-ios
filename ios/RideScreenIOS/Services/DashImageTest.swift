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
    /// Moving map and destination/route; lives across test runs so a destination survives a restart.
    let navigator: DashNavigator

    private var link: DashLink?
    private var source: DashPictureSource?
    private let location = CLLocationManager()
    private var lastLocation: CLLocation?
    private var uiTimer: Timer?
    private var startDate = Date()
    private var appState = "app abierta"
    private var observers: [NSObjectProtocol] = []

    var logText: String { lines.joined(separator: "\n") }

    override init() {
        navigator = DashNavigator()
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        location.activityType = .automotiveNavigation
        navigator.log = { [weak self] text in self?.log(text) }
        navigator.appState = { [weak self] in self?.appState ?? "" }
        navigator.onStateChange = { [weak self] state in self?.source?.setMapState(state) }
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
        src.setMapState(navigator.state)
        let link = DashLink(source: src, screenPixels: (Int(pixels.width), Int(pixels.height)), log: logger)
        link.onStreamingChanged = { [weak self] on in Task { @MainActor in self?.setStreaming(on) } }
        self.link = link
        link.start(host: target)

        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickUI() }
        }
    }

    func stop() {
        guard isRunning else { return }
        link?.stop(); link = nil
        source?.stop(); source = nil
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
            if first { self.log("Primera ubicación ±\(Int(last.horizontalAccuracy)) m") }
            self.navigator.update(location: last)
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

    // MARK: Log

    func log(_ text: String) {
        let t = Date().timeIntervalSince(startDate)
        lines.append(String(format: "%6.1fs ", t) + text)
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
    }
}
