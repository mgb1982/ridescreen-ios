import Foundation

enum TripGPXExporter {
    private static let namespace = "https://ridescreen.app/gpx/extensions/1"

    static func xml(for trip: RecordedTrip) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let shortDate = ISO8601DateFormatter()
        shortDate.timeZone = TimeZone(secondsFromGMT: 0)
        shortDate.formatOptions = [.withInternetDateTime]

        let name = "RideScreen \(shortDate.string(from: trip.startedAt))"
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="RideScreen iOS" xmlns="http://www.topografix.com/GPX/1/1" xmlns:rs="\(namespace)">
          <metadata>
            <name>\(escape(name))</name>
            <time>\(formatter.string(from: trip.startedAt))</time>
          </metadata>
          <trk>
            <name>\(escape(name))</name>
            <trkseg>

        """

        for point in trip.points {
            xml += """
                  <trkpt lat="\(number(point.latitude))" lon="\(number(point.longitude))">
                    <ele>\(number(point.altitudeMeters))</ele>
                    <time>\(formatter.string(from: point.timestamp))</time>
                    <extensions>
                      <rs:speed unit="m/s">\(number(point.speedMetersPerSecond))</rs:speed>
                    </extensions>
                  </trkpt>

            """
        }

        xml += """
            </trkseg>
          </trk>
        </gpx>
        """
        return xml
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
