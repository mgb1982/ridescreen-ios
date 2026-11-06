import Foundation
import Security

/// EasyConn / PXC messages a Zontes dash expects from the phone, ported from RideScreen AA for Android
/// (PxcHandshake.kt, EasyConnProber.kt, BikeProfile.kt, HuQueryTime.kt). Pure functions, so the bytes
/// can be tested against the Android implementation without a bike.
enum DashProtocol {
    // Control plane (TCP 10922, 16-byte CmdBaseHead).
    static let carCtrl: UInt32 = 0x10000
    static let carData: UInt32 = 0x20000
    static let clientInfo: UInt32 = 0x10010
    static let clientInfoReply: UInt32 = 0x10011
    static let querySpeed: UInt32 = 0x10690
    static let checkSN: UInt32 = 0x103e0
    static let checkSNResult: UInt32 = 0x201c0
    static let heartbeat: UInt32 = 0x7000_0000
    static let heartbeatAck: UInt32 = 0x7000_0001
    static let huTimeSync: UInt32 = 0x10600
    static let huQueryTime: UInt32 = 0x10450
    static let appStatusForeground: UInt32 = 0x20020

    // Media plane (TCP 10920/10921, 8-byte ReqBase).
    static let reqConfigCapture: UInt16 = 16
    static let rlyConfigCapture: UInt16 = 17
    static let reqGetVersion: UInt16 = 48
    static let reqHeartbeat: UInt16 = 64
    static let reqConfigExtend: UInt16 = 96
    static let reqDataStart: UInt16 = 112
    static let rlyDataStart: UInt16 = 113
    static let reqDataNext: UInt16 = 114
    static let reqStartH264: UInt16 = 128

    /// Same identity the Android app uses (the dash accepts it on every Zontes tested).
    static let spoofedPackage = "com.cfmoto.cfmotointernational"
    static let probeJSON = #"{"phoneType":"Android","packageName":"com.cfmoto.cfmotointernational"}"#

    /// Channels where Android sends APPSTATUS, the CHECK_SN result on CAR_DATA and the Zontes time
    /// reply (125X/125V 21340, 368 21334, 350D/E 21313, T350X 34808, 125M 21322).
    static let clockFixChannels: Set<String> = ["21340", "21334", "21313", "34808", "21322"]

    // MARK: Control replies

    /// CLIENT_INFO reply (0x10011): Android's `basePhoneClientInfo` with the MotoPlay supportFunction.
    static func clientInfoReply(phoneUUID: String, publicKeyBase64: String, encryptedHUID: String,
                                supportFunction: Int = 128) -> Data {
        let fields: [(String, Any)] = [
            ("pxcVersion", "1.0.2"),
            ("phoneUUID", phoneUUID),
            ("phoneBrand", "Google"),
            ("phoneModel", "Pixel 7"),
            ("phoneOsVersion", "34"),
            ("phoneOs", "Android"),
            ("package", spoofedPackage),
            ("versionCode", 126),
            ("token", 0),
            ("pubkey", publicKeyBase64),
            ("encryptedHUID", encryptedHUID),
            ("bluetoothName", "RideScreen"),
            ("supportH264IFrame", true),
            ("supportFunction", supportFunction),
            ("supportSyncCorrectTime", false),
            ("appVersionFingerPrint", "opencfmoto-poc"),
        ]
        return orderedJSON(fields)
    }

    /// CHECK_SN result (0x201c0).
    static func checkSNResult(serial: String) -> Data {
        orderedJSON([("isOk", true), ("errCode", 0), ("errMsg", ""), ("id", serial), ("client_set", "easy_conn")])
    }

    /// APPSTATUS_FOREGROUND (0x20020) body: the phone's portrait size in pixels.
    static func appStatusPayload(width: Int, height: Int) -> Data {
        orderedJSON([("displayRotation", 0), ("width", min(width, height)), ("height", max(width, height)),
                     ("enableAccessibility", false), ("enableAOAHid", true), ("mode", 2)])
    }

    /// Zontes QUERY_TIME reply (0x10451): `{"time","currentTime","currentTimeZone","dateTime"}`,
    /// dateTime as `dd.MM.yyyy HH:mm:ss:SSS` in the phone's zone.
    static func zontesTime(now: Date, zone: TimeZone) -> Data {
        let ms = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let current = ms + Int64(zone.secondsFromGMT(for: now)) * 1000
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = zone
        fmt.dateFormat = "dd.MM.yyyy HH:mm:ss"
        let stamp = fmt.string(from: now) + String(format: ":%03d", Int(ms % 1000))
        return orderedJSON([("time", ms), ("currentTime", current), ("currentTimeZone", zone.identifier), ("dateTime", stamp)])
    }

    // MARK: Media replies

    struct CaptureConfig: Equatable {
        let width: Int
        let height: Int
        let fps: Int
        let encoder: Int
        let extend: UInt8
    }

    /// Parses REQ_CONFIG_CAPTURE (16): w u16 @0, h u16 @2, fps i32 @4, encoder i32 @8, ext byte @29.
    /// Sizes are rounded down to multiples of 16 like Android.
    static func parseCaptureConfig(_ body: Data) -> CaptureConfig {
        let b = [UInt8](body)
        func u16(_ o: Int) -> Int { b.count >= o + 2 ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func i32(_ o: Int) -> Int {
            guard b.count >= o + 4 else { return 0 }
            return Int(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24))
        }
        let encoder = b.count >= 12 ? i32(8) : 2
        return CaptureConfig(width: u16(0) & 0xFFF0, height: u16(2) & 0xFFF0, fps: b.count >= 8 ? i32(4) : 0,
                             encoder: encoder == 0 ? 2 : encoder, extend: b.count >= 30 ? b[29] : 0)
    }

    /// RLY_CONFIG_CAPTURE (17) body: encoder i32 | width u16 | height u16 | ext u8.
    static func captureReply(_ c: CaptureConfig) -> Data {
        var d = Data()
        d.appendLittleEndian(UInt32(truncatingIfNeeded: c.encoder))
        d.appendLittleEndian(UInt16(truncatingIfNeeded: c.width))
        d.appendLittleEndian(UInt16(truncatingIfNeeded: c.height))
        d.append(c.extend)
        return d
    }

    /// RLY_GET_VERSION (49) body: version 3, subVersion 1.
    static let versionReply: Data = {
        var d = Data()
        d.appendLittleEndian(UInt32(3))
        d.appendLittleEndian(UInt32(1))
        return d
    }()

    // MARK: JSON

    /// JSON with keys in the given order (Android's org.json keeps insertion order; some dashes are picky).
    static func orderedJSON(_ fields: [(String, Any)]) -> Data {
        func value(_ v: Any) -> String {
            switch v {
            case let b as Bool: return b ? "true" : "false"
            case let i as Int: return String(i)
            case let i as Int64: return String(i)
            case let s as String:
                let enc = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
                return String(enc.dropFirst().dropLast())
            default: return "null"
            }
        }
        let body = fields.map { "\"\($0.0)\":\(value($0.1))" }.joined(separator: ",")
        return Data("{\(body)}".utf8)
    }
}

/// The session RSA key the CLIENT_INFO reply carries (Android RsaKeys: 1024-bit, X.509 public key,
/// HUID "encrypted" with the private key = PKCS#1 v1.5 type-1 signature without a digest).
final class DashRSA {
    let publicKeyBase64: String
    private let privateKey: SecKey?

    init() {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 1024]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error)
        privateKey = key
        if let key, let pub = SecKeyCopyPublicKey(key),
           let pkcs1 = SecKeyCopyExternalRepresentation(pub, nil) as Data? {
            publicKeyBase64 = Self.spki(fromPKCS1: pkcs1).base64EncodedString()
        } else {
            publicKeyBase64 = ""
        }
    }

    /// Wraps a PKCS#1 RSAPublicKey in the X.509 SubjectPublicKeyInfo Java's `PublicKey.encoded` gives.
    static func spki(fromPKCS1 pkcs1: Data) -> Data {
        let algorithm: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString: [UInt8] = [0x03] + derLength(pkcs1.count + 1) + [0x00] + [UInt8](pkcs1)
        let body: [UInt8] = algorithm + bitString
        let whole: [UInt8] = [0x30] + derLength(body.count) + body
        return Data(whole)
    }

    static func derLength(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        if n <= 0xFF { return [0x81, UInt8(n)] }
        return [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]
    }

    func signHUID(_ huid: String) -> String {
        guard let privateKey, !huid.isEmpty else { return "" }
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, .rsaSignatureDigestPKCS1v15Raw, Data(huid.utf8) as CFData, &error) else {
            return ""
        }
        return (sig as Data).base64EncodedString()
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
