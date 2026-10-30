import SwiftUI

private enum RideBrand {
    static let background = Color(hex: 0x1A231D)
    static let surface = Color(hex: 0x243028)
    static let outline = Color(hex: 0x3D4F42)
    static let gold = Color(hex: 0xD1A955)
    static let text = Color(hex: 0xF1F4EC)
    static let secondary = Color(hex: 0xAEBAAA)
}
private enum RideFont {
    static func regular(_ size: CGFloat) -> Font { .custom("Archivo-Regular", size: size) }
    static func bold(_ size: CGFloat) -> Font { .custom("Archivo-ExtraBold", size: size) }
    static func black(_ size: CGFloat) -> Font { .custom("ArchivoBlack-Regular", size: size) }
}

@main
struct RideScreenIOSApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RadialGradient(
                    colors: [Color(hex: 0x2A3A30), RideBrand.background],
                    center: UnitPoint(x: 0.2, y: 0),
                    startRadius: 0,
                    endRadius: max(geometry.size.width * 1.2, geometry.size.height * 0.6)
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    header
                    hero.padding(.top, 26)
                    featureSection.padding(.top, 28)
                    Spacer(minLength: 0)
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 58)
                .padding(.bottom, 34)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("RideScreenMark")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text("Ride").foregroundStyle(RideBrand.text)
                    Text("Screen").foregroundStyle(RideBrand.gold)
                }
                .font(RideFont.black(24))
                .tracking(0.2)
                .lineLimit(1)

                Text("iOS EDITION")
                    .font(RideFont.bold(10.5))
                    .tracking(2.2)
                    .foregroundStyle(RideBrand.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Circle().fill(RideBrand.gold).frame(width: 6, height: 6)
                Text("PREVIEW")
                    .font(RideFont.bold(10.5))
                    .tracking(1.6)
                    .foregroundStyle(RideBrand.gold)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .overlay { Capsule().stroke(RideBrand.outline, lineWidth: 1.5) }
        }
        .frame(height: 40)
    }

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: 0x30423A), location: 0),
                            .init(color: Color(hex: 0x1C261F), location: 0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RideRouteArtwork()
                .frame(width: 190, height: 230)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 6, y: 4)

            VStack(alignment: .leading, spacing: 0) {
                Text("EL SIGUIENTE CAPÍTULO")
                    .font(RideFont.bold(11))
                    .tracking(2.4)
                    .foregroundStyle(RideBrand.gold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("Tus rutas.\nTus historias.")
                    .font(RideFont.black(39))
                    .lineSpacing(-4)
                    .foregroundStyle(RideBrand.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 56)

                Text("RideScreen llega a iPhone.")
                    .font(RideFont.regular(16))
                    .foregroundStyle(RideBrand.secondary)
                    .padding(.top, 14)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 22)

            HStack(spacing: 7) {
                Text("🛠️").font(.system(size: 12))
                Text("EN DESARROLLO")
                    .font(RideFont.bold(11))
                    .tracking(1.8)
                    .foregroundStyle(Color(hex: 0x18211A))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(RideBrand.gold, in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 22)
            .padding(.bottom, 22)
        }
        .frame(height: 318)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(RideBrand.outline, lineWidth: 1.5)
        }
    }

    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DISEÑADO PARA CADA KILÓMETRO")
                .font(RideFont.bold(11))
                .tracking(2.4)
                .foregroundStyle(RideBrand.gold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text("Lo que estamos preparando")
                .font(RideFont.black(24))
                .foregroundStyle(RideBrand.text)
                .padding(.top, 8)

            HStack(alignment: .top, spacing: 9) {
                featureCard(kind: .route, title: "RUTAS", detail: "Graba cada salida en segundo plano")
                featureCard(kind: .data, title: "DATOS", detail: "Velocidad, distancia y recorrido")
                featureCard(kind: .video, title: "VÍDEO", detail: "Telemetría sobre tus clips")
            }
            .padding(.top, 14)
        }
    }

    private func featureCard(kind: FeatureLineIcon.Kind, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FeatureLineIcon(kind: kind)
            Text(title)
                .font(RideFont.bold(13))
                .tracking(1.2)
                .foregroundStyle(RideBrand.text)
                .padding(.top, 10)
            Text(detail)
                .font(RideFont.regular(11.5))
                .lineSpacing(1.2)
                .foregroundStyle(RideBrand.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .padding(.horizontal, 11)
        .padding(.top, 14)
        .padding(.bottom, 13)
        .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(RideBrand.outline, lineWidth: 1.5)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(RideBrand.secondary)
            Text("Proyecto en desarrollo. Las funciones pueden cambiar.")
                .font(RideFont.regular(11.5))
                .foregroundStyle(RideBrand.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RideRouteArtwork: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                routePath(in: geometry.size)
                    .stroke(Color(hex: 0x0F1511), style: StrokeStyle(lineWidth: 34, lineCap: .round, lineJoin: .round))
                routePath(in: geometry.size)
                    .stroke(RideBrand.gold, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [7, 9]))
            }
        }
        .accessibilityHidden(true)
    }

    private func routePath(in size: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: size.width + 10, y: -10))
        path.addCurve(
            to: CGPoint(x: size.width * 0.55, y: size.height * 0.68),
            control1: CGPoint(x: size.width * 0.75, y: size.height * 0.27),
            control2: CGPoint(x: size.width * 0.8, y: size.height * 0.48)
        )
        path.addCurve(
            to: CGPoint(x: size.width * 0.1, y: size.height + 10),
            control1: CGPoint(x: size.width * 0.3, y: size.height * 0.83),
            control2: CGPoint(x: size.width * 0.2, y: size.height * 0.91)
        )
        return path
    }
}

private struct FeatureLineIcon: View {
    enum Kind { case route, data, video }
    let kind: Kind

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            switch kind {
            case .route:
                path.move(to: CGPoint(x: 6, y: 19))
                path.addCurve(to: CGPoint(x: 18, y: 19), control1: CGPoint(x: 9, y: 19), control2: CGPoint(x: 9, y: 14))
                path.addCurve(to: CGPoint(x: 18, y: 7), control1: CGPoint(x: 18, y: 11), control2: CGPoint(x: 12, y: 10))
                path.addEllipse(in: CGRect(x: 4, y: 17, width: 4, height: 4))
                path.addEllipse(in: CGRect(x: 16, y: 3, width: 4, height: 4))
            case .data:
                path.move(to: CGPoint(x: 4, y: 16))
                path.addCurve(to: CGPoint(x: 20, y: 16), control1: CGPoint(x: 4, y: 5), control2: CGPoint(x: 20, y: 5))
                path.move(to: CGPoint(x: 12, y: 16))
                path.addLine(to: CGPoint(x: 16, y: 10))
                path.addEllipse(in: CGRect(x: 10.6, y: 14.6, width: 2.8, height: 2.8))
            case .video:
                path.addRoundedRect(in: CGRect(x: 3, y: 6, width: 13, height: 12), cornerSize: CGSize(width: 2.5, height: 2.5))
                path.move(to: CGPoint(x: 16, y: 10.5))
                path.addLine(to: CGPoint(x: 21, y: 7.5))
                path.addLine(to: CGPoint(x: 21, y: 16.5))
                path.closeSubpath()
            }
            context.stroke(path, with: .color(RideBrand.gold), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 24, height: 24)
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
