import Darwin
import Foundation
import Network
import UIKit

/// Wi‑Fi credentials read from the dash's projection QR (Carbit link with `ssid=` and `pwd=`).
struct MirrorQR: Equatable {
    let ssid: String
    let password: String
    let modelID: String?

    /// Back to a parseable string, to keep it on the phone between tests.
    var raw: String {
        // Encode everything but letters and digits: "+", "&" and "=" would break [parse].
        func enc(_ v: String) -> String { v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v }
        var parts = ["ssid=\(enc(ssid))", "pwd=\(enc(password))"]
        if let modelID { parts.append("modelid=\(enc(modelID))") }
        return parts.joined(separator: "&")
    }

    static func parse(_ raw: String) -> MirrorQR? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var fields: [String: String] = [:]
        let query = text.contains("?") ? String(text.split(separator: "?", maxSplits: 1)[1]) : text
        for part in query.split(separator: "#", maxSplits: 1)[0].split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let value = pair[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? pair[1]
            fields[pair[0].lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        guard let ssid = fields["ssid"], !ssid.isEmpty else { return nil }
        return MirrorQR(ssid: ssid,
                        password: fields["pwd"] ?? fields["password"] ?? fields["pass"] ?? "",
                        modelID: fields["modelid"])
    }
}

/// Field test for iOS mirroring: can this iPhone reach the dash's EasyConn service and does the dash
/// call back on 10920–10922? It mirrors the Android order (Bonjour `_EasyConn._tcp`, then `:10930`,
/// MDNS_RESPOND 0x70000010 → expect 0x70000011 {"status":true}). It sends no video and answers nothing
/// on the reverse sockets: it only records which connections arrive and the first command IDs.
/// The log holds no Wi‑Fi password, PKE data or screen content.
@MainActor
final class MirrorLinkTester: ObservableObject {
    static let reversePorts: [UInt16] = [10920, 10921, 10922]
    static let probePort: UInt16 = 10930

    @Published private(set) var lines: [String] = []
    @Published private(set) var isRunning = false
    @Published var bikeHost = ""

    private let queue = DispatchQueue(label: "ridescreen.mirror-test")
    private var listeners: [NWListener] = []
    private var inbound: [NWConnection] = []
    private var browser: NWBrowser?
    private var runTask: Task<Void, Never>?
    private var startDate = Date()
    private var inboundPorts: Set<UInt16> = []
    private var accepted = false
    private var bonjourFound: [NWEndpoint] = []

    var logText: String { lines.joined(separator: "\n") }

    func start() {
        guard !isRunning else { return }
        lines = []
        inboundPorts = []
        accepted = false
        startDate = Date()
        isRunning = true
        runTask = Task { await run() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        teardown()
        if isRunning { log("Stopped") }
        isRunning = false
    }

    // MARK: Sequence

    private func run() async {
        let device = UIDevice.current
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log("RideScreen iOS mirror test · build \(version) · \(device.systemName) \(device.systemVersion)")

        guard let wifi = Self.wifiIPv4() else {
            log("!! No Wi‑Fi IPv4 address. Join the bike's Wi‑Fi (ZT…) in Settings first.")
            finish()
            return
        }
        log("Wi‑Fi: \(wifi.address) / \(wifi.netmask)")
        let host = bikeHost.trimmingCharacters(in: .whitespaces).isEmpty ? wifi.gatewayGuess : bikeHost.trimmingCharacters(in: .whitespaces)
        bikeHost = host
        log("Dash address: \(host)")

        startListeners()
        try? await Task.sleep(nanoseconds: 800_000_000)

        log("Bonjour: browsing _EasyConn._tcp for 5 s…")
        let services = await browseEasyConn(seconds: 5)
        if services.isEmpty { log("Bonjour: nothing found") }

        var targets: [(String, NWEndpoint)] = services.map { ("Bonjour \($0)", $0) }
        targets.append(("\(host):\(Self.probePort)", .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Self.probePort)!)))

        let identities = [
            #"{"phoneType":"Android","packageName":"com.cfmoto.cfmotointernational"}"#,
            #"{"phoneType":"iOS","packageName":"com.cfmoto.cfmotointernational"}"#,
        ]
        outer: for identity in identities {
            for (label, endpoint) in targets {
                if Task.isCancelled { return }
                for attempt in 1...2 {
                    log("Probe → \(label) (try \(attempt)) \(identity)")
                    let result = await MirrorProbe.run(endpoint: endpoint, json: identity, queue: queue)
                    log("   \(result.message)")
                    if result.accepted {
                        accepted = true
                        log("*** MDNS_RESPOND accepted: the dash should now connect back to 10920–10922 ***")
                        break outer
                    }
                    if result.refused { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        log("Waiting 45 s for the dash to connect back…")
        for _ in 0..<45 {
            if Task.isCancelled { return }
            if inboundPorts.contains(10922) && inboundPorts.count >= 2 { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        summary()
        finish()
    }

    private func summary() {
        log("—— Summary ——")
        log("Probe accepted: \(accepted ? "YES" : "no")")
        let ports = inboundPorts.sorted().map(String.init).joined(separator: ", ")
        log("Dash connected back on: \(ports.isEmpty ? "none" : ports)")
        if inboundPorts.contains(10922) {
            log("RESULT: the network path works on iPhone. Next step is the PXC handshake and video.")
        } else if accepted {
            log("RESULT: probe accepted but no callback. Possible causes: Local Network permission, or the iPhone is not reachable from the dash.")
        } else {
            log("RESULT: EasyConn did not answer. Check the dash is on the mirroring screen (interface 3) and the Android app is closed.")
        }
    }

    private func finish() {
        teardown()
        isRunning = false
    }

    private func teardown() {
        browser?.cancel(); browser = nil
        listeners.forEach { $0.cancel() }; listeners = []
        inbound.forEach { $0.cancel() }; inbound = []
    }

    // MARK: Reverse listeners (the dash dials the phone)

    private func startListeners() {
        for port in Self.reversePorts {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .wifi
            guard let nwPort = NWEndpoint.Port(rawValue: port), let listener = try? NWListener(using: params, on: nwPort) else {
                log("!! Could not open port \(port)")
                continue
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.log("Listening on :\(port)")
                    case .failed(let error): self?.log("!! Port \(port) failed: \(error)")
                    case .waiting(let error): self?.log("Port \(port) waiting: \(error) (Local Network permission?)")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, port: port) }
            }
            listener.start(queue: queue)
            listeners.append(listener)
        }
    }

    private func accept(_ connection: NWConnection, port: UInt16) {
        inbound.append(connection)
        inboundPorts.insert(port)
        log("<<< Dash connected on :\(port) from \(connection.endpoint)")
        let reader = InboundReader(port: port) { [weak self] text in
            Task { @MainActor in self?.log(text) }
        }
        connection.stateUpdateHandler = { state in
            if case .ready = state { reader.receive(on: connection) }
        }
        connection.start(queue: queue)
    }

    // MARK: Bonjour

    private func browseEasyConn(seconds: Double) async -> [NWEndpoint] {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_EasyConn._tcp", domain: nil), using: params)
        self.browser = browser
        bonjourFound = []
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.map(\.endpoint)
            Task { @MainActor in
                guard let self else { return }
                for endpoint in endpoints where !self.bonjourFound.contains(endpoint) {
                    self.bonjourFound.append(endpoint)
                    self.log("Bonjour: found \(endpoint)")
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { Task { @MainActor in self?.log("Bonjour failed: \(error)") } }
            if case .waiting(let error) = state { Task { @MainActor in self?.log("Bonjour waiting: \(error) (Local Network permission?)") } }
        }
        browser.start(queue: queue)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        browser.cancel()
        self.browser = nil
        return bonjourFound
    }

    // MARK: Helpers

    func log(_ text: String) {
        let t = Date().timeIntervalSince(startDate)
        lines.append(String(format: "%6.1fs ", t) + text)
    }

    struct WifiAddress {
        let address: String
        let netmask: String
        let gatewayGuess: String
    }

    /// IPv4 of en0 (Wi‑Fi). The dash is normally the first host of the subnet (e.g. 192.168.3.1).
    static func wifiIPv4() -> WifiAddress? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == "en0",
                  let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let nm = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let ipHost = UInt32(bigEndian: ip), maskHost = UInt32(bigEndian: nm)
            let gateway = (ipHost & maskHost) + 1
            return WifiAddress(address: dotted(ipHost), netmask: dotted(maskHost), gatewayGuess: dotted(gateway))
        }
        return nil
    }

    private static func dotted(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }
}

/// Reads what the dash sends on a reverse socket and logs the first frames' command IDs.
private final class InboundReader {
    private let port: UInt16
    private let log: (String) -> Void
    private var buffer = Data()
    private var frames = 0

    init(port: UInt16, log: @escaping (String) -> Void) {
        self.port = port
        self.log = log
    }

    func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, done, error in
            if let data { buffer.append(data) }
            drain()
            if let error { log("    :\(port) closed: \(error)"); return }
            if done { log("    :\(port) closed by the dash"); return }
            receive(on: connection)
        }
    }

    private func drain() {
        do {
            while frames < 12 {
                if port == 10922 {
                    guard let frame = try PXCWireCodec.takeControlFrame(from: &buffer) else { return }
                    frames += 1
                    log(String(format: "    :%d cmd=0x%08x len=%d", Int(port), frame.command, frame.payload.count))
                } else {
                    guard let request = try PXCWireCodec.takeMediaRequest(from: &buffer) else { return }
                    frames += 1
                    log("    :\(port) request cmd=\(request.command) len=\(request.payload.count)")
                }
            }
            buffer.removeAll()
        } catch {
            log("    :\(port) unexpected framing (\(error)); first bytes \(buffer.prefix(16).map { String(format: "%02x", $0) }.joined())")
            buffer.removeAll()
            frames = 12
        }
    }
}

/// One MDNS_RESPOND probe on a fresh TCP connection.
enum MirrorProbe {
    static let mdnsRespond: UInt32 = 0x7000_0010
    static let mdnsRespondAck: UInt32 = 0x7000_0011

    struct Result {
        let accepted: Bool
        let refused: Bool
        let message: String
    }

    static func run(endpoint: NWEndpoint, json: String, queue: DispatchQueue) async -> Result {
        let request: Data
        do { request = try PXCWireCodec.encodeControl(command: mdnsRespond, payload: Data(json.utf8)) }
        catch { return Result(accepted: false, refused: false, message: "encode error \(error)") }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi
        let connection = NWConnection(to: endpoint, using: params)
        let state = ProbeState()

        return await withCheckedContinuation { continuation in
            func finish(_ result: Result) {
                guard state.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
                    if let data { state.buffer.append(data) }
                    do {
                        if let frame = try PXCWireCodec.takeControlFrame(from: &state.buffer) {
                            let body = String(decoding: frame.payload.prefix(300), as: UTF8.self)
                            let ok = frame.command == mdnsRespondAck && body.contains("true")
                            finish(Result(accepted: ok, refused: false,
                                          message: String(format: "← cmd=0x%08x ", frame.command) + body))
                            return
                        }
                    } catch {
                        finish(Result(accepted: false, refused: false, message: "unexpected reply framing: \(error)"))
                        return
                    }
                    if let error { finish(Result(accepted: false, refused: false, message: "receive error: \(error)")); return }
                    if done { finish(Result(accepted: false, refused: false, message: "dash closed without answering")); return }
                    receive()
                }
            }
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error { finish(Result(accepted: false, refused: false, message: "send error: \(error)")) }
                        else { receive() }
                    })
                case .waiting(let error), .failed(let error):
                    let refused: Bool
                    if case .posix(let code) = error { refused = code == .ECONNREFUSED } else { refused = false }
                    finish(Result(accepted: false, refused: refused, message: "connect failed: \(error)"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6) {
                finish(Result(accepted: false, refused: false, message: "timeout after 6 s"))
            }
        }
    }

    private final class ProbeState {
        private let lock = NSLock()
        private var done = false
        var buffer = Data()

        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
