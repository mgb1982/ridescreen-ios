import Combine
import CoreLocation
import Foundation
import UIKit

enum RecordingDialog: Identifiable {
    case whenInUse
    case always
    case permissionDenied
    case backgroundUnavailable
    case locationServicesDisabled
    case failure(String)

    var id: String {
        switch self {
        case .whenInUse: return "whenInUse"
        case .always: return "always"
        case .permissionDenied: return "permissionDenied"
        case .backgroundUnavailable: return "backgroundUnavailable"
        case .locationServicesDisabled: return "locationServicesDisabled"
        case .failure: return "failure"
        }
    }
}

@MainActor
final class TripRecordingViewModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isLoading = true
    @Published private(set) var liveMetrics = TripLiveMetrics(
        elapsedSeconds: 0,
        distanceMeters: 0,
        currentSpeedMetersPerSecond: 0,
        maximumSpeedMetersPerSecond: 0,
        pointCount: 0
    )
    @Published private(set) var completedTrips: [RecordedTrip] = []
    @Published private(set) var pendingTrip: RecordedTrip?
    @Published private(set) var diagnosticLines: [String] = []
    @Published private(set) var shareURL: URL?
    @Published var dialog: RecordingDialog?

    let locationService = TripLocationService()

    private let store = TripJournalStore()
    private let diagnostics = TripDiagnosticsLogger.shared
    private var tracker: TripTracker?
    private var activeTripID: String?
    private var persistenceTask: Task<Void, Never>?
    private var awaitingWhenInUse = false
    private var awaitingAlways = false
    private var didRequestAlways = UserDefaults.standard.bool(forKey: "ridescreen.location.alwaysRequested")

    init() {
        locationService.onLocation = { [weak self] fix, distance in
            self?.receive(fix, segmentDistanceMeters: distance) ?? false
        }
        locationService.onAuthorizationChanged = { [weak self] status in
            self?.authorizationChanged(status)
        }
        locationService.onError = { [weak self] message in
            self?.log("CoreLocation error: \(message)")
        }

        Task { await bootstrap() }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.applicationWillTerminate()
            }
        }
    }

    var authorizationStatus: CLAuthorizationStatus {
        locationService.authorizationStatus
    }

    func startTapped() {
        guard !isRecording else { return }
        switch locationService.authorizationStatus {
        case .notDetermined:
            dialog = .whenInUse
        case .authorizedWhenInUse:
            if didRequestAlways {
                startActiveTrip(backgroundAllowed: false)
            } else {
                dialog = .always
            }
        case .authorizedAlways:
            startActiveTrip(backgroundAllowed: true)
        case .denied, .restricted:
            dialog = .permissionDenied
        @unknown default:
            dialog = .permissionDenied
        }
    }

    func requestWhenInUse() {
        awaitingWhenInUse = true
        log("Location permission request: When In Use")
        locationService.requestWhenInUseAuthorization()
    }

    func requestAlways() {
        awaitingAlways = true
        didRequestAlways = true
        UserDefaults.standard.set(true, forKey: "ridescreen.location.alwaysRequested")
        log("Location permission request: Always, after user pressed Start")
        locationService.requestAlwaysAuthorization()
    }

    func chooseForegroundOnly() {
        didRequestAlways = true
        UserDefaults.standard.set(true, forKey: "ridescreen.location.alwaysRequested")
        startActiveTrip(backgroundAllowed: false)
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func stopTapped() {
        guard isRecording else { return }
        locationService.stopUpdating()
        isRecording = false
        let finishedTrip = tracker?.completed(at: Date())
        log("Recording stopped; points=\(finishedTrip?.points.count ?? 0) distance=\(Int(finishedTrip?.distanceMeters ?? 0))m maxSpeed=\(String(format: "%.1f", finishedTrip?.maximumSpeedMetersPerSecond ?? 0))m/s")
        Task {
            await persistenceTask?.value
            do {
                if let finishedTrip {
                    try await store.finish(finishedTrip)
                }
                await logAsync("Trip journal finalized")
                tracker = nil
                activeTripID = nil
                liveMetrics = TripLiveMetrics(
                    elapsedSeconds: 0, distanceMeters: 0,
                    currentSpeedMetersPerSecond: 0, maximumSpeedMetersPerSecond: 0,
                    pointCount: 0
                )
                try await refreshTrips()
            } catch {
                await logAsync("Failed to finalize trip journal: \(error.localizedDescription)")
                dialog = .failure("trip.error.finish")
            }
        }
    }

    func recoverPendingTrip() {
        guard let pendingTrip else { return }
        Task {
            do {
                let recovered = try await store.resume(id: pendingTrip.id)
                tracker = TripTracker(restoring: recovered)
                activeTripID = recovered.id
                self.pendingTrip = nil
                liveMetrics = tracker?.liveMetrics() ?? liveMetrics
                locationService.restorePreviousPoint(recovered.points.last)
                await logAsync("Recovered interrupted trip; points=\(recovered.points.count)")
                startTapped()
            } catch {
                await logAsync("Trip recovery failed: \(error.localizedDescription)")
                dialog = .failure("trip.error.recovery")
            }
        }
    }

    func discardPendingTrip() {
        guard let pendingTrip else { return }
        Task {
            do {
                try await store.discardPending(id: pendingTrip.id)
                self.pendingTrip = nil
                await logAsync("Interrupted trip discarded by user")
            } catch {
                await logAsync("Could not discard interrupted trip: \(error.localizedDescription)")
                dialog = .failure("trip.error.discard")
            }
        }
    }

    func export(_ trip: RecordedTrip) {
        Task {
            do {
                shareURL = try await store.exportURL(for: trip)
                await logAsync("GPX export prepared; points=\(trip.points.count)")
            } catch {
                await logAsync("GPX export failed: \(error.localizedDescription)")
                dialog = .failure("trip.error.export")
            }
        }
    }

    func clearShareURL() {
        shareURL = nil
    }

    func delete(_ trip: RecordedTrip) {
        Task {
            do {
                try await store.deleteTrip(id: trip.id)
                try await refreshTrips()
                await logAsync("Saved trip deleted by user")
            } catch {
                await logAsync("Trip deletion failed: \(error.localizedDescription)")
            }
        }
    }

    func refreshTrips() async throws {
        completedTrips = try await store.completedTrips()
    }

    func refreshDiagnostics() {
        Task {
            do {
                diagnosticLines = try await diagnostics.recentLines()
            } catch {
                diagnosticLines = ["Unable to read local diagnostics: \(error.localizedDescription)"]
            }
        }
    }

    func handleScenePhase(active: Bool) {
        if active {
            log("Application became active")
            refreshDiagnostics()
            Task { try? await refreshTrips() }
        } else {
            Task {
                await persistenceTask?.value
                do {
                    try await store.flush()
                    await logAsync("Application entered background; trip journal synchronized")
                } catch {
                    await logAsync("Background synchronization failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func metrics(at date: Date) -> TripLiveMetrics {
        tracker?.liveMetrics(now: date) ?? liveMetrics
    }

    private func bootstrap() async {
        do {
            try await refreshTrips()
            let interrupted = try await store.pendingTrips()
            pendingTrip = interrupted.first
            if let pendingTrip {
                await logAsync("Found interrupted trip awaiting user decision; points=\(pendingTrip.points.count)")
            }
            diagnosticLines = try await diagnostics.recentLines()
            await logAsync("Application started")
            diagnosticLines = try await diagnostics.recentLines()
        } catch {
            await logAsync("Startup recovery scan failed: \(error.localizedDescription)")
        }
        isLoading = false
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        log("Location authorization changed: \(authorizationLabel(status))")

        if awaitingWhenInUse {
            awaitingWhenInUse = false
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                dialog = .always
            } else {
                dialog = .permissionDenied
            }
            return
        }

        if awaitingAlways {
            if status == .authorizedAlways {
                awaitingAlways = false
                startActiveTrip(backgroundAllowed: true)
            } else if status == .authorizedWhenInUse {
                awaitingAlways = false
                startActiveTrip(backgroundAllowed: false)
                dialog = .backgroundUnavailable
            } else if status == .denied || status == .restricted {
                awaitingAlways = false
                dialog = .permissionDenied
            }
        }
    }

    private func authorizationLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown"
        }
    }

    private func startActiveTrip(backgroundAllowed: Bool) {
        guard locationService.servicesEnabled else {
            dialog = .locationServicesDisabled
            return
        }

        Task {
            do {
                if activeTripID == nil {
                    let id = UUID().uuidString
                    let startedAt = Date()
                    try await store.begin(id: id, startedAt: startedAt)
                    tracker = TripTracker(id: id, startedAt: startedAt)
                    activeTripID = id
                }

                locationService.startUpdating(backgroundAllowed: backgroundAllowed)
                isRecording = true
                liveMetrics = tracker?.liveMetrics() ?? liveMetrics
                log("Recording started; backgroundLocation=\(backgroundAllowed)")
            } catch {
                await logAsync("Could not start trip journal: \(error.localizedDescription)")
                dialog = .failure("trip.error.start")
            }
        }
    }

    @discardableResult
    private func receive(_ fix: GPSFix, segmentDistanceMeters: Double?) -> Bool {
        guard var activeTracker = tracker, isRecording || activeTripID != nil else { return false }
        let update = activeTracker.ingest(
            fix,
            now: Date(),
            segmentDistanceMeters: segmentDistanceMeters
        )

        switch update {
        case .rejected(let reason):
            log("GPS point discarded: \(reason.rawValue)")
            return false

        case .accepted(let point, _, _):
            tracker = activeTracker
            liveMetrics = activeTracker.liveMetrics()
            enqueuePersistence(point: point, trip: activeTracker.trip)
            return true
        }
    }

    private func enqueuePersistence(point: TripPoint, trip: RecordedTrip) {
        let previousTask = persistenceTask
        persistenceTask = Task {
            await previousTask?.value
            do {
                try await store.append(
                    point: point,
                    distanceMeters: trip.distanceMeters,
                    movingTimeMilliseconds: trip.movingTimeMilliseconds,
                    maximumSpeedMetersPerSecond: trip.maximumSpeedMetersPerSecond
                )
            } catch {
                await logAsync("Incremental trip write failed: \(error.localizedDescription)")
                locationService.stopUpdating()
                isRecording = false
                dialog = .failure("trip.error.persistence")
            }
        }
    }

    private func log(_ message: String) {
        Task { await logAsync(message) }
    }

    private func logAsync(_ message: String) async {
        do {
            try await diagnostics.append(message)
            diagnosticLines = try await diagnostics.recentLines()
        } catch {
            // Diagnostics must never interrupt recording.
        }
    }

    private func applicationWillTerminate() async {
        await persistenceTask?.value
        try? await store.flush()
        await logAsync("Application termination callback received")
    }
}

