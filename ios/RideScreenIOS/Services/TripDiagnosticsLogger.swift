import Foundation

actor TripDiagnosticsLogger {
    static let maximumLines = 500

    private let fileURL: URL
    private let fileManager: FileManager
    private var lines: [String] = []
    private var loaded = false

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = support
                .appendingPathComponent("RideScreen", isDirectory: true)
                .appendingPathComponent("diagnostics.log")
        }
    }

    func append(_ message: String) throws {
        try loadIfNeeded()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        lines.append("[\(timestamp)] \(message)")
        if lines.count > Self.maximumLines {
            lines.removeFirst(lines.count - Self.maximumLines)
        }
        try persist()
    }

    func recentLines() throws -> [String] {
        try loadIfNeeded()
        return lines
    }

    func text() throws -> String {
        try recentLines().joined(separator: "\n")
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        let text = String(decoding: data, as: UTF8.self)
        lines = Array(text.split(whereSeparator: \.isNewline).map(String.init).suffix(Self.maximumLines))
    }

    private func persist() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
        try data.write(to: fileURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.synchronize()
        try handle.close()
    }
}
