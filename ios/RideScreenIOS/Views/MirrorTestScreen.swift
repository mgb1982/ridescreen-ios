import SwiftUI
import MapKit
import UIKit
import VisionKit

/// Home card that opens the mirroring field test.
struct MirrorTestEntryCard: View {
    @EnvironmentObject private var trips: TripRecordingViewModel
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 18))
                    .foregroundStyle(RideBrand.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("mirror.test.entry")
                        .font(RideFont.semiBold(14))
                        .foregroundStyle(RideBrand.text)
                    Text("mirror.test.entrySubtitle")
                        .font(RideFont.regular(12))
                        .foregroundStyle(RideBrand.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RideBrand.secondary)
            }
            .padding(16)
            .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(RideBrand.outline, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            NavigationStack { MirrorTestScreen() }.environmentObject(trips)
        }
    }
}

/// Field test: 1) read the dash QR, 2) join its Wi‑Fi, 3) check EasyConn and the callback, 4) try capture.
struct MirrorTestScreen: View {
    @StateObject private var tester = MirrorLinkTester()
    @ObservedObject private var imageTest = DashImageTest.shared
    @EnvironmentObject private var trips: TripRecordingViewModel
    /// The dash QR (Wi‑Fi name and password) and the dash address are kept on this phone.
    @AppStorage("dash.qr") private var savedQR = ""
    @AppStorage("dash.host") private var savedHost = ""
    @State private var qr: MirrorQR?
    @State private var showingScanner = false
    @State private var pasted = ""
    @State private var copied: String?
    @State private var isCaptured = UIScreen.main.isCaptured

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                step(1, "mirror.test.step1") { qrSection }
                step(2, "mirror.test.step2") {
                    Text("mirror.test.step2.body")
                        .font(RideFont.regular(13))
                        .foregroundStyle(RideBrand.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                step(3, "mirror.test.step3") { linkSection }
                step(4, "mirror.test.step4") { captureSection }
                step(5, "dash.image.step") { imageSection }
            }
            .padding(16)
        }
        .background(RideBrand.background.ignoresSafeArea())
        .navigationTitle(Text("mirror.test.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingScanner) {
            QRScannerView { value in
                showingScanner = false
                qr = MirrorQR.parse(value)
                if qr == nil { pasted = value }
            }
            .ignoresSafeArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            isCaptured = UIScreen.main.isCaptured
        }
        .onAppear {
            if qr == nil, let restored = MirrorQR.parse(savedQR) { qr = restored }
            if tester.bikeHost.isEmpty { tester.bikeHost = savedHost }
            let recorder = trips
            imageTest.startTrip = { [weak recorder] in recorder?.startForDash() ?? false }
            imageTest.stopTrip = { [weak recorder] in recorder?.stopTapped() }
            imageTest.tripMetrics = { [weak recorder] in recorder?.liveMetrics }
            if DashImageTest.autoStart && !imageTest.isRunning && !tester.isRunning {
                imageTest.start(host: tester.bikeHost)
            }
        }
        .onChange(of: qr) { value in if let value { savedQR = value.raw } }
        .onChange(of: tester.bikeHost) { value in savedHost = value }
        .onDisappear { tester.stop(); imageTest.stop() }
    }

    // MARK: Sections

    private var qrSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if QRScannerView.isAvailable {
                Button { showingScanner = true } label: {
                    Label("mirror.test.scan", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .tint(RideBrand.gold)
            }
            TextField("mirror.test.pastePlaceholder", text: $pasted, axis: .vertical)
                .font(RideFont.regular(13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(RideBrand.background, in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: pasted) { value in
                    if let parsed = MirrorQR.parse(value) { qr = parsed }
                }
            if let qr {
                credentialRow("mirror.test.network", qr.ssid)
                credentialRow("mirror.test.password", qr.password.isEmpty ? "—" : qr.password, copyValue: qr.password)
            } else if !pasted.isEmpty {
                Text("mirror.test.qrInvalid")
                    .font(RideFont.medium(12))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("mirror.test.dashAddress")
                    .font(RideFont.medium(13))
                    .foregroundStyle(RideBrand.secondary)
                TextField(text: $tester.bikeHost, prompt: Text(verbatim: "192.168.3.1")) { Text(verbatim: "IP") }
                    .font(RideFont.regular(13))
                    .keyboardType(.decimalPad)
                    .disabled(tester.isRunning)
            }
            HStack(spacing: 10) {
                Button {
                    if tester.isRunning { tester.stop() } else { imageTest.stop(); tester.start() }
                } label: {
                    Label(LocalizedStringKey(tester.isRunning ? "mirror.test.stop" : "mirror.test.start"),
                          systemImage: tester.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(RideBrand.gold)
                if tester.isRunning { ProgressView() }
                Spacer()
                if !tester.lines.isEmpty {
                    Button {
                        UIPasteboard.general.string = tester.logText
                        copied = "log"
                    } label: { Image(systemName: copied == "log" ? "checkmark" : "doc.on.doc") }
                    ShareLink(item: tester.logText) { Image(systemName: "square.and.arrow.up") }
                }
            }
            if !tester.lines.isEmpty {
                ScrollView(.horizontal) {
                    Text(tester.logText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(RideBrand.text)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// Step 5: RideScreen's own picture on the dash, kept alive with the phone locked.
    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("dash.image.body")
                .font(RideFont.regular(13))
                .foregroundStyle(RideBrand.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DashDestinationPicker(navigator: imageTest.navigator)
            HStack(spacing: 10) {
                Button {
                    if imageTest.isRunning {
                        imageTest.stop()
                    } else {
                        tester.stop()   // both tests use ports 10920–10922
                        imageTest.start(host: tester.bikeHost)
                    }
                } label: {
                    Label(LocalizedStringKey(imageTest.isRunning ? "mirror.test.stop" : "dash.image.start"),
                          systemImage: imageTest.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(RideBrand.gold)
                if imageTest.isRunning {
                    Label(imageTest.streaming ? "\(imageTest.framesSent)" : "…",
                          systemImage: imageTest.streaming ? "dot.radiowaves.left.and.right" : "hourglass")
                        .font(RideFont.semiBold(13))
                        .foregroundStyle(imageTest.streaming ? Color.green : RideBrand.secondary)
                }
                Spacer()
                if !imageTest.lines.isEmpty {
                    Button {
                        UIPasteboard.general.string = imageTest.logText
                        copied = "imagelog"
                    } label: { Image(systemName: copied == "imagelog" ? "checkmark" : "doc.on.doc") }
                    ShareLink(item: imageTest.logText) { Image(systemName: "square.and.arrow.up") }
                }
            }
            if !imageTest.isRunning && DashImageTest.hasPreviousLog {
                ShareLink(item: DashImageTest.previousLogURL) {
                    Label("dash.log.previous", systemImage: "clock.arrow.circlepath")
                }
                .font(RideFont.medium(13))
            }
            if !imageTest.lines.isEmpty {
                ScrollView(.horizontal) {
                    Text(imageTest.logText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(RideBrand.text)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("mirror.capture.description")
                .font(RideFont.regular(13))
                .foregroundStyle(RideBrand.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                ScreenBroadcastPicker()
                    .frame(width: 52, height: 52)
                    .accessibilityLabel(Text("mirror.capture.start"))
                Label(LocalizedStringKey(isCaptured ? "mirror.test.captureOn" : "mirror.test.captureOff"),
                      systemImage: isCaptured ? "record.circle.fill" : "circle")
                    .font(RideFont.semiBold(13))
                    .foregroundStyle(isCaptured ? Color.red : RideBrand.secondary)
            }
            Text("mirror.capture.limit")
                .font(RideFont.medium(12))
                .foregroundStyle(RideBrand.gold)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Building blocks

    private func step<Content: View>(_ number: Int, _ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: "\(number)")
                    .font(RideFont.extraBold(13))
                    .foregroundStyle(RideBrand.background)
                    .frame(width: 22, height: 22)
                    .background(RideBrand.gold, in: Circle())
                Text(title)
                    .font(RideFont.semiBold(15))
                    .foregroundStyle(RideBrand.text)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(RideBrand.outline, lineWidth: 1))
    }

    private func credentialRow(_ label: LocalizedStringKey, _ value: String, copyValue: String? = nil) -> some View {
        HStack {
            Text(label)
                .font(RideFont.medium(13))
                .foregroundStyle(RideBrand.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(RideBrand.text)
                .textSelection(.enabled)
            Spacer()
            Button {
                UIPasteboard.general.string = copyValue ?? value
                copied = value
            } label: { Image(systemName: copied == value ? "checkmark" : "doc.on.doc") }
        }
    }
}

/// VisionKit QR scanner (iPhone XS and later). Returns the first QR payload it reads.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue {
                    delivered = true
                    scanner.stopScanning()
                    onCode(value)
                    return
                }
            }
        }
    }
}

/// Destination for the dash navigation: search (Apple Maps), pick, clear.
private struct DashDestinationPicker: View {
    @ObservedObject var navigator: DashNavigator
    @State private var query = ""
    @State private var places = DashPlaces.all
    @State private var renaming: DashPlace?
    @State private var newName = ""
    @State private var tilesInfo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = navigator.destinationName {
                HStack(spacing: 8) {
                    Image(systemName: "flag.checkered").foregroundStyle(RideBrand.gold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: name).font(RideFont.semiBold(14)).foregroundStyle(RideBrand.text)
                        if let summary = navigator.routeSummary {
                            Text(verbatim: summary).font(RideFont.regular(12)).foregroundStyle(RideBrand.secondary)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) { navigator.clearDestination() } label: {
                        Label("dash.nav.clear", systemImage: "xmark.circle.fill")
                    }
                    .font(RideFont.medium(13))
                }
            } else {
                HStack(spacing: 8) {
                    TextField("dash.nav.placeholder", text: $query)
                        .font(RideFont.regular(14))
                        .submitLabel(.search)
                        .onSubmit { navigator.search(query) }
                        .padding(10)
                        .background(RideBrand.background, in: RoundedRectangle(cornerRadius: 10))
                    if navigator.searching {
                        ProgressView()
                    } else {
                        Button { navigator.search(query) } label: { Image(systemName: "magnifyingglass") }
                            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !navigator.hasFix {
                    Text("dash.nav.noFix").font(RideFont.regular(12)).foregroundStyle(RideBrand.secondary)
                }
                ForEach(Array(navigator.results.enumerated()), id: \.offset) { _, item in
                    Button { navigator.setDestination(item); query = "" } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.name ?? "—").font(RideFont.semiBold(14)).foregroundStyle(RideBrand.text)
                            if let address = item.placemark.title {
                                Text(verbatim: address).font(RideFont.regular(12)).foregroundStyle(RideBrand.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RideBrand.background, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                if navigator.results.isEmpty && !places.isEmpty {
                    Text("dash.nav.saved").font(RideFont.semiBold(12)).foregroundStyle(RideBrand.secondary)
                    ForEach(places.sorted { $0.favourite && !$1.favourite }) { place in
                        HStack(spacing: 8) {
                            Button { navigator.setDestination(place.mapItem); places = DashPlaces.all } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: place.name).font(RideFont.semiBold(14)).foregroundStyle(RideBrand.text)
                                    if !place.address.isEmpty {
                                        Text(verbatim: place.address).font(RideFont.regular(12)).foregroundStyle(RideBrand.secondary).lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Button { DashPlaces.toggleFavourite(place.id); places = DashPlaces.all } label: {
                                Image(systemName: place.favourite ? "star.fill" : "star")
                                    .foregroundStyle(place.favourite ? RideBrand.gold : RideBrand.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(8)
                        .background(RideBrand.background, in: RoundedRectangle(cornerRadius: 8))
                        .contextMenu {
                            Button { newName = place.name; renaming = place } label: { Label("dash.nav.rename", systemImage: "pencil") }
                            Button(role: .destructive) { DashPlaces.remove(place.id); places = DashPlaces.all } label: {
                                Label("dash.nav.delete", systemImage: "trash")
                            }
                        }
                    }
                    Text("dash.nav.siriHint").font(RideFont.regular(11)).foregroundStyle(RideBrand.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                if let progress = navigator.areaProgress {
                    ProgressView().controlSize(.small)
                    Text(verbatim: progress).font(RideFont.medium(12)).foregroundStyle(RideBrand.secondary)
                    Button("pke.cancel") { navigator.cancelAreaDownload() }.font(RideFont.medium(12))
                } else {
                    Menu {
                        ForEach([10, 25, 50], id: \.self) { km in
                            Button("\(km) km") { navigator.downloadArea(radiusKm: Double(km)) }
                        }
                        Button("dash.map.clear", role: .destructive) { navigator.tiles.clear(); tilesInfo = navigator.tiles.summary }
                    } label: {
                        Label("dash.map.download", systemImage: "square.and.arrow.down.on.square")
                    }
                    .font(RideFont.medium(13))
                    .disabled(!navigator.hasFix)
                    Text(verbatim: tilesInfo).font(RideFont.regular(11)).foregroundStyle(RideBrand.secondary)
                }
            }
        }
        .onAppear { places = DashPlaces.all; tilesInfo = navigator.tiles.summary }
        .onChange(of: navigator.areaProgress) { _ in tilesInfo = navigator.tiles.summary }
        .onChange(of: navigator.destinationName) { _ in places = DashPlaces.all }
        .alert("dash.nav.rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("dash.nav.renamePlaceholder", text: $newName)
            Button("pke.save") { if let r = renaming { DashPlaces.rename(r.id, to: newName); places = DashPlaces.all }; renaming = nil }
            Button("pke.cancel", role: .cancel) { renaming = nil }
        }
    }
}
