import Foundation
import Network

/// Where the encoded picture comes from. Called on the link's queue except [onNewFrame].
protocol DashFrameSource: AnyObject {
    /// The dash's canvas from REQ_CONFIG_CAPTURE (e.g. 800×416 on the 125X).
    func configure(width: Int, height: Int)
    /// REQ_RV_DATA_START: the next frame handed out must be a keyframe with SPS/PPS.
    func startStreaming()
    /// The newest encoded access unit (Annex B) newer than [sequence], if any. Thread-safe.
    func frame(after sequence: Int) -> (sequence: Int, data: Data)?
    /// Called (any thread) whenever a new access unit is ready.
    var onNewFrame: (() -> Void)? { get set }
}

/// A full EasyConn session with a Zontes dash, as RideScreen AA does on Android: probe the dash on
/// :10930, accept its connections on 10920–10922, answer the PXC control handshake (CAR_CTRL/CAR_DATA,
/// CLIENT_INFO, CHECK_SN, APPSTATUS, time) and serve H.264 frames when the dash pulls them (REQ 114).
/// No Android Auto: the picture is whatever [DashFrameSource] encodes.
final class DashLink {
    static let controlPort: UInt16 = 10922
    static let mediaPorts: [UInt16] = [10921, 10920]

    private let q = DispatchQueue(label: "ridescreen.dash-link")
    private let probeQueue = DispatchQueue(label: "ridescreen.dash-probe")
    private let log: (String) -> Void
    private let rsa = DashRSA()
    private let phoneUUID = UUID().uuidString.lowercased()
    private let screenPixels: (Int, Int)
    private weak var source: DashFrameSource?

    private var running = false
    private var host = ""
    private var listeners: [NWListener] = []
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var ctrlPeer: Peer?
    private var dataPeer: Peer?
    private var channel = ""
    private var ctrlSelectedAt = Date.distantPast
    private var ackLogged: Set<UInt32> = []
    private var pendingPull: Peer?
    private var lastSentSequence = -1
    private var framesSent = 0
    private var probing = false

    /// Streaming state changes (true once the first frame went out), on the link queue.
    var onStreamingChanged: ((Bool) -> Void)?
    /// Frames sent so far, for the UI.
    private(set) var sentCount = 0

    init(source: DashFrameSource, screenPixels: (Int, Int), log: @escaping (String) -> Void) {
        self.source = source
        self.screenPixels = screenPixels
        self.log = log
        source.onNewFrame = { [weak self] in self?.q.async { self?.sendPendingFrame() } }
    }

    func start(host: String) {
        q.async { [self] in
            guard !running else { return }
            running = true
            self.host = host
            framesSent = 0
            lastSentSequence = -1
            openListeners()
            probeUntilConnected()
        }
    }

    func stop() {
        q.async { [self] in
            running = false
            listeners.forEach { $0.cancel() }
            listeners = []
            peers.values.forEach { $0.close() }
            peers = [:]
            ctrlPeer = nil
            dataPeer = nil
            pendingPull = nil
            onStreamingChanged?(false)
        }
    }

    // MARK: Probe (MDNS_RESPOND on :10930)

    private func probeUntilConnected() {
        guard running, !probing, ctrlPeer == nil else { return }
        probing = true
        let host = self.host
        Task { [weak self] in
            var attempt = 0
            while true {
                guard let self else { return }
                let keepGoing = self.q.sync { self.running && self.ctrlPeer == nil }
                if !keepGoing { break }
                attempt += 1
                let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: 10930)
                let result = await MirrorProbe.run(endpoint: endpoint, json: DashProtocol.probeJSON, queue: self.probeQueue)
                if attempt <= 10 || attempt % 20 == 0 || result.accepted {
                    self.log("[PROBE] #\(attempt) \(host):10930 → \(result.message)")
                }
                if result.accepted { self.log("[PROBE] accepted — waiting for the dash to connect back") }
                try? await Task.sleep(nanoseconds: (result.accepted ? 4 : 3) * 1_000_000_000)
                // Keep trying while the test runs: the bike may be switched on later.
            }
            self?.q.async { self?.probing = false }
        }
    }

    // MARK: Listeners

    private func openListeners() {
        for port in [Self.controlPort] + Self.mediaPorts {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .wifi
            if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.noDelay = true }
            guard let nwPort = NWEndpoint.Port(rawValue: port), let listener = try? NWListener(using: params, on: nwPort) else {
                log("[LINK] !! could not listen on :\(port)")
                continue
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.log("[LINK] listening on :\(port)")
                case .failed(let e): self?.log("[LINK] !! :\(port) failed: \(e)")
                case .waiting(let e): self?.log("[LINK] :\(port) waiting: \(e) (Local Network permission?)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn, port: port) }
            listener.start(queue: q)
            listeners.append(listener)
        }
    }

    private func accept(_ conn: NWConnection, port: UInt16) {
        let peer = Peer(connection: conn, port: port)
        peers[ObjectIdentifier(peer)] = peer
        log("[:\(port)] <<< dash connected from \(conn.endpoint)")
        conn.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .ready: self.receive(peer)
            case .failed(let e): self.closed(peer, reason: "\(e)")
            case .cancelled: self.closed(peer, reason: "cancelled")
            default: break
            }
        }
        conn.start(queue: q)
    }

    private func receive(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak peer] data, _, done, error in
            guard let self, let peer else { return }
            if let data { peer.buffer.append(data) }
            self.drain(peer)
            if let error { self.closed(peer, reason: "\(error)"); return }
            if done { self.closed(peer, reason: "closed by the dash"); return }
            self.receive(peer)
        }
    }

    private func closed(_ peer: Peer, reason: String) {
        guard peers.removeValue(forKey: ObjectIdentifier(peer)) != nil else { return }
        peer.close()
        log("[:\(peer.port)] closed (\(peer.role ?? "media")): \(reason)")
        if ctrlPeer === peer { ctrlPeer = nil }
        if dataPeer === peer { dataPeer = nil }
        if pendingPull === peer { pendingPull = nil }
        if peers.isEmpty && running {
            log("[LINK] all dash sockets closed after \(framesSent) frame(s) — probing again")
            onStreamingChanged?(false)
            framesSent = 0
            probeUntilConnected()
        }
    }

    private func drain(_ peer: Peer) {
        do {
            if peer.port == Self.controlPort {
                while let frame = try PXCWireCodec.takeControlFrame(from: &peer.buffer) { handleControl(frame, peer) }
            } else {
                while let req = try PXCWireCodec.takeMediaRequest(from: &peer.buffer) { handleMedia(req, peer) }
            }
        } catch {
            log("[:\(peer.port)] framing error \(error) — dropping socket")
            peer.connection.cancel()
        }
    }

    // MARK: Control plane

    private func sendControl(_ command: UInt32, _ payload: Data = Data(), on peer: Peer) {
        guard let frame = try? PXCWireCodec.encodeControl(command: command, payload: payload) else { return }
        peer.connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func hex(_ v: UInt32) -> String { "0x" + String(v, radix: 16) }

    private func handleControl(_ frame: PXCWireCodec.ControlFrame, _ peer: Peer) {
        let text = String(data: frame.payload, encoding: .utf8) ?? "<\(frame.payload.count)b>"
        switch frame.command {
        case DashProtocol.carCtrl:
            peer.role = "CAR_CTRL"
            ctrlPeer = peer
            ctrlSelectedAt = Date()
            log("[:10922] dash selected CAR_CTRL → ack 0x10001")
            sendControl(DashProtocol.carCtrl + 1, on: peer)
            startHeartbeat(peer)
        case DashProtocol.carData:
            peer.role = "CAR_DATA"
            dataPeer = peer
            log("[:10922] dash selected CAR_DATA → ack 0x20001")
            sendControl(DashProtocol.carData + 1, on: peer)
            startHeartbeat(peer)
            startAppStatus(peer, waited: 0)
        case DashProtocol.clientInfo:
            let json = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any] ?? [:]
            channel = Self.string(json["channel"])
            let huid = Self.string(json["HUID"]).isEmpty ? Self.string(json["huid"]) : Self.string(json["HUID"])
            log("[:10922] CLIENT_INFO channel=\(channel) HUName=\(Self.string(json["HUName"])) sdk=\(Self.string(json["sdkVersion"]))")
            let reply = DashProtocol.clientInfoReply(phoneUUID: phoneUUID, publicKeyBase64: rsa.publicKeyBase64,
                                                     encryptedHUID: rsa.signHUID(huid))
            log("[:10922] → CLIENT_INFO reply (\(reply.count)b, pubkey \(rsa.publicKeyBase64.isEmpty ? "MISSING" : "ok"))")
            sendControl(DashProtocol.clientInfoReply, reply, on: peer)
        case DashProtocol.querySpeed:
            sendControl(DashProtocol.querySpeed + 1, on: peer)
        case DashProtocol.checkSN:
            let json = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any] ?? [:]
            let sn = Self.string(json["sn"])
            sendControl(DashProtocol.checkSN + 1, on: peer)
            let body = DashProtocol.checkSNResult(serial: sn)
            if DashProtocol.clockFixChannels.contains(channel), let data = dataPeer {
                log("[:10922] CHECK_SN → result on CAR_DATA")
                sendControl(DashProtocol.checkSNResult, body, on: data)
            } else {
                log("[:10922] CHECK_SN → result on \(peer.role ?? "same socket")")
                sendControl(DashProtocol.checkSNResult, body, on: peer)
            }
        case DashProtocol.heartbeat:
            sendControl(DashProtocol.heartbeatAck, on: peer)
        case DashProtocol.heartbeatAck:
            break
        case DashProtocol.checkSNResult + 1, DashProtocol.appStatusForeground + 1, 0x20031, 0x20041, 0x20051:
            if ackLogged.insert(frame.command).inserted { log("[:10922] dash acked \(hex(frame.command))") }
        case DashProtocol.huTimeSync:
            sendControl(DashProtocol.huTimeSync + 1, frame.payload, on: peer)
        case DashProtocol.huQueryTime:
            let after = Int(Date().timeIntervalSince(ctrlSelectedAt) * 1000)
            if DashProtocol.clockFixChannels.contains(channel) {
                sendControl(DashProtocol.huQueryTime + 1, DashProtocol.zontesTime(now: Date(), zone: .current), on: peer)
                log("[:10922] QUERY_TIME after \(after)ms → Zontes time")
            } else {
                sendControl(DashProtocol.huQueryTime + 1, on: peer)
                log("[:10922] QUERY_TIME after \(after)ms → empty ack (channel \(channel))")
            }
        default:
            log("[:10922] \(hex(frame.command)) len=\(frame.payload.count) \(text.prefix(80)) → ack \(hex(frame.command + 1))")
            sendControl(frame.command + 1, on: peer)
        }
    }

    private func startHeartbeat(_ peer: Peer) {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self, weak peer] in
            guard let self, let peer, self.peers[ObjectIdentifier(peer)] != nil else { return }
            self.sendControl(DashProtocol.heartbeat, on: peer)
        }
        t.resume()
        peer.timers.append(t)
    }

    /// APPSTATUS_FOREGROUND every second on CAR_DATA (Zontes clock fix; the official app does it).
    private func startAppStatus(_ peer: Peer, waited: Int) {
        if channel.isEmpty && waited < 3000 {
            q.asyncAfter(deadline: .now() + 0.1) { [weak self, weak peer] in
                guard let self, let peer else { return }
                self.startAppStatus(peer, waited: waited + 100)
            }
            return
        }
        guard DashProtocol.clockFixChannels.contains(channel) else {
            log("[APPSTATUS] not sent on channel \(channel.isEmpty ? "-" : channel)")
            return
        }
        let payload = DashProtocol.appStatusPayload(width: screenPixels.0, height: screenPixels.1)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.13, repeating: 1)
        t.setEventHandler { [weak self, weak peer] in
            guard let self, let peer, self.peers[ObjectIdentifier(peer)] != nil else { return }
            self.sendControl(DashProtocol.appStatusForeground, payload, on: peer)
            peer.appStatusCount += 1
            if peer.appStatusCount <= 2 { self.log("[APPSTATUS] → 0x20020 #\(peer.appStatusCount)") }
        }
        t.resume()
        peer.timers.append(t)
    }

    // MARK: Media plane

    private func sendMedia(_ command: UInt16, _ payload: Data = Data(), on peer: Peer) {
        guard let data = try? PXCWireCodec.encodeMediaResponse(command: command, payload: payload) else { return }
        peer.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func handleMedia(_ req: PXCWireCodec.MediaRequest, _ peer: Peer) {
        let tag = "[:\(peer.port)]"
        switch req.command {
        case DashProtocol.reqConfigCapture:
            let cfg = DashProtocol.parseCaptureConfig(req.payload)
            log("\(tag) CONFIG_CAPTURE \(cfg.width)x\(cfg.height) fps=\(cfg.fps) encoder=\(cfg.encoder) → RLY 17")
            source?.configure(width: cfg.width, height: cfg.height)
            sendMedia(DashProtocol.rlyConfigCapture, DashProtocol.captureReply(cfg), on: peer)
        case DashProtocol.reqGetVersion:
            sendMedia(DashProtocol.reqGetVersion + 1, DashProtocol.versionReply, on: peer)
        case DashProtocol.reqHeartbeat:
            sendMedia(DashProtocol.reqHeartbeat + 1, on: peer)
        case DashProtocol.reqConfigExtend:
            sendMedia(DashProtocol.reqConfigExtend + 1, Data(#"{"state":0}"#.utf8), on: peer)
        case DashProtocol.reqStartH264:
            sendMedia(DashProtocol.reqStartH264 + 1, on: peer)
        case DashProtocol.reqDataStart:
            log("\(tag) RV_DATA_START → RLY 113, next frame is a keyframe")
            source?.startStreaming()
            lastSentSequence = -1
            sendMedia(DashProtocol.rlyDataStart, on: peer)
        case DashProtocol.reqDataNext:
            pendingPull = peer
            sendPendingFrame()
        case 32:
            break // touch: not used
        default:
            log("\(tag) media cmd \(req.command) len=\(req.payload.count)")
        }
    }

    private func sendPendingFrame() {
        guard let peer = pendingPull, peers[ObjectIdentifier(peer)] != nil,
              let frame = source?.frame(after: lastSentSequence),
              let raw = try? PXCWireCodec.encodeRawVideoFrame(frame.data) else { return }
        pendingPull = nil
        lastSentSequence = frame.sequence
        peer.connection.send(content: raw, completion: .contentProcessed { _ in })
        framesSent += 1
        sentCount += 1
        if framesSent == 1 { onStreamingChanged?(true) }
        if framesSent <= 3 || framesSent % 100 == 0 { log("[:\(peer.port)] sent frame #\(framesSent) (\(frame.data.count)b)") }
    }

    private static func string(_ v: Any?) -> String {
        switch v {
        case let s as String: return s.trimmingCharacters(in: .whitespaces)
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    private final class Peer {
        let connection: NWConnection
        let port: UInt16
        var buffer = Data()
        var role: String?
        var appStatusCount = 0
        var timers: [DispatchSourceTimer] = []

        init(connection: NWConnection, port: UInt16) {
            self.connection = connection
            self.port = port
        }

        func close() {
            timers.forEach { $0.cancel() }
            timers = []
            connection.cancel()
        }
    }
}
