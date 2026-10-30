import SwiftUI

private enum Brand {
    static let bg = Color(hex: 0x1A231D)
    static let surface = Color(hex: 0x243028)
    static let outline = Color(hex: 0x3D4F42)
    static let gold = Color(hex: 0xD1A955)
    static let text = Color(hex: 0xF1F4EC)
    static let muted = Color(hex: 0xAEBAAA)
}
private enum Archivo {
    static func regular(_ n: CGFloat) -> Font { .custom("Archivo-Regular", size: n) }
    static func medium(_ n: CGFloat) -> Font { .custom("Archivo-Medium", size: n) }
    static func bold(_ n: CGFloat) -> Font { .custom("Archivo-ExtraBold", size: n) }
    static func black(_ n: CGFloat) -> Font { .custom("Archivo-Black", size: n) }
}
@main struct RideScreenIOSApp: App {
    var body: some Scene { WindowGroup { ContentView().preferredColorScheme(.dark) } }
}
struct ContentView: View {
    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0x2A3A30), Brand.bg], center: UnitPoint(x: 0.2, y: 0), startRadius: 5, endRadius: 460).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    hero.padding(.top, 26)
                    features.padding(.top, 28)
                    footer.padding(.top, 22).padding(.bottom, 20)
                }.padding(.horizontal, 20).padding(.top, 4).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
        }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image("RideScreenMark").resizable().scaledToFit().frame(width: 40, height: 40).clipShape(Circle()).overlay(Circle().stroke(Brand.outline, lineWidth: 1)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) { Text("Ride").foregroundStyle(Brand.text); Text("Screen").foregroundStyle(Brand.gold) }.font(Archivo.black(24)).tracking(0.2).lineLimit(1).minimumScaleFactor(0.8)
                Text("iOS EDITION").font(Archivo.bold(10.5)).tracking(2.2).foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) { Circle().fill(Brand.gold).frame(width: 6, height: 6); Text("PREVIEW").font(Archivo.bold(10.5)).tracking(1.4).foregroundStyle(Brand.gold) }
                .padding(.horizontal, 11).padding(.vertical, 7).background(Brand.bg.opacity(0.25), in: Capsule()).overlay(Capsule().stroke(Brand.outline, lineWidth: 1.5)).fixedSize()
        }
    }
    private var hero: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 26).fill(LinearGradient(colors: [Color(hex: 0x30423A), Brand.surface, Color(hex: 0x1C261F)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RouteArt().clipShape(RoundedRectangle(cornerRadius: 26))
            LinearGradient(colors: [Brand.bg.opacity(0.02), Brand.bg.opacity(0.08), Brand.bg.opacity(0.72)], startPoint: .top, endPoint: .bottom).clipShape(RoundedRectangle(cornerRadius: 26))
            VStack(alignment: .leading, spacing: 0) {
                eyebrow("EL SIGUIENTE CAPÍTULO")
                Spacer(minLength: 18)
                Text("Tus rutas.\nTus historias.").font(Archivo.black(39)).lineSpacing(-3).tracking(0.1).foregroundStyle(Brand.text).fixedSize(horizontal: false, vertical: true)
                Text("RideScreen llega a iPhone.").font(Archivo.medium(16)).foregroundStyle(Brand.muted).padding(.top, 14)
                Spacer(minLength: 16)
                HStack(spacing: 7) { Image(systemName: "wrench.and.screwdriver.fill").font(.system(size: 10, weight: .bold)); Text("EN DESARROLLO").font(Archivo.bold(11)).tracking(1.8) }
                    .foregroundStyle(Brand.bg).padding(.horizontal, 15).padding(.vertical, 9).background(Brand.gold, in: Capsule())
            }.padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 22)
        }.frame(height: 318).overlay(RoundedRectangle(cornerRadius: 26).stroke(Brand.outline, lineWidth: 1.5))
    }
    private var features: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("DISEÑADO PARA CADA KILÓMETRO")
            Text("Lo que estamos preparando").font(Archivo.black(24)).foregroundStyle(Brand.text).padding(.top, 8)
            HStack(alignment: .top, spacing: 9) {
                card(icon: "route", title: "RUTAS", detail: "Graba cada salida en segundo plano")
                card(icon: "speedometer", title: "DATOS", detail: "Velocidad, distancia y recorrido")
                card(icon: "video", title: "VÍDEO", detail: "Telemetría sobre tus clips")
            }.padding(.top, 14)
        }
    }
    private func eyebrow(_ value: String) -> some View {
        Text(value).font(Archivo.bold(11)).tracking(2.4).foregroundStyle(Brand.gold).lineLimit(1).minimumScaleFactor(0.8)
    }
    private func card(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).font(.system(size: 24, weight: .regular)).foregroundStyle(Brand.gold).frame(width: 28, height: 30, alignment: .leading).accessibilityHidden(true)
            Text(title).font(Archivo.bold(13)).tracking(1.2).foregroundStyle(Brand.text).padding(.top, 3)
            Text(detail).font(Archivo.regular(11.5)).lineSpacing(1).foregroundStyle(Brand.muted).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading).padding(.horizontal, 11).padding(.vertical, 14)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.outline, lineWidth: 1.5))
    }
    private var footer: some View {
        HStack(spacing: 8) { Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Brand.gold); Text("Proyecto en desarrollo. Las funciones pueden cambiar.").font(Archivo.regular(11.5)).foregroundStyle(Brand.muted).lineLimit(2).minimumScaleFactor(0.85) }.frame(maxWidth: .infinity)
    }
}
private struct RouteArt: View {
    var body: some View {
        GeometryReader { g in
            let s = g.size
            ZStack {
                Path { p in p.move(to: CGPoint(x: s.width * 1.05, y: -12)); p.addCurve(to: CGPoint(x: s.width * 0.10, y: s.height * 1.08), control1: CGPoint(x: s.width * 0.58, y: s.height * 0.34), control2: CGPoint(x: s.width * 0.84, y: s.height * 0.66)) }
                    .stroke(Color.black.opacity(0.32), style: StrokeStyle(lineWidth: 35, lineCap: .round))
                Path { p in p.move(to: CGPoint(x: s.width * 1.05, y: -12)); p.addCurve(to: CGPoint(x: s.width * 0.10, y: s.height * 1.08), control1: CGPoint(x: s.width * 0.58, y: s.height * 0.34), control2: CGPoint(x: s.width * 0.84, y: s.height * 0.66)) }
                    .stroke(Brand.gold.opacity(0.9), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [7, 9]))
                Circle().fill(Brand.gold).frame(width: 7, height: 7).position(x: s.width * 0.77, y: s.height * 0.57)
            }
        }.accessibilityHidden(true)
    }
}
private extension Color {
    init(hex: UInt) { self.init(.sRGB, red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, opacity: 1) }
}
#Preview { ContentView() }
