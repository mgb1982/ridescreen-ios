import SwiftUI
import UIKit

enum RideBrand {
    static let background = Color(hex: 0x1A231D)
    static let surface = Color(hex: 0x243028)
    static let outline = Color(hex: 0x3D4F42)
    static let gold = Color(hex: 0xD1A955)
    static let text = Color(hex: 0xF1F4EC)
    static let secondary = Color(hex: 0xAEBAAA)
}

enum RideFont {
    static func regular(_ size: CGFloat) -> Font { .custom("Archivo-Regular", size: size, relativeTo: .body) }
    static func medium(_ size: CGFloat) -> Font { .custom("Archivo-Medium", size: size, relativeTo: .body) }
    static func semiBold(_ size: CGFloat) -> Font { .custom("Archivo-SemiBold", size: size, relativeTo: .headline) }
    static func extraBold(_ size: CGFloat) -> Font { .custom("Archivo-ExtraBold", size: size, relativeTo: .title) }
    static func black(_ size: CGFloat) -> Font { .custom("ArchivoBlack-Regular", size: size, relativeTo: .largeTitle) }
}

@main
struct RideScreenIOSApp: App {
    @StateObject private var viewModel = TripRecordingViewModel()
    @StateObject private var garage = GarageStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(viewModel)
                .environmentObject(garage)
                .onChange(of: scenePhase) { phase in
                    viewModel.handleScenePhase(active: phase == .active)
                }
        }
    }
}

struct MainTabView: View {
    @State private var selection: MainTab = .home

    var body: some View {
        TabView(selection: $selection) {
            HomeScreen(selection: $selection)
                .tabItem { Label("tab.home", systemImage: "house") }
                .tag(MainTab.home)
            RecordingScreen()
                .tabItem { Label("tab.record", systemImage: "record.circle") }
                .tag(MainTab.record)
            TripsScreen()
                .tabItem { Label("tab.trips", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }
                .tag(MainTab.trips)
            DiagnosticsScreen()
                .tabItem { Label("tab.diagnostics", systemImage: "stethoscope") }
                .tag(MainTab.diagnostics)
        }
        .tint(RideBrand.gold)
        .preferredColorScheme(.dark)
    }
}

struct RideScreenHeader: View {
    let eyebrow: LocalizedStringKey

    var body: some View {
        HStack(spacing: 10) {
            Image("RideScreenMark")
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text("Ride").foregroundStyle(RideBrand.text)
                    Text("Screen").foregroundStyle(RideBrand.gold)
                }
                .font(RideFont.black(22))
                .lineLimit(1)

                Text(eyebrow)
                    .font(RideFont.extraBold(10))
                    .tracking(1.8)
                    .foregroundStyle(RideBrand.secondary)
            }

            Spacer()
            Text("IOS")
                .font(RideFont.extraBold(10))
                .tracking(1.4)
                .foregroundStyle(RideBrand.gold)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(Capsule().stroke(RideBrand.outline, lineWidth: 1))
        }
        .frame(minHeight: 42)
    }
}

private struct MetricCard: View {
    let title: LocalizedStringKey
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(RideBrand.gold)
                Text(title)
                    .font(RideFont.semiBold(11))
                    .foregroundStyle(RideBrand.secondary)
            }
            Text(value)
                .font(RideFont.black(25))
                .foregroundStyle(RideBrand.text)
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .padding(15)
        .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(RideBrand.outline, lineWidth: 1))
    }
}

struct RecordingScreen: View {
    @EnvironmentObject private var viewModel: TripRecordingViewModel
    @State private var showRecoveryDialog = false

    var body: some View {
        ZStack {
            RideBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    RideScreenHeader(eyebrow: "record.header")
                    recordingStatus

                    if !viewModel.isRecording {
                        permissionExplanation
                    }

                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let metrics = viewModel.metrics(at: timeline.date)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                MetricCard(title: "record.metric.time", value: durationText(metrics.elapsedSeconds), symbol: "timer")
                                MetricCard(title: "record.metric.distance", value: String(format: NSLocalizedString("record.value.distance", comment: ""), metrics.distanceMeters / 1_000), symbol: "point.topleft.down.curvedto.point.bottomright.up")
                            }
                            HStack(spacing: 10) {
                                MetricCard(title: "record.metric.currentSpeed", value: String(format: NSLocalizedString("record.value.speed", comment: ""), Int((metrics.currentSpeedMetersPerSecond * 3.6).rounded())), symbol: "speedometer")
                                MetricCard(title: "record.metric.maxSpeed", value: String(format: NSLocalizedString("record.value.speed", comment: ""), Int((metrics.maximumSpeedMetersPerSecond * 3.6).rounded())), symbol: "gauge.with.dots.needle.67percent")
                            }
                        }
                    }

                    Button {
                        if viewModel.isRecording {
                            viewModel.stopTapped()
                        } else {
                            viewModel.startTapped()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: viewModel.isRecording ? "stop.fill" : "record.circle")
                            Text(viewModel.isRecording ? "record.stop" : "record.start")
                        }
                        .font(RideFont.extraBold(16))
                        .foregroundStyle(Color(hex: 0x18211A))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(RideBrand.gold, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Text("record.localOnly")
                        .font(RideFont.regular(12))
                        .foregroundStyle(RideBrand.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .alert(item: $viewModel.dialog) { dialog in
            alert(for: dialog)
        }
        .confirmationDialog("recovery.title", isPresented: $showRecoveryDialog, titleVisibility: .visible) {
            Button("recovery.recover") { viewModel.recoverPendingTrip() }
            Button("recovery.discard", role: .destructive) { viewModel.discardPendingTrip() }
        } message: {
            if let trip = viewModel.pendingTrip {
                Text(String(format: NSLocalizedString("recovery.message", comment: ""),
                            trip.points.count,
                            trip.distanceMeters / 1_000))
            } else {
                Text("recovery.message.fallback")
            }
        }
        .onChange(of: viewModel.pendingTrip?.id) { tripID in
            showRecoveryDialog = tripID != nil
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(viewModel.isRecording ? Color.red : RideBrand.gold)
                .frame(width: 9, height: 9)
            Text(viewModel.isRecording ? "record.status.recording" : "record.status.ready")
                .font(RideFont.extraBold(12))
                .tracking(1.4)
                .foregroundStyle(viewModel.isRecording ? Color.red : RideBrand.gold)
            Spacer()
            if viewModel.isRecording {
                Text(String(format: NSLocalizedString("record.points.count", comment: ""), viewModel.metrics(at: Date()).pointCount))
                    .font(RideFont.medium(11))
                    .foregroundStyle(RideBrand.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RideBrand.surface.opacity(0.8), in: Capsule())
        .overlay(Capsule().stroke(RideBrand.outline, lineWidth: 1))
    }

    private var permissionExplanation: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(RideBrand.gold)
            VStack(alignment: .leading, spacing: 5) {
                Text("record.permission.title")
                    .font(RideFont.semiBold(14))
                    .foregroundStyle(RideBrand.text)
                Text("record.permission.explanation")
                    .font(RideFont.regular(12))
                    .foregroundStyle(RideBrand.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("record.permission.always")
                    .font(RideFont.medium(11))
                    .foregroundStyle(RideBrand.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(RideBrand.outline, lineWidth: 1))
    }

    private func alert(for dialog: RecordingDialog) -> Alert {
        switch dialog {
        case .whenInUse:
            return Alert(
                title: Text("permission.when.title"),
                message: Text("permission.when.message"),
                primaryButton: .default(Text("common.continue"), action: { viewModel.requestWhenInUse() }),
                secondaryButton: .cancel(Text("common.cancel"))
            )
        case .always:
            return Alert(
                title: Text("permission.always.title"),
                message: Text("permission.always.message"),
                primaryButton: .default(Text("permission.always.allow"), action: { viewModel.requestAlways() }),
                secondaryButton: .default(Text("permission.always.foreground"), action: { viewModel.chooseForegroundOnly() })
            )
        case .permissionDenied:
            return Alert(
                title: Text("permission.denied.title"),
                message: Text("permission.denied.message"),
                primaryButton: .default(Text("permission.openSettings"), action: { viewModel.openSystemSettings() }),
                secondaryButton: .cancel(Text("common.cancel"))
            )
        case .backgroundUnavailable:
            return Alert(
                title: Text("permission.background.off.title"),
                message: Text("permission.background.off.message"),
                dismissButton: .default(Text("common.ok"))
            )
        case .locationServicesDisabled:
            return Alert(
                title: Text("permission.services.off.title"),
                message: Text("permission.services.off.message"),
                dismissButton: .default(Text("common.ok"))
            )
        case .failure(let key):
            return Alert(
                title: Text("common.error"),
                message: Text(LocalizedStringKey(key)),
                dismissButton: .default(Text("common.ok"))
            )
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let wholeSeconds = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", wholeSeconds / 3600, (wholeSeconds % 3600) / 60, wholeSeconds % 60)
    }
}

struct TripsScreen: View {
    @EnvironmentObject private var viewModel: TripRecordingViewModel

    var body: some View {
        NavigationStack {
        ZStack {
            RideBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RideScreenHeader(eyebrow: "trips.header")
                    if viewModel.completedTrips.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(viewModel.completedTrips) { trip in
                                NavigationLink {
                                    TripDetailScreen(trip: trip)
                                } label: {
                                    tripRow(trip)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            Task { try? await viewModel.refreshTrips() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: Binding(
            get: { viewModel.shareURL.map(ShareFile.init(url:)) },
            set: { value in if value == nil { viewModel.clearShareURL() } }
        )) { file in
            ActivityShareSheet(activityItems: [file.url])
                .ignoresSafeArea()
        }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 34))
                .foregroundStyle(RideBrand.gold)
            Text("trips.empty.title")
                .font(RideFont.black(20))
                .foregroundStyle(RideBrand.text)
            Text("trips.empty.message")
                .font(RideFont.regular(13))
                .foregroundStyle(RideBrand.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func tripRow(_ trip: RecordedTrip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trip.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(RideFont.semiBold(14))
                        .foregroundStyle(RideBrand.text)
                    Text(String(format: NSLocalizedString("trips.summary", comment: ""),
                                durationText(trip.elapsedDuration),
                                TripGeometry.resolvedDistance(stored: trip.distanceMeters, points: trip.points) / 1_000))
                        .font(RideFont.regular(12))
                        .foregroundStyle(RideBrand.secondary)
                }
                Spacer()
                Button {
                    viewModel.export(trip)
                } label: {
                    Label("trips.export", systemImage: "square.and.arrow.up")
                        .font(RideFont.semiBold(12))
                        .foregroundStyle(RideBrand.gold)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(15)
        .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(RideBrand.outline, lineWidth: 1))
        .contextMenu {
            Button(role: .destructive) {
                viewModel.delete(trip)
            } label: {
                Label("trips.delete", systemImage: "trash")
            }
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
    }
}

struct DiagnosticsScreen: View {
    @EnvironmentObject private var viewModel: TripRecordingViewModel

    var body: some View {
        ZStack {
            RideBackground()
            VStack(alignment: .leading, spacing: 14) {
                RideScreenHeader(eyebrow: "diagnostics.header")
                HStack {
                    Text(String(format: NSLocalizedString("diagnostics.lineCount", comment: ""), viewModel.diagnosticLines.count))
                        .font(RideFont.medium(11))
                        .foregroundStyle(RideBrand.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = viewModel.diagnosticLines.joined(separator: "\n")
                    } label: {
                        Label("diagnostics.copy", systemImage: "doc.on.doc")
                            .font(RideFont.semiBold(12))
                    }
                    .tint(RideBrand.gold)
                    ShareLink(item: viewModel.diagnosticLines.joined(separator: "\n")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(RideBrand.gold)
                }
                ScrollView {
                    Text(viewModel.diagnosticLines.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(RideBrand.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 18)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { viewModel.refreshDiagnostics() }
    }
}

struct RideBackground: View {
    var body: some View {
        ZStack {
            RideBrand.background
            RadialGradient(colors: [Color(hex: 0x2A3A30), .clear],
                           center: UnitPoint(x: 0.2, y: 0), startRadius: 0, endRadius: 720)
        }
        .ignoresSafeArea()
    }
}

private struct ShareFile: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}


extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
