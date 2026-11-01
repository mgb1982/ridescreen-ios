import Combine
import CoreBluetooth
import CommonCrypto
import Foundation
import Security

enum PKEAction: String, CaseIterable, Identifiable {
    case lock = "1", unlock = "2", fuel = "5", seat = "6"
    var id: String { rawValue }
    var title: String {
        switch self { case .lock: "Bloquear"; case .unlock: "Desbloquear"; case .fuel: "Abrir depÃ³sito"; case .seat: "Abrir asiento" }
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
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), kp.baseAddress, key.count, nil, bp.baseAddress, block.count, op.baseAddress, output.count, &moved)
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
    static func set(_ value: String, account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var item = q; item[kSecValueData as String] = Data(value.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

@MainActor
final class PKEControlService: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var voltage: Double?
    @Published private(set) var locked: Bool?
    @Published var status = "Configura el PKE para empezar"
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var continuation: CheckedContinuation<String, Error>?
    private var buffer = ""
    private var expectedCode = ""
    private var scanWaiter: CheckedContinuation<CBPeripheral, Error>?
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var readyWaiter: CheckedContinuation<Void, Error>?

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    func refresh() async { await run { try await self.readStatus() } }
    func execute(_ action: PKEAction, speedKmh: Double?) async {
        if action == .lock && (speedKmh == nil || speedKmh! > 3) { status = "No se bloquea: falta velocidad GPS reciente o supera 3 km/h"; return }
        await run { try await self.send(action) }
    }
    private func run(_ operation: @escaping () async throws -> Void) async {
        do { try await operation() } catch { status = error.localizedDescription }
    }
    private func credentials() throws -> (String, String) {
        guard let code = PKECredentials.get("code"), code.count >= 8 else { throw PKEError.missingCredentials }
        guard let mcu = PKECredentials.get("mcuid"), PKEProtocol.validMcuID(mcu) else { throw PKEError.missingCredentials }
        return (code, mcu)
    }
    private func readStatus() async throws {
        let (code, _) = try credentials(); status = "Conectando con la cajaâ€¦"
        try await open(code: code)
        defer { close() }
        let reply = try await ask(code: code, command: "008")
        voltage = PKEProtocol.voltage(reply)
        let state = try await ask(code: code, command: "001,7")
        locked = PKEProtocol.locked(state)
        guard voltage != nil || locked != nil else { throw PKEError.badReply }
        status = "Conectado"
    }
    private func send(_ action: PKEAction) async throws {
        let (code, mcu) = try credentials(); status = "Conectando con la cajaâ€¦"
        try await open(code: code); defer { close() }
        let challengeReply = try await ask(code: code, command: "008")
        voltage = PKEProtocol.voltage(challengeReply)
        guard let nonce = PKEProtocol.challenge(challengeReply), let cipher = PKEProtocol.derive(code: code, mcuID: mcu, challenge: nonce) else { throw PKEError.badReply }
        try await write(PKEProtocol.actionFrame(code: code, action: action, cipher: cipher))
        _ = try await waitReply(command: "001")
        try await Task.sleep(for: .milliseconds(1500))
        let state = try await ask(code: code, command: "001,7")
        locked = PKEProtocol.locked(state)
        status = action == .lock && locked != true ? "La caja no confirmÃ³ el bloqueo" : (action == .unlock && locked != false ? "La caja no confirmÃ³ el desbloqueo" : "Orden enviada Â· estado actualizado")
    }
    private func open(code: String) async throws {
        expectedCode = code
        guard central.state == .poweredOn else { throw PKEError.bluetoothOff }
        let found = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CBPeripheral, Error>) in
            scanWaiter = c; central.scanForPeripherals(withServices: [PKEProtocol.service]);
            Task { try? await Task.sleep(for: .seconds(12)); if self.scanWaiter != nil { self.central.stopScan(); self.scanWaiter?.resume(throwing: PKEError.notFound); self.scanWaiter = nil } }
        }
        peripheral = found; found.delegate = self
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in connectWaiter = c; central.connect(found) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in readyWaiter = c; found.discoverServices([PKEProtocol.service]) }
    }
    private func ask(code: String, command: String) async throws -> String {
        try await write(PKEProtocol.frame(code: code, command: command)); return try await waitReply(command: String(command.prefix(3)))
    }
    private func write(_ data: Data) async throws {
        guard let p = peripheral, let c = writeChar else { throw PKEError.noLink }
        if c.properties.contains(.writeWithoutResponse) && !c.properties.contains(.write) {
            guard p.canSendWriteWithoutResponse else { throw PKEError.noLink }
            p.writeValue(data, for: c, type: .withoutResponse)
            return
        }
        guard c.properties.contains(.write) else { throw PKEError.noLink }
        try await withCheckedThrowingContinuation { (w: CheckedContinuation<Void, Error>) in
            continuation = nil; writeWaiter = w; p.writeValue(data, for: c, type: .withResponse)
        }
    }
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private func waitReply(command: String) async throws -> String {
        try await withCheckedThrowingContinuation { c in
            continuation = c; expectedReply = command
            Task { try? await Task.sleep(for: .seconds(6)); if self.continuation != nil { self.continuation?.resume(throwing: PKEError.timeout); self.continuation = nil } }
        }
    }
    private var expectedReply = ""
    private func close() { if let p = peripheral { central.cancelPeripheralConnection(p) }; peripheral = nil; writeChar = nil; notifyChar = nil }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { if central.state != .poweredOn { status = "Bluetooth no disponible" } }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "").uppercased()
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
        let advertHex = (Array(serviceData.values) + [manufacturerData]).map { $0.map { String(format: "%02X", $0) }.joined() }.joined()
        guard name.contains(expectedCode) || name == "PKE-" + expectedCode.suffix(4) || advertHex.contains(expectedCode) else { return }
        central.stopScan(); scanWaiter?.resume(returning: p); scanWaiter = nil
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) { connectWaiter?.resume(); connectWaiter = nil }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { connectWaiter?.resume(throwing: error ?? PKEError.noLink); connectWaiter = nil }
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
        guard error == nil, characteristic.uuid == PKEProtocol.tx, let data = characteristic.value, let chunk = String(data: data, encoding: .ascii) else { return }
        buffer += chunk
        while let end = buffer.firstIndex(of: "#") {
            let frame = String(buffer[...end]); buffer = String(buffer[buffer.index(after: end)...])
            let parts = frame.components(separatedBy: ",")
            guard parts.first == "*AT", parts.contains(expectedReply), parts.contains(expectedCode) else { continue }
            continuation?.resume(returning: frame); continuation = nil
        }
    }
}

enum PKEError: LocalizedError {
    case missingCredentials, bluetoothOff, notFound, noLink, timeout, badReply
    var errorDescription: String? { switch self { case .missingCredentials: "Configura el cÃ³digo PKE y el McuID"; case .bluetoothOff: "Activa Bluetooth"; case .notFound: "No se encontrÃ³ la caja PKE"; case .noLink: "No se pudo conectar con la caja"; case .timeout: "La caja no respondiÃ³"; case .badReply: "Respuesta PKE no vÃ¡lida" } }
}

