import SwiftUI

private enum RideBrand {
    static let background = Color(hex: 0x1A231D)
    static let surface = Color(hex: 0x243028)
    static let surfaceHigh = Color(hex: 0x2D3B31)
    static let outline = Color(hex: 0x3D4F42)
    static let gold = Color(hex: 0xD1A955)
    static let text = Color(hex: 0xF1F4EC)
    static let secondary = Color(hex: 0xAEBAAA)
}

@main
struct RideScreenIOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        ZStack {
            RideBrand.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    hero
                    featuresHeading
                    featureCards
                    comingSoonCard
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 30)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image("RideScreenMark")
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(RideBrand.outline, lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text("RIDE")
                        .foregroundStyle(RideBrand.text)
                    Text("SCREEN")
                        .foregroundStyle(RideBrand.gold)
                }
                .font(.custom("AvenirNextCondensed-Heavy", size: 25))
                .tracking(-0.45)

                Text("iOS EDITION")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(2.1)
                    .foregroundStyle(RideBrand.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Circle()
                    .fill(RideBrand.gold)
                    .frame(width: 6, height: 6)
                Text("PREVIEW")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(RideBrand.gold)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RideBrand.surfaceHigh, in: Capsule())
            .overlay(Capsule().stroke(RideBrand.outline, lineWidth: 1))
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: 0x34463A),
                            RideBrand.surface,
                            Color(hex: 0x172019)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RideRouteArtwork()
                .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))

            LinearGradient(
                colors: [RideBrand.background.opacity(0.04), RideBrand.background.opacity(0.18), RideBrand.background.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text("EL SIGUIENTE CAPÍTULO")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(2.0)
                    .foregroundStyle(RideBrand.gold)

                Spacer(minLength: 8)

                Text("Tus rutas.\nTus historias.")
                    .font(.custom("AvenirNextCondensed-Heavy", size: 39))
                    .lineSpacing(-4)
                    .foregroundStyle(RideBrand.text)
                    .fixedSize(horizontal: false, vertical: true)

                Text("RideScreen llega a iPhone.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(RideBrand.secondary)

                HStack(spacing: 7) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("EN DESARROLLO")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .tracking(1.35)
                }
                .foregroundStyle(RideBrand.background)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RideBrand.gold, in: Capsule())
                .padding(.top, 3)
            }
            .padding(20)
        }
        .frame(height: 238)
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(RideBrand.outline.opacity(0.9), lineWidth: 1)
        }
    }

    private var featuresHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DISEÑADO PARA CADA KILÓMETRO")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(RideBrand.gold)

            Text("Lo que estamos preparando")
                .font(.custom("AvenirNextCondensed-Heavy", size: 25))
                .foregroundStyle(RideBrand.text)
        }
        .padding(.top, 1)
    }

    private var featureCards: some View {
        HStack(alignment: .top, spacing: 9) {
            featureCard(
                icon: "point.topleft.down.curvedto.point.bottomright.up",
                title: "RUTAS",
                detail: "Graba cada salida"
            )
            featureCard(
                icon: "speedometer",
                title: "DATOS",
                detail: "Velocidad y recorrido"
            )
            featureCard(
                icon: "video.fill",
                title: "VÍDEO",
                detail: "Telemetría sobre tus clips"
            )
        }
    }

    private func featureCard(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(RideBrand.gold)
                .frame(width: 35, height: 35)
                .background(RideBrand.gold.opacity(0.13), in: Circle())

            Text(title)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(RideBrand.text)

            Text(detail)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(RideBrand.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .frame(minHeight: 112, alignment: .topLeading)
        .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(RideBrand.outline, lineWidth: 1)
        }
    }

    private var comingSoonCard: some View {
        HStack(spacing: 13) {
            Image("RideScreenMark")
                .resizable()
                .scaledToFit()
                .frame(width: 53, height: 53)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("RIDESCREEN iOS")
                    .font(.custom("AvenirNextCondensed-Heavy", size: 22))
                    .tracking(0.2)
                    .foregroundStyle(RideBrand.text)

                Text("Mismo espíritu. Nuevos horizontes.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(RideBrand.secondary)

                Text("PRÓXIMAMENTE")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(1.7)
                    .foregroundStyle(RideBrand.gold)
                    .padding(.top, 3)
            }

            Spacer(minLength: 0)
        }
        .padding(15)
        .background(
            LinearGradient(
                colors: [RideBrand.surfaceHigh, RideBrand.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 19, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(RideBrand.outline, lineWidth: 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RideBrand.gold)

            Text("Proyecto en desarrollo. Las funciones pueden cambiar.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(RideBrand.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 1)
    }
}

private struct RideRouteArtwork: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height * 0.69))
                    path.addCurve(
                        to: CGPoint(x: size.width, y: size.height * 0.54),
                        control1: CGPoint(x: size.width * 0.28, y: size.height * 0.43),
                        control2: CGPoint(x: size.width * 0.61, y: size.height * 0.82)
                    )
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.addLine(to: CGPoint(x: 0, y: size.height))
                    path.closeSubpath()
                }
                .fill(Color(hex: 0x202D24).opacity(0.95))

                Path { path in
                    path.move(to: CGPoint(x: size.width * 0.60, y: size.height * 1.08))
                    path.addCurve(
                        to: CGPoint(x: size.width * 1.10, y: size.height * 0.32),
                        control1: CGPoint(x: size.width * 0.48, y: size.height * 0.76),
                        control2: CGPoint(x: size.width * 0.91, y: size.height * 0.77)
                    )
                }
                .stroke(Color.black.opacity(0.42), style: StrokeStyle(lineWidth: 31, lineCap: .round))

                Path { path in
                    path.move(to: CGPoint(x: size.width * 0.60, y: size.height * 1.08))
                    path.addCurve(
                        to: CGPoint(x: size.width * 1.10, y: size.height * 0.32),
                        control1: CGPoint(x: size.width * 0.48, y: size.height * 0.76),
                        control2: CGPoint(x: size.width * 0.91, y: size.height * 0.77)
                    )
                }
                .stroke(RideBrand.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [5, 7]))

                Path { path in
                    path.move(to: CGPoint(x: size.width * 0.60, y: size.height * 1.08))
                    path.addCurve(
                        to: CGPoint(x: size.width * 1.10, y: size.height * 0.32),
                        control1: CGPoint(x: size.width * 0.48, y: size.height * 0.76),
                        control2: CGPoint(x: size.width * 0.91, y: size.height * 0.77)
                    )
                }
                .stroke(RideBrand.gold.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 9]))

                Circle()
                    .fill(RideBrand.gold)
                    .frame(width: 7, height: 7)
                    .position(x: size.width * 0.81, y: size.height * 0.57)

                Circle()
                    .stroke(RideBrand.gold.opacity(0.7), lineWidth: 1)
                    .frame(width: 17, height: 17)
                    .position(x: size.width * 0.81, y: size.height * 0.57)
            }
        }
        .accessibilityHidden(true)
    }
}

private extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

#Preview {
    ContentView()
}
