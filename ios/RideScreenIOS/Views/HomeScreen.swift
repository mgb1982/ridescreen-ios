import PhotosUI
import SwiftUI

enum MainTab: Hashable {
    case home, record, trips, diagnostics
}

/// Start screen: the rider's bike with its garage photo, live speed / trip / day figures and shortcuts.
struct HomeScreen: View {
    @EnvironmentObject private var viewModel: TripRecordingViewModel
    @EnvironmentObject private var garage: GarageStore
    @Binding var selection: MainTab
    @State private var showEditor = false
    @State private var showShareChoices = false

    private var trips: [RecordedTrip] { viewModel.completedTrips }

    var body: some View {
        ZStack {
            RideBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    RideScreenHeader(eyebrow: "tab.home")
                    hero
                    liveSection
                    tripsCard
                    HStack(alignment: .top, spacing: 12) {
                        shareCard
                        settingsCard
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
        .sheet(isPresented: $showEditor) {
            BikeEditorSheet()
                .environmentObject(garage)
        }
        .confirmationDialog("start.share.title", isPresented: $showShareChoices, titleVisibility: .visible) {
            if let latest = trips.first {
                Button("start.share.lastTrip") {
                    viewModel.export(latest)
                    selection = .trips
                }
            }
            Button("start.share.diagnostics") { selection = .diagnostics }
            Button("common.cancel", role: .cancel) {}
        }
    }

    // MARK: Garage

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            heroBackground
            LinearGradient(
                colors: [.clear, RideBrand.background.opacity(0.92)],
                startPoint: UnitPoint(x: 0.5, y: 0.35),
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 6) {
                Text("start.garage.eyebrow")
                    .font(RideFont.extraBold(10.5))
                    .tracking(2.2)
                    .foregroundStyle(RideBrand.gold)
                Group {
                    if garage.bikeName.isEmpty {
                        Text("start.name.placeholder")
                            .foregroundStyle(RideBrand.secondary)
                    } else {
                        Text(verbatim: garage.bikeName)
                            .foregroundStyle(RideBrand.text)
                    }
                }
                .font(RideFont.black(30))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                Text(summary)
                    .font(RideFont.regular(13))
                    .foregroundStyle(RideBrand.secondary)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 224)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(RideBrand.outline, lineWidth: 1.5))
        .overlay(alignment: .topTrailing) {
            Button {
                showEditor = true
            } label: {
                Label("start.edit", systemImage: "pencil")
                    .font(RideFont.semiBold(12))
                    .foregroundStyle(RideBrand.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RideBrand.background.opacity(0.75), in: Capsule())
                    .overlay(Capsule().stroke(RideBrand.outline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { showEditor = true }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var heroBackground: some View {
        if let photo = garage.photo {
            Color.clear
                .overlay(alignment: .top) {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .accessibilityHidden(true)
                }
                .clipped()
        } else {
            ZStack {
                RideBrand.surface
                VStack(spacing: 10) {
                    Image(systemName: "camera")
                        .font(.system(size: 30))
                        .foregroundStyle(RideBrand.gold)
                    Text("start.photo.placeholder")
                        .font(RideFont.regular(13))
                        .foregroundStyle(RideBrand.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 70)
                .padding(.horizontal, 30)
            }
        }
    }

    private var summary: String {
        guard !trips.isEmpty else { return NSLocalizedString("start.summary.none", comment: "") }
        let km = Self.kmText(TripStats.totalDistanceMeters(trips))
        let key = trips.count == 1 ? "start.summary.one" : "start.summary.other"
        return String(format: NSLocalizedString(key, comment: ""), km, trips.count)
    }

    // MARK: Live figures

    private var liveSection: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let metrics = viewModel.metrics(at: timeline.date)
            let recording = viewModel.isRecording
            let todayMeters = TripStats.distanceMeters(on: timeline.date, trips: trips)
                + (recording ? metrics.distanceMeters : 0)
            VStack(alignment: .leading, spacing: 10) {
                statusPill(recording: recording, elapsed: metrics.elapsedSeconds)
                HStack(spacing: 10) {
                    tile(
                        "start.tile.speed",
                        value: "\(Int((metrics.currentSpeedMetersPerSecond * 3.6).rounded()))",
                        unit: "km/h", emphasized: true, active: recording
                    )
                    tile("start.tile.trip", value: Self.kmText(metrics.distanceMeters), unit: "km", emphasized: false, active: recording)
                    tile("start.tile.today", value: Self.kmText(todayMeters), unit: "km", emphasized: false, active: true)
                }
            }
        }
    }

    private func statusPill(recording: Bool, elapsed: TimeInterval) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(recording ? Color(hex: 0x5BD47A) : RideBrand.secondary.opacity(0.6))
                .frame(width: 8, height: 8)
            Text(recording ? LocalizedStringKey("start.recording") : LocalizedStringKey("start.idle"))
            if recording {
                Text(Self.duration(elapsed))
            }
        }
        .font(RideFont.extraBold(10.5))
        .tracking(1.6)
        .foregroundStyle(RideBrand.secondary)
    }

    private func tile(_ title: LocalizedStringKey, value: String, unit: String, emphasized: Bool, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(RideFont.extraBold(9.5))
                .tracking(1.4)
                .foregroundStyle(RideBrand.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(RideFont.black(emphasized ? 30 : 22))
                    .foregroundStyle(active ? (emphasized ? RideBrand.gold : RideBrand.text) : RideBrand.secondary.opacity(0.55))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(unit)
                    .font(RideFont.semiBold(10))
                    .foregroundStyle(RideBrand.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(RideBrand.outline, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
    }

    // MARK: Cards

    private var tripsCard: some View {
        Button {
            selection = .trips
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    iconBox("point.topleft.down.curvedto.point.bottomright.up")
                    Text("start.trips.title")
                        .font(RideFont.extraBold(12.5))
                        .tracking(1.4)
                        .foregroundStyle(RideBrand.text)
                        .textCase(.uppercase)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RideBrand.secondary)
                }
                if let latest = trips.first {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(latest.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(RideFont.semiBold(14))
                            .foregroundStyle(RideBrand.text)
                        Text("\(Self.kmText(latest.distanceMeters)) km · \(Self.duration(latest.elapsedDuration))")
                            .font(RideFont.regular(12))
                            .foregroundStyle(RideBrand.secondary)
                    }
                } else {
                    Text("start.trips.empty")
                        .font(RideFont.regular(13))
                        .foregroundStyle(RideBrand.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(RideBrand.outline, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var shareCard: some View {
        Button {
            showShareChoices = true
        } label: {
            miniCard(symbol: "square.and.arrow.up", title: "start.share.title", text: "start.share.desc")
        }
        .buttonStyle(.plain)
    }

    private var settingsCard: some View {
        Button {
            viewModel.openSystemSettings()
        } label: {
            miniCard(symbol: "slider.horizontal.3", title: "start.settings.title", text: "start.settings.desc")
        }
        .buttonStyle(.plain)
    }

    private func miniCard(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            iconBox(symbol)
            Text(title)
                .font(RideFont.extraBold(12.5))
                .tracking(1.4)
                .foregroundStyle(RideBrand.text)
                .textCase(.uppercase)
            Text(text)
                .font(RideFont.regular(12.5))
                .foregroundStyle(RideBrand.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .padding(14)
        .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(RideBrand.outline, lineWidth: 1.5))
    }

    private func iconBox(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(RideBrand.gold)
            .frame(width: 34, height: 34)
            .background(Color(hex: 0x2D3B31), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }

    // MARK: Formatting

    static func kmText(_ meters: Double) -> String {
        (max(0, meters) / 1_000).formatted(.number.precision(.fractionLength(1)))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// Sheet to name the bike and pick its garage photo.
struct BikeEditorSheet: View {
    @EnvironmentObject private var garage: GarageStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var photoFailed = false

    var body: some View {
        ZStack {
            RideBrand.surface.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text("start.editor.title")
                    .font(RideFont.black(22))
                    .foregroundStyle(RideBrand.text)

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("start.editor.name")
                    TextField("start.editor.namePlaceholder", text: $name)
                        .font(RideFont.semiBold(16))
                        .foregroundStyle(RideBrand.text)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .padding(14)
                        .background(RideBrand.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RideBrand.outline, lineWidth: 1.5))
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("start.editor.photo")
                    HStack(spacing: 14) {
                        thumbnail
                        VStack(spacing: 8) {
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                optionLabel("photo.on.rectangle", "start.editor.pick", color: RideBrand.text)
                            }
                            if garage.photo != nil {
                                Button(role: .destructive) {
                                    garage.removePhoto()
                                } label: {
                                    optionLabel("trash", "start.editor.remove", color: Color(hex: 0xFF8D82))
                                }
                            }
                        }
                    }
                    if photoFailed {
                        Text("start.editor.error")
                            .font(RideFont.regular(12))
                            .foregroundStyle(Color(hex: 0xFF8D82))
                    }
                }

                Button {
                    garage.bikeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    dismiss()
                } label: {
                    Text("start.editor.save")
                        .font(RideFont.extraBold(16))
                        .foregroundStyle(Color(hex: 0x18211A))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(RideBrand.gold, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onAppear { name = garage.bikeName }
        .onChange(of: name) { newValue in
            if newValue.count > GarageStore.maximumNameLength {
                name = String(newValue.prefix(GarageStore.maximumNameLength))
            }
        }
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                if let data, garage.setPhoto(from: data) {
                    photoFailed = false
                } else {
                    photoFailed = true
                }
                pickerItem = nil
            }
        }
    }

    private var thumbnail: some View {
        Color.clear
            .frame(width: 92, height: 68)
            .overlay {
                if let photo = garage.photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .accessibilityHidden(true)
                } else {
                    RideBrand.background
                    Image(systemName: "camera")
                        .foregroundStyle(RideBrand.gold)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RideBrand.outline, lineWidth: 1.5))
    }

    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(RideFont.extraBold(11))
            .tracking(1.8)
            .foregroundStyle(RideBrand.secondary)
    }

    private func optionLabel(_ symbol: String, _ key: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color == RideBrand.text ? RideBrand.gold : color)
            Text(key)
                .font(RideFont.semiBold(13))
                .foregroundStyle(color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(hex: 0x2D3B31), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(RideBrand.outline, lineWidth: 1.5))
    }
}
