import AppIntents
import Foundation
import MapKit

// Siri and Shortcuts: "Oye Siri, desbloquea la moto con RideScreen", "abre el asiento…",
// "llévame a Casa con RideScreen". Keyless commands need the phone unlocked (Face ID) first.

enum BikeKeylessAction: String, AppEnum {
    case unlock, seat, fuel

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Orden de la llave"
    static var caseDisplayRepresentations: [BikeKeylessAction: DisplayRepresentation] = [
        .unlock: "Desbloquear", .seat: "Abrir el asiento", .fuel: "Abrir el depósito",
    ]
    var pke: PKEAction {
        switch self { case .unlock: .unlock; case .seat: .seat; case .fuel: .fuel }
    }
}

/// Runs one keyless command. Locking is left out on purpose: it needs a known speed of zero.
struct BikeKeylessIntent: AppIntent {
    static var title: LocalizedStringResource = "Llave de la moto"
    static var description = IntentDescription("Desbloquea la moto o abre el asiento o el depósito con la llave sin contacto.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static var openAppWhenRun = false

    @Parameter(title: "Orden", default: .unlock)
    var action: BikeKeylessAction

    init() {}
    init(action: BikeKeylessAction) { self.action = action }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let pke = PKEControlService.shared
        await pke.execute(action.pke, speedKmh: nil)
        if pke.lastResultOK {
            let done: String
            switch action {
            case .unlock: done = "Moto desbloqueada."
            case .seat: done = "Asiento abierto."
            case .fuel: done = "Depósito abierto."
            }
            return .result(dialog: "\(done)")
        }
        return .result(dialog: "\(pke.status)")
    }
}

struct DashPlaceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Destino guardado"
    static var defaultQuery = DashPlaceQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name)) }
}

struct DashPlaceQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [DashPlaceEntity] {
        DashPlaces.all.filter { identifiers.contains($0.id) }.map { DashPlaceEntity(id: $0.id, name: $0.name) }
    }
    func entities(matching string: String) async throws -> [DashPlaceEntity] {
        let q = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return DashPlaces.all.filter { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q) }
            .map { DashPlaceEntity(id: $0.id, name: $0.name) }
    }
    func suggestedEntities() async throws -> [DashPlaceEntity] {
        let list = DashPlaces.favourites.isEmpty ? DashPlaces.all : DashPlaces.favourites
        return list.map { DashPlaceEntity(id: $0.id, name: $0.name) }
    }
}

/// Sets a saved destination on the dash navigator; the route is asked for as soon as there is a fix.
struct NavigateToPlaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Navegar a un destino guardado"
    static var description = IntentDescription("Pone un destino guardado en la navegación del cuadro.")
    static var openAppWhenRun = true

    @Parameter(title: "Destino")
    var place: DashPlaceEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let saved = DashPlaces.all.first(where: { $0.id == place.id }) else {
            return .result(dialog: "No encuentro ese destino guardado.")
        }
        DashImageTest.shared.navigator.setDestination(saved.mapItem)
        return .result(dialog: "Ruta a \(saved.name). Abre la proyección para verla en el cuadro.")
    }
}

struct RideScreenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BikeKeylessIntent(action: .unlock), phrases: [
            "Desbloquea la moto con \(.applicationName)",
            "Desbloquea mi moto con \(.applicationName)",
            "Desbloquear la moto con \(.applicationName)",
            "Desbloquear mi moto con \(.applicationName)",
            "Abre la moto con \(.applicationName)",
            "Abre mi moto con \(.applicationName)",
            "Desbloquea con \(.applicationName)",
        ])
        AppShortcut(intent: BikeKeylessIntent(action: .seat), phrases: [
            "Abre el asiento con \(.applicationName)",
            "Abre el asiento de la moto con \(.applicationName)",
            "Abre el asiento de mi moto con \(.applicationName)",
            "Abrir el asiento con \(.applicationName)",
        ])
        AppShortcut(intent: BikeKeylessIntent(action: .fuel), phrases: [
            "Abre el depósito con \(.applicationName)",
            "Abre el depósito de la moto con \(.applicationName)",
            "Abre el depósito de mi moto con \(.applicationName)",
            "Abrir el depósito con \(.applicationName)",
        ])
        AppShortcut(intent: NavigateToPlaceIntent(), phrases: [
            "Llévame a \(\.$place) con \(.applicationName)",
            "Navega a \(\.$place) con \(.applicationName)",
        ])
    }
}
