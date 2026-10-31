import MapKit
import SwiftUI

/// Route of one saved trip: the recorded points drawn on a map, with the same summary the list shows.
struct TripDetailScreen: View {
    let trip: RecordedTrip

    private var distanceMeters: Double {
        TripGeometry.resolvedDistance(stored: trip.distanceMeters, points: trip.points)
    }

    var body: some View {
        ZStack {
            RideBackground()
            VStack(spacing: 14) {
                if trip.points.count > 1 {
                    TripRouteMap(points: trip.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                        .frame(maxWidth: .infinity)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Text("trip.detail.noRoute")
                        .font(RideFont.regular(13))
                        .foregroundStyle(RideBrand.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                VStack(spacing: 10) {
                    statRow("trip.detail.distance", String(format: "%.2f km", distanceMeters / 1_000))
                    statRow("trip.detail.time", durationText(trip.elapsedDuration))
                    statRow("trip.detail.maxSpeed", String(format: "%.0f km/h", trip.maximumSpeedMetersPerSecond * 3.6))
                    statRow("trip.detail.points", "\(trip.points.count)")
                }
                .padding(15)
                .background(RideBrand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(RideBrand.outline, lineWidth: 1))

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .navigationTitle(trip.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statRow(_ key: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(RideFont.regular(13))
                .foregroundStyle(RideBrand.secondary)
            Spacer()
            Text(value)
                .font(RideFont.semiBold(15))
                .foregroundStyle(RideBrand.text)
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// MKMapView (available on iOS 16) with the route as a polyline, fitted to the whole trip.
private struct TripRouteMap: UIViewRepresentable {
    let points: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isUserInteractionEnabled = true
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        let line = MKPolyline(coordinates: points, count: points.count)
        map.addOverlay(line)
        map.delegate = context.coordinator
        let inset = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        map.setVisibleMapRect(line.boundingMapRect, edgePadding: inset, animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer = MKPolylineRenderer(overlay: overlay)
            renderer.strokeColor = UIColor(red: 0.84, green: 0.66, blue: 0.27, alpha: 1)
            renderer.lineWidth = 4
            return renderer
        }
    }
}
