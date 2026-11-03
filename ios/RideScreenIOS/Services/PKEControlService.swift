import Combine
import CoreBluetooth
import CommonCrypto
import Foundation
import Security

enum PKEAction: String, CaseIterable, Identifiable {
    case lock = "1", unlock = "2", fuel = "5", seat = "6"
    var id: String { rawValue }
    var title: String {
        switch self { case .lock: String(localized: "pke.action.lock"); case .unlock: String(localized: "pke.action.unlock"); case .fuel: String(localized: "pke.action.fuel"); case .seat: String(localized: "pke.action.seat") }
    }
}

enum PKEProtocol {
    static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rx = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let tx = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    static let ccc = CBUUID(string: "00002902-0000-1000-8000-00805F9B34FB")
    private static let key = Data("TAYOBTa1YCWc2gTS".utf8)

    static func validMcuID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy(\.isHexDigit)
    }
    static func frame(code: String, command: String) -> Data { Data("*BT,\(code),10,\(command)#".utf8) }
    static func challenge(_ reply: String) -> Data? {
        let parts = reply.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "").components(separatedBy: ",")
        guard parts.first == "*AT", let i = parts.firstIndex(of: "008"), i > 0, parts.count > i + 2 else { return nil }
        let field = parts[i + 1]
        for candidate in [field, String(field.dropLast())] {
            guard candidate.count == 8 else { continue }
            var bytes = [UInt8]()
            var index = candidate.startIndex
            while index < candidate.endIndex {
                let next = candidate.index(index, offsetBy: 2)
                guard let byte = UInt8(candidate[index..<next], radix: 16) else { return nil }
                bytes.append(byte); index = next
            }
            if bytes.count == 4 { return Data(bytes) }
        }
        return nil
    }
    static func voltage(_ reply: String) -> Double? {
        let p = reply.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "").components(separatedBy: ",")
        guard p.first == "*AT", let i = p.firstIndex(of: "008"), let raw = p[safe: i + 2], let n = Double(raw) else { return nil }
        let v = n / 10
        return (5...20).contains(v) ? v : nil
    }
    static func locked(_ reply: String) -> Bool? {
        let p = reply.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "").components(separatedBy: ",")
        guard p.first == "*AT", let i = p.firstIndex(of: "001"), p[safe: i + 1] == "7" else { return nil }
        return p[safe: i + 2] == "1" ? true : (p[safe: i + 2] == "2" ? false : nil)
    }
    static func derive(code: String, mcuID: String, challenge: Data) -> Data? {
        guard validMcuID(mcuID), challenge.count == 4, let mcu = hex(mcuID), mcu.count == 16,
              let h = aes(key: key, block: mcu) else { return nil }
        var session = h
        for i in 12..<16 { session[i] ^= challenge[i - 12] }
        var block = [UInt8](repeating: 0, count: 16)
        let codeBytes = Array(code.utf8.prefix(15)); block.replaceSubrange(0..<codeBytes.count, with: codeBytes)
        return aes(key: Data(session), block: Data(block))
    }
    static func actionFrame(code: String, action: PKEAction, cipher: Data) -> Data {
        frame(code: code, command: "001,\(action.rawValue),\(cipher.map { String(format: "%02X", $0) }.joined())")
    }
    private static func hex(_ s: String) -> Data? {
        guard s.count.isMultiple(of: 2) else { return nil }
        var out = Data(); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); guard let b = UInt8(s[i..<j], radix: 16) else { return nil }; out.append(b); i = j }
        return out
    }
    private static func aes(key: Data, block: Data) -> Data? {
        guard key.count == 16, block.count == 16 else { return nil }
        // CommonCrypto is used because the box requires AES-128/ECB without padding.
        var output = [UInt8](repeating: 0, count: 16); var moved: size_t = 0
        let status = key.withUnsafeBytes { kp in block.withUnsafeBytes { bp in output.withUnsafeMutableBytes { op in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), kp.baseAddress, key.count, nil, bp.baseAddress, block.count, op.baseAddress, 16, &moved)
        }}}
        return status == kCCSuccess && moved == 16 ? Data(output) : nil
    }
}

private extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }

enum PKECredentials {
    private static let service = "dev.ridescreen.ios.pke"
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var item = q; item[kSecValueData as String] = Data(value.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

@MainActor
final class PKEControlService: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var voltage: Double?
    @Published private(set) var locked: Bool?
    @Published var status = String(localized: "pke.status.initial")
    @Published private(set) var isBusy = false
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingReplyID: UUID?
    private var buffer = ""
    private var expectedCode = ""
    private var unmatchedPeripheralCount = 0
    private var scanWaiter: CheckedContinuation<CBPeripheral, Error>?
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var readyWaiter: CheckedContinuation<Void, Error>?

    private func log(_ message: String) {
        Task { try? await TripDiagnosticsLogger.shared.append("PKE: \(message)") }
    }

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    func refresh() async { await run { try await self.readStatus() } }
    func execute(_ action: PKEAction, speedKmh: Double?) async {
        if action == .lock && (speedKmh == nil || speedKmh! > 3) { status = String(localized: "pke.status.lockBlocked"); return }
        await run { try await self.send(action) }
    }
    private func run(_ operation: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { try await operation() } catch { log("operation failed: \(error.localizedDescription)"); status = error.localizedDescription }
    }
    private func credentials() throws -> (String, String) {
        guard let code = PKECredentials.get("code"), code.count >= 8 else { throw PKEError.missingCredentials }
        guard let mcu = PKECredentials.get("mcuid"), PKEProtocol.validMcuID(mcu) else { throw PKEError.missingCredentials }
        return (code, mcu)
    }
    private func readStatus() async throws {
        log("battery/status refresh started")
        let (code, _) = try credentials(); status = String(localized: "pke.status.connecting")
        try await open(code: code)
        defer { close() }
        let reply = try await ask(code: code, command: "008")
        voltage = PKEProtocol.voltage(reply)
        let state = try await ask(code: code, command: "001,7")
        locked = PKEProtocol.locked(state)
        guard voltage != nil || locked != nil else { throw PKEError.badReply }
        status = String(localized: "pke.status.connected")
    }
    private func send(_ action: PKEAction) async throws {
        log("action started: \(action.rawValue)")
        let (code, mcu) = try credentials(); status = String(localized: "pke.status.connecting")
        try await open(code: code); defer { close() }
        let challengeReply = try await ask(code: code, command: "008")
        voltage = PKEProtocol.voltage(challengeReply)
        guard let nonce = PKEProtocol.challenge(challengeReply), let cipher = PKEProtocol.derive(code: code, mcuID: mcu, challenge: nonce) else { throw PKEError.badReply }
        _ = try await exchange(PKEProtocol.actionFrame(code: code, action: action, cipher: cipher), command: "001")
        let expectedState: Bool? = action == .lock ? true : (action == .unlock ? false : nil)
        let attempts = expectedState == nil ? 1 : 6
        for attempt in 0..<attempts {
            try await Task.sleep(for: .milliseconds(700))
            let state = try await ask(code: code, command: "001,7")
            locked = PKEProtocol.locked(state)
            if let expectedState, locked == expectedState { break }
            if expectedState == nil { break }
            if attempt < attempts - 1 { log("action state not confirmed yet; checking again") }
        }
        status = action == .lock && locked != true ? String(localized: "pke.status.lockNotConfirmed") : (action == .unlock && locked != false ? String(localized: "pke.status.unlockNotConfirmed") : String(localized: "pke.status.sent"))
    }
    private func open(code: String) async throws {
        expectedCode = code
        log("Bluetooth state: \(central.state.rawValue); scanning BLE advertisements for configured PKE")
        guard central.state == .poweredOn else { throw PKEError.bluetoothOff }
        unmatchedPeripheralCount = 0
        let found = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CBPeripheral, Error>) in
            scanWaiter = c
            // Some PKE boxes expose Nordic UART only after connecting and do not advertise its UUID.
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            Task {
                try? await Task.sleep(for: .seconds(12))
                if self.scanWaiter != nil {
                    self.central.stopScan()
                    self.log("BLE scan timed out; unmatched advertisements observed: \(self.unmatchedPeripheralCount)")
                    self.scanWaiter?.resume(throwing: PKEError.notFound)
                    self.scanWaiter = nil
                }
            }
        }
        peripheral = found; found.delegate = self
        log("matching peripheral found; connecting")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in connectWaiter = c; central.connect(found) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in readyWaiter = c; found.discoverServices([PKEProtocol.service]) }
        log("UART characteristics and notifications ready")
    }
    private func ask(code: String, command: String) async throws -> String {
        log("request sent: \(command); waiting for response")
        return try await exchange(PKEProtocol.frame(code: code, command: command), command: String(command.prefix(3)))
    }
    private func exchange(_ data: Data, command: String) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            guard continuation == nil else { c.resume(throwing: PKEError.busy); return }
            let requestID = UUID()
            continuation = c
            pendingReplyID = requestID
            expectedReply = command
            Task {
                do { try await self.write(data) }
                catch { self.failPendingReply(error) }
            }
            Task {
                try? await Task.sleep(for: .seconds(6))
                if self.pendingReplyID == requestID { self.failPendingReply(PKEError.timeout) }
            }
        }
    }
    private func failPendingReply(_ error: Error) {
        let pending = continuation
        continuation = nil
        pendingReplyID = nil
        pending?.resume(throwing: error)
    }
    private func write(_ data: Data) async throws {
        guard let p = peripheral, let c = writeChar else { throw PKEError.noLink }
        if c.properties.contains(.writeWithoutResponse) && !c.properties.contains(.write) {
            guard p.canSendWriteWithoutResponse else { throw PKEError.noLink }
            p.writeValue(data, for: c, type: .withoutResponse)
            return
        }
        guard c.properties.contains(.write) else { throw PKEError.noLink }
        // Do NOT touch `continuation` here: it holds the pending reply waiter set by exchange().
        // Clearing it would drop the box's reply and hang the operation forever.
        try await withCheckedThrowingContinuation { (w: CheckedContinuation<Void, Error>) in
            let id = UUID()
            writeWaiter = w; writeWaiterID = id
            p.writeValue(data, for: c, type: .withResponse)
            Task {
                try? await Task.sleep(for: .seconds(6))
                if self.writeWaiterID == id, let waiter = self.writeWaiter {
                    self.writeWaiter = nil
                    waiter.resume(throwing: PKEError.timeout)
                }
            }
        }
    }
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private var writeWaiterID: UUID?
    private var expectedReply = ""
    private func close() {
        if continuation != nil { failPendingReply(PKEError.noLink) }
        if let waiter = writeWaiter { writeWaiter = nil; waiter.resume(throwing: PKEError.noLink) }
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil; writeChar = nil; notifyChar = nil; buffer = ""
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { if central.state != .poweredOn { status = String(localized: "pke.status.btUnavailable") } }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "").uppercased()
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
        let advertHex = (Array(serviceData.values) + [manufacturerData]).map { $0.map { String(format: "%02X", $0) }.joined() }.joined()
        guard name.contains(expectedCode) || name == "PKE-" + expectedCode.suffix(4) || advertHex.contains(expectedCode) else {
            unmatchedPeripheralCount += 1
            return
        }
        log("configured PKE advertisement matched; RSSI \(rssi)")
        central.stopScan(); scanWaiter?.resume(returning: p); scanWaiter = nil
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) { log("connected; discovering UART service"); connectWaiter?.resume(); connectWaiter = nil }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { log("connection failed: \(error?.localizedDescription ?? "unknown")"); connectWaiter?.resume(throwing: error ?? PKEError.noLink); connectWaiter = nil }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let s = p.services?.first(where: { $0.uuid == PKEProtocol.service }) else { readyWaiter?.resume(throwing: PKEError.noLink); readyWaiter = nil; return }
        p.discoverCharacteristics([PKEProtocol.rx, PKEProtocol.tx], for: s)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics, let rx = chars.first(where: { $0.uuid == PKEProtocol.rx }), let tx = chars.first(where: { $0.uuid == PKEProtocol.tx }) else { readyWaiter?.resume(throwing: PKEError.noLink); readyWaiter = nil; return }
        writeChar = rx; notifyChar = tx; p.setNotifyValue(true, for: tx)
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) { if characteristic.uuid == PKEProtocol.tx { if let error { readyWaiter?.resume(throwing: error) } else { readyWaiter?.resume() }; readyWaiter = nil } }
    func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) { if let error { writeWaiter?.resume(throwing: error) } else { writeWaiter?.resume() }; writeWaiter = nil }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == PKEProtocol.tx, let data = characteristic.value, let chunk = String(data: data, encoding: .ascii) else { if let error { log("notification error: \(error.localizedDescription)") }; return }
        buffer += chunk
        while let end = buffer.firstIndex(of: "#") {
            let frame = String(buffer[...end]); buffer = String(buffer[buffer.index(after: end)...])
            let parts = frame.components(separatedBy: ",")
            guard parts.first == "*AT", parts.contains(expectedReply), parts.contains(expectedCode) else { log("ignored unmatched response frame (contents redacted)"); continue }
            log("expected response received (contents redacted)")
            let pending = continuation
            continuation = nil
            pendingReplyID = nil
            pending?.resume(returning: frame)
        }
    }
}

enum PKEError: LocalizedError {
    case missingCredentials, bluetoothOff, notFound, noLink, timeout, badReply, busy
    var errorDescription: String? {
        switch self {
        case .missingCredentials: String(localized: "pke.error.missingCredentials")
        case .bluetoothOff: String(localized: "pke.error.bluetoothOff")
        case .notFound: String(localized: "pke.error.notFound")
        case .noLink: String(localized: "pke.error.noLink")
        case .timeout: String(localized: "pke.error.timeout")
        case .badReply: String(localized: "pke.error.badReply")
        case .busy: String(localized: "pke.error.busy")
        }
    }
}

