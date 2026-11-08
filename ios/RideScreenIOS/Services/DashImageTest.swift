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
    /// One per app, so Siri can set a destination before the dash screen opens.
    static let shared = DashImageTest()

    private var link: DashLink?
    private var source: DashPictureSource?
    private let location = CLLocationManager()
    private var lastLocation: CLLocation?
    private var uiTimer: Timer?
    private var startDate = Date()
    private var appState = "app abierta"
    private var observers: [NSObjectProtocol] = []
    private var logFile: FileHandle?
    private var statsTimer: Timer?
    private var fixCount = 0
    private var fixDelaySum = 0.0
    private var fixDelayMax = 0.0
    private var lastFrames = 0
    private var wifiTimer: Timer?
    private var pendingHost = ""
    /// Trip recording started with the picture (stopped with it).
    var startTrip: (() -> Bool)?
    var stopTrip: (() -> Void)?
    private var tripStartedHere = false

    /// Start the picture as soon as the test screen opens (set after the first time the dash shows it).
    static var autoStart: Bool {
        get { UserDefaults.standard.bool(forKey: "dash.autoStart") }
        set { UserDefaults.standard.set(newValue, forKey: "dash.autoStart") }
    }

    /// The log is also written to a file, so it survives the app closing or the battery dying.
    /// Starting a test moves the previous run's file to [previousLogURL].
    static var logURL: URL { documents.appendingPathComponent("dash-log.txt") }
    static var previousLogURL: URL { documents.appendingPathComponent("dash-log-anterior.txt") }
    static var hasPreviousLog: Bool { FileManager.default.fileExists(atPath: previousLogURL.path) }
    private static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

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
        openLogFile()
        framesSent = 0
        isRunning = true
        let device = UIDevice.current
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log("RideScreen iOS · imagen propia · build \(build) · \(device.systemName) \(device.systemVersion) · \(device.model)")
        device.isBatteryMonitoringEnabled = true
        log(statusLine(prefix: "Inicio"))

        startLocation()
        observeAppState()
        if let startTrip, startTrip() {
            tripStartedHere = true
            log("Viaje: grabando mientras se proyecta")
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.logMinute() }
        }
        pendingHost = host
        if !connectIfWifi() {
            log("Esperando al Wi‑Fi de la moto (ZT…); se conectará solo al unirse")
            wifiTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    if self.connectIfWifi() { self.wifiTimer?.invalidate(); self.wifiTimer = nil }
                }
            }
        }
    }

    /// Connects to the dash once the phone has an IPv4 on Wi‑Fi. False while there is none.
    private func connectIfWifi() -> Bool {
        guard let wifi = MirrorLinkTester.wifiIPv4() else { return false }
        let host = pendingHost
        let target = host.trimmingCharacters(in: .whitespaces).isEmpty ? wifi.gatewayGuess : host.trimmingCharacters(in: .whitespaces)
        log("Wi‑Fi \(wifi.address) · cuadro \(target)")

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
        return true
    }

    func stop() {
        guard isRunning else { return }
        link?.stop(); link = nil
        source?.stop(); source = nil
        uiTimer?.invalidate(); uiTimer = nil
        statsTimer?.invalidate(); statsTimer = nil
        wifiTimer?.invalidate(); wifiTimer = nil
        if tripStartedHere {
            stopTrip?()
            tripStartedHere = false
            log("Viaje: guardado")
        }
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        isRunning = false
        streaming = false
        log("Prueba detenida · \(framesSent) imágenes enviadas · " + statusLine(prefix: "Fin"))
        try? logFile?.synchronize()
        try? logFile?.close()
        logFile = nil
    }

    // MARK: State

    private func setStreaming(_ on: Bool) {
        guard streaming != on else { return }
        streaming = on
        if on { Self.autoStart = true }
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
            let delay = Date().timeIntervalSince(last.timestamp)
            self.fixCount += 1
            self.fixDelaySum += delay
            self.fixDelayMax = max(self.fixDelayMax, delay)
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

    /// Once a minute: battery, temperature, frame rate, drawing cost and GPS delay — to measure how
    /// much the test costs per hour and whether the picture keeps up.
    private func logMinute() {
        let sent = link?.sentCount ?? 0
        let stats = source?.takeStats() ?? (frames: 0, drawMs: 0)
        let gps = fixCount > 0
            ? String(format: "GPS %ld fijaciones, retraso medio %.1f s (máx %.1f)", fixCount, fixDelaySum / Double(fixCount), fixDelayMax)
            : "GPS sin fijaciones"
        log(statusLine(prefix: "Minuto") + String(format: " · %.1f img/s dibujadas (%.0f ms c/u) · %.1f img/s enviadas · ",
                                                    Double(stats.frames) / 60, stats.drawMs, Double(sent - lastFrames) / 60) + gps)
        lastFrames = sent
        fixCount = 0; fixDelaySum = 0; fixDelayMax = 0
        try? logFile?.synchronize()
    }

    private func statusLine(prefix: String) -> String {
        let device = UIDevice.current
        let level = device.batteryLevel < 0 ? "?" : "\(Int((device.batteryLevel * 100).rounded()))%"
        let charging: String
        switch device.batteryState {
        case .charging: charging = " cargando"
        case .full: charging = " llena"
        default: charging = ""
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "normal"
        case .fair: thermal = "templado"
        case .serious: thermal = "caliente"
        case .critical: thermal = "crítico"
        @unknown default: thermal = "?"
        }
        let clock = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? " · ahorro" : ""
        return "\(prefix) \(clock) · batería \(level)\(charging)\(lowPower) · temp. \(thermal) · \(appState)"
    }

    private func openLogFile() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.logURL.path) {
            try? fm.removeItem(at: Self.previousLogURL)
            try? fm.moveItem(at: Self.logURL, to: Self.previousLogURL)
        }
        fm.createFile(atPath: Self.logURL.path, contents: nil)
        logFile = try? FileHandle(forWritingTo: Self.logURL)
    }

    func log(_ text: String) {
        let t = Date().timeIntervalSince(startDate)
        let line = String(format: "%6.1fs ", t) + text
        lines.append(line)
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
        if let data = (line + "\n").data(using: .utf8) { try? logFile?.write(contentsOf: data) }
    }
}
