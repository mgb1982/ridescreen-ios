import Foundation

enum PXCWireError: Error, Equatable {
    case invalidControlLength
    case invalidControlMagic
    case invalidMediaLength
    case payloadTooLarge
}

/// Wire framing shared by EasyConn's PXC control plane and media plane.
enum PXCWireCodec {
    static let controlHeaderLength = 16
    static let mediaHeaderLength = 8
    static let maximumControlPayload = 1_048_576

    struct ControlFrame: Equatable {
        let command: UInt32
        let payload: Data
    }

    struct MediaRequest: Equatable {
        let command: UInt16
        let token: UInt32
        let payload: Data
    }

    /// Encodes the 16-byte CmdBaseHead header used on TCP 10922.
    static func encodeControl(command: UInt32, payload: Data = Data()) throws -> Data {
        guard payload.count <= maximumControlPayload else { throw PXCWireError.payloadTooLarge }
        let totalLength = UInt32(controlHeaderLength + payload.count)
        var data = Data()
        data.appendLE(command)
        data.appendLE(totalLength)
        data.appendLE(command ^ totalLength)
        data.appendLE(UInt32(0))
        data.append(payload)
        return data
    }

    /// Extracts one complete CmdBaseHead frame from a TCP receive buffer.
    /// Incomplete headers and payloads remain in the caller's buffer.
    static func takeControlFrame(from buffer: inout Data) throws -> ControlFrame? {
        guard buffer.count >= controlHeaderLength else { return nil }
        let command: UInt32 = buffer.readLE(at: 0)
        let totalLength: UInt32 = buffer.readLE(at: 4)
        let magic: UInt32 = buffer.readLE(at: 8)
        guard totalLength >= UInt32(controlHeaderLength),
              totalLength <= UInt32(controlHeaderLength + maximumControlPayload) else {
            throw PXCWireError.invalidControlLength
        }
        guard magic == (command ^ totalLength) else { throw PXCWireError.invalidControlMagic }
        let frameLength = Int(totalLength)
        guard buffer.count >= frameLength else { return nil }
        let payload = Data(buffer[controlHeaderLength..<frameLength])
        buffer.removeSubrange(0..<frameLength)
        return ControlFrame(command: command, payload: payload)
    }

    /// Extracts one 8-byte ReqBase request used on TCP 10920 and 10921.
    static func takeMediaRequest(from buffer: inout Data) throws -> MediaRequest? {
        guard buffer.count >= mediaHeaderLength else { return nil }
        let command: UInt16 = buffer.readLE(at: 0)
        let payloadLength: UInt16 = buffer.readLE(at: 2)
        let token: UInt32 = buffer.readLE(at: 4)
        let frameLength = mediaHeaderLength + Int(payloadLength)
        guard buffer.count >= frameLength else { return nil }
        let payload = Data(buffer[mediaHeaderLength..<frameLength])
        buffer.removeSubrange(0..<frameLength)
        return MediaRequest(command: command, token: token, payload: payload)
    }

    /// Builds a ReqBase response. RideScreen AA uses a zero token in responses.
    static func encodeMediaResponse(command: UInt16, payload: Data = Data()) throws -> Data {
        guard payload.count <= Int(UInt16.max) else { throw PXCWireError.payloadTooLarge }
        var data = Data()
        data.appendLE(command)
        data.appendLE(UInt16(payload.count))
        data.appendLE(UInt32(0))
        data.append(payload)
        return data
    }

    /// Data-plane video responses are raw [UInt32 length, H.264 access unit], not ReqBase.
    static func encodeRawVideoFrame(_ accessUnit: Data) throws -> Data {
        guard accessUnit.count <= Int(UInt32.max) else { throw PXCWireError.payloadTooLarge }
        var data = Data()
        data.appendLE(UInt32(accessUnit.count))
        data.append(accessUnit)
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(self[offset + index]) << (index * 8)
        }
        return value
    }
}
