import Foundation

actor TripJournalStore {
    private struct JournalLine: Codable {
        let type: String
        let id: String
        var startedAt: Date?
        var endedAt: Date?
        var point: TripPoint?
        var distanceMeters: Double?
        var movingTimeMilliseconds: Int64?
        var maximumSpeedMetersPerSecond: Double?
    }

    private let directoryURL: URL
    private let fileManager: FileManager
    private var activeHandle: FileHandle?
    private var activeID: String?
    private var activeJournalURL: URL?
    private var lastSync = Date.distantPast
    private let syncInterval: TimeInterval = 3

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directoryURL = support.appendingPathComponent("RideScreen/Trips", isDirectory: true)
        }
    }

    func begin(id: String, startedAt: Date) throws {
        guard activeHandle == nil else { throw StoreError.recordingAlreadyOpen }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = journalURL(for: id)
        guard !fileManager.fileExists(atPath: url.path) else { throw StoreError.journalAlreadyExists }
        guard fileManager.createFile(atPath: url.path, contents: nil) else { throw StoreError.cannotCreateFile }

        let handle = try FileHandle(forWritingTo: url)
        activeHandle = handle
        activeID = id
        activeJournalURL = url
        lastSync = Date.distantPast
        try write(JournalLine(type: "start", id: id, startedAt: startedAt))
        try synchronize()
    }

    func append(
        point: TripPoint,
        distanceMeters: Double,
        movingTimeMilliseconds: Int64,
        maximumSpeedMetersPerSecond: Double
    ) throws {
        guard let id = activeID else { throw StoreError.noActiveRecording }
        try write(
            JournalLine(
                type: "point",
                id: id,
                point: point,
                distanceMeters: distanceMeters,
                movingTimeMilliseconds: movingTimeMilliseconds,
                maximumSpeedMetersPerSecond: maximumSpeedMetersPerSecond
            )
        )
        if Date().timeIntervalSince(lastSync) >= syncInterval {
            try synchronize()
        }
    }

    func flush() throws {
        try synchronize()
    }

    func finish(_ trip: RecordedTrip) throws {
        guard activeID == trip.id, activeHandle != nil else { throw StoreError.noActiveRecording }
        let complete = trip.endedAt == nil
            ? withEndDate(trip, date: Date())
            : trip

        try write(
            JournalLine(
                type: "end",
                id: complete.id,
                endedAt: complete.endedAt,
                distanceMeters: complete.distanceMeters,
                movingTimeMilliseconds: complete.movingTimeMilliseconds,
                maximumSpeedMetersPerSecond: complete.maximumSpeedMetersPerSecond
            )
        )
        try synchronize()
        try activeHandle?.close()
        activeHandle = nil
        activeID = nil
        activeJournalURL = nil

        try writeAndroidCompatibleTrip(complete)
        try fileManager.removeItem(at: journalURL(for: complete.id))
    }

    func completedTrips() throws -> [RecordedTrip] {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        return urls.compactMap { try? readAndroidCompatibleTrip(at: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func pendingTrips() throws -> [RecordedTrip] {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" && $0 != activeJournalURL }

        var pending: [RecordedTrip] = []
        for url in urls {
            let parsed = try readJournal(at: url)
            if parsed.isComplete {
                // Recover a process stopped between writing the end record and final JSON conversion.
                try writeAndroidCompatibleTrip(parsed.trip)
                try fileManager.removeItem(at: url)
            } else {
                pending.append(parsed.trip)
            }
        }
        return pending.sorted { $0.startedAt > $1.startedAt }
    }

    func resume(id: String) throws -> RecordedTrip {
        guard activeHandle == nil else { throw StoreError.recordingAlreadyOpen }
        let url = journalURL(for: id)
        let bytes = try Data(contentsOf: url)
        if !bytes.isEmpty, bytes.last != 0x0A {
            let lastNewline = bytes.lastIndex(of: 0x0A).map { bytes.distance(from: bytes.startIndex, to: $0) + 1 } ?? 0
            let truncateHandle = try FileHandle(forWritingTo: url)
            try truncateHandle.truncate(atOffset: UInt64(lastNewline))
            try truncateHandle.close()
        }

        let parsed = try readJournal(at: url)
        guard !parsed.isComplete else { throw StoreError.journalAlreadyCompleted }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        activeHandle = handle
        activeID = id
        activeJournalURL = url
        lastSync = Date.distantPast
        try synchronize()
        return parsed.trip
    }

    func discardPending(id: String) throws {
        if activeID == id {
            try activeHandle?.close()
            activeHandle = nil
            activeID = nil
            activeJournalURL = nil
        }
        let url = journalURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func deleteTrip(id: String) throws {
        let url = tripURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func exportURL(for trip: RecordedTrip) throws -> URL {
        let exports = directoryURL.appendingPathComponent("Exports", isDirectory: true)
        try fileManager.createDirectory(at: exports, withIntermediateDirectories: true)
        let url = exports.appendingPathComponent("ridescreen_\(trip.id).gpx")
        let data = Data(TripGPXExporter.xml(for: trip).utf8)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func write(_ line: JournalLine) throws {
        guard let handle = activeHandle else { throw StoreError.noActiveRecording }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var data = try encoder.encode(line)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func synchronize() throws {
        try activeHandle?.synchronize()
        lastSync = Date()
    }

    private func readJournal(at url: URL) throws -> (trip: RecordedTrip, isComplete: Bool) {
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        var id: String?
        var startedAt: Date?
        var endedAt: Date?
        var points: [TripPoint] = []
        var distance = 0.0
        var movingMilliseconds: Int64 = 0
        var maxSpeed = 0.0
        var completed = false

        for rawLine in lines {
            guard let entry = try? decoder.decode(JournalLine.self, from: Data(rawLine)) else {
                continue // An incomplete final write is ignored and truncated if the user resumes.
            }
            id = entry.id
            switch entry.type {
            case "start":
                startedAt = entry.startedAt
            case "point":
                if let point = entry.point { points.append(point) }
                distance = entry.distanceMeters ?? distance
                movingMilliseconds = entry.movingTimeMilliseconds ?? movingMilliseconds
                maxSpeed = entry.maximumSpeedMetersPerSecond ?? maxSpeed
            case "end":
                endedAt = entry.endedAt
                distance = entry.distanceMeters ?? distance
                movingMilliseconds = entry.movingTimeMilliseconds ?? movingMilliseconds
                maxSpeed = entry.maximumSpeedMetersPerSecond ?? maxSpeed
                completed = true
            default:
                continue
            }
        }

        guard let tripID = id, let start = startedAt else { throw StoreError.invalidJournal }
        return (
            RecordedTrip(
                id: tripID,
                startedAt: start,
                endedAt: endedAt,
                distanceMeters: TripGeometry.resolvedDistance(stored: distance, points: points),
                movingTimeMilliseconds: movingMilliseconds,
                maximumSpeedMetersPerSecond: maxSpeed,
                points: points
            ),
            completed
        )
    }

    private func writeAndroidCompatibleTrip(_ trip: RecordedTrip) throws {
        let points = trip.points.map { point in
            [
                point.latitude,
                point.longitude,
                Double(Int64((point.timestamp.timeIntervalSince1970 * 1_000).rounded())),
                point.speedMetersPerSecond
            ]
        }
        let object: [String: Any] = [
            "id": trip.id,
            "start": Int64((trip.startedAt.timeIntervalSince1970 * 1_000).rounded()),
            "end": Int64(((trip.endedAt ?? Date()).timeIntervalSince1970 * 1_000).rounded()),
            "distanceMeters": trip.distanceMeters,
            "movingTimeMs": trip.movingTimeMilliseconds,
            "maxSpeedMs": trip.maximumSpeedMetersPerSecond,
            "points": points,
            "altitudesMeters": trip.points.map(\.altitudeMeters),
            "horizontalAccuracyMeters": trip.points.map(\.horizontalAccuracyMeters)
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let url = tripURL(for: trip.id)
        try data.write(to: url, options: .atomic)
        let verifyHandle = try FileHandle(forWritingTo: url)
        try verifyHandle.synchronize()
        try verifyHandle.close()
    }

    private func readAndroidCompatibleTrip(at url: URL) throws -> RecordedTrip {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              let start = object["start"] as? NSNumber,
              let end = object["end"] as? NSNumber,
              let pointsArray = object["points"] as? [[NSNumber]] else {
            throw StoreError.invalidCompletedTrip
        }

        let altitudes = object["altitudesMeters"] as? [NSNumber] ?? []
        let accuracies = object["horizontalAccuracyMeters"] as? [NSNumber] ?? []
        let points = pointsArray.enumerated().map { index, values -> TripPoint in
            TripPoint(
                latitude: values.count > 0 ? values[0].doubleValue : 0,
                longitude: values.count > 1 ? values[1].doubleValue : 0,
                altitudeMeters: altitudes.indices.contains(index) ? altitudes[index].doubleValue : 0,
                timestamp: Date(timeIntervalSince1970: (values.count > 2 ? values[2].doubleValue : 0) / 1_000),
                speedMetersPerSecond: values.count > 3 ? values[3].doubleValue : 0,
                horizontalAccuracyMeters: accuracies.indices.contains(index) ? accuracies[index].doubleValue : -1
            )
        }

        return RecordedTrip(
            id: id,
            startedAt: Date(timeIntervalSince1970: start.doubleValue / 1_000),
            endedAt: Date(timeIntervalSince1970: end.doubleValue / 1_000),
            distanceMeters: TripGeometry.resolvedDistance(
                stored: (object["distanceMeters"] as? NSNumber)?.doubleValue ?? 0,
                points: points
            ),
            movingTimeMilliseconds: (object["movingTimeMs"] as? NSNumber)?.int64Value ?? 0,
            maximumSpeedMetersPerSecond: (object["maxSpeedMs"] as? NSNumber)?.doubleValue ?? 0,
            points: points
        )
    }

    private func journalURL(for id: String) -> URL {
        directoryURL.appendingPathComponent("\(id).jsonl")
    }

    private func tripURL(for id: String) -> URL {
        directoryURL.appendingPathComponent("\(id).json")
    }

    private func withEndDate(_ trip: RecordedTrip, date: Date) -> RecordedTrip {
        var copy = trip
        copy.endedAt = date
        return copy
    }

    enum StoreError: Error {
        case recordingAlreadyOpen
        case journalAlreadyExists
        case cannotCreateFile
        case noActiveRecording
        case journalAlreadyCompleted
        case invalidJournal
        case invalidCompletedTrip
    }
}
