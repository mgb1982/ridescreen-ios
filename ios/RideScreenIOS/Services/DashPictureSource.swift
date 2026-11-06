import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import UIKit
import VideoToolbox

/// RideScreen's own picture for the dash: drawn on the CPU (no screen, works with the phone locked
/// as long as the app is kept alive) and encoded to H.264 Baseline with VideoToolbox at 10 fps.
///
/// Unknown on purpose, and logged: whether iOS lets the hardware encoder run while the app is in
/// the background. If it refuses, the last keyframe keeps being served so the dash shows a frozen
/// picture instead of dropping the link, and the log says so.
final class DashPictureSource: DashFrameSource {
    var onNewFrame: (() -> Void)?

    private let q = DispatchQueue(label: "ridescreen.dash-picture")
    private let lock = NSLock()
    private let log: (String) -> Void

    // Encoded output (guarded by [lock]).
    private var latest: (sequence: Int, data: Data, key: Bool)?
    private var lastKeyframe: Data?
    private var sequence = 0
    private var awaitingKeyframe = true

    // Encoder state (on [q]).
    private var width = 800
    private var height = 416
    private var session: VTCompressionSession?
    private var timer: DispatchSourceTimer?
    private var forceKeyframe = true
    private var frameIndex: Int64 = 0
    private var encodeFailures = 0
    private var encodedFrames = 0

    // Inputs from the UI (guarded by [lock]).
    private var speedKmh: Double?
    private var appState = "app abierta"
    private var map: CGImage?
    private var mapNote = "mapa: esperando ubicación"

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    func update(speedKmh: Double?, appState: String) {
        lock.lock(); self.speedKmh = speedKmh; self.appState = appState; lock.unlock()
    }

    func setMap(_ image: CGImage?, note: String) {
        lock.lock(); if let image { map = image }; mapNote = note; lock.unlock()
    }

    // MARK: DashFrameSource

    func configure(width: Int, height: Int) {
        q.async { [self] in
            let w = max(160, width), h = max(96, height)
            if w != self.width || h != self.height || session == nil {
                self.width = w; self.height = h
                makeSession()
            }
            startTimer()
        }
    }

    func startStreaming() {
        lock.lock(); awaitingKeyframe = true; lock.unlock()
        q.async { [self] in
            forceKeyframe = true
            if session == nil { makeSession() }
            startTimer()
        }
    }

    func frame(after sequence: Int) -> (sequence: Int, data: Data)? {
        lock.lock(); defer { lock.unlock() }
        guard let latest, latest.sequence > sequence else { return nil }
        if awaitingKeyframe && !latest.key { return nil }
        awaitingKeyframe = false
        return (latest.sequence, latest.data)
    }

    func stop() {
        q.async { [self] in
            timer?.cancel(); timer = nil
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
        }
    }

    // MARK: Encoder

    private func makeSession() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else {
            log("[ENC] !! could not create the H.264 encoder (status \(status))")
            return
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 1_200_000))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 10))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 20))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        forceKeyframe = true
        log("[ENC] H.264 Baseline \(width)x\(height) @10 fps ready")
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if session == nil { makeSession() }
        guard let session, let buffer = render() else { return }
        let pts = CMTime(value: frameIndex, timescale: 10)
        frameIndex += 1
        let props: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 10),
            frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
                self?.encoded(status: status, sample: sample)
            }
        if status == noErr {
            forceKeyframe = false
        } else {
            encodeFailed(status)
        }
    }

    private func encoded(status: OSStatus, sample: CMSampleBuffer?) {
        guard status == noErr, let sample, let unit = Self.annexB(sample) else {
            q.async { [weak self] in self?.encodeFailed(status) }
            return
        }
        let data = unit.0, key = unit.1
        lock.lock()
        sequence += 1
        latest = (sequence, data, key)
        if key { lastKeyframe = data }
        lock.unlock()
        q.async { [weak self] in
            guard let self else { return }
            if self.encodeFailures > 0 {
                self.log("[ENC] encoder working again after \(self.encodeFailures) failure(s) (\(self.currentState()))")
                self.encodeFailures = 0
            }
            self.encodedFrames += 1
        }
        onNewFrame?()
    }

    /// The hardware encoder may be refused in the background. Keep serving the last keyframe (a
    /// frozen picture) and rebuild the session so it recovers when allowed again.
    private func encodeFailed(_ status: OSStatus) {
        encodeFailures += 1
        if encodeFailures == 1 || encodeFailures % 50 == 0 {
            log("[ENC] !! encode failed (status \(status), \(currentState()), #\(encodeFailures)) — repeating the last keyframe")
        }
        lock.lock()
        if let key = lastKeyframe {
            sequence += 1
            latest = (sequence, key, true)
        }
        lock.unlock()
        if lastKeyframe != nil { onNewFrame?() }
        if status == kVTInvalidSessionErr || encodeFailures % 20 == 0 {
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
        }
    }

    private func currentState() -> String {
        lock.lock(); defer { lock.unlock() }
        return appState
    }

    // MARK: Drawing

    private func render() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                     kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        if let pool = session.flatMap({ VTCompressionSessionGetPixelBufferPool($0) }) {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        }
        if pb == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb)
        }
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        lock.lock()
        let speed = speedKmh, state = appState, mapImage = map, note = mapNote
        lock.unlock()
        let frames = encodedFrames
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        DashPicture.draw(in: CGRect(x: 0, y: 0, width: width, height: height), speedKmh: speed, state: state,
                         map: mapImage, mapNote: note, frames: frames)
        return pb
    }

    // MARK: AVCC → Annex B

    /// One access unit as Annex B (00 00 00 01 start codes), with SPS/PPS in front of keyframes.
    static func annexB(_ sample: CMSampleBuffer) -> (Data, Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        if key, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    out.append(contentsOf: startCode)
                    out.append(pointer, count: size)
                }
            }
        }
        let total = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: total)
        let copied = avcc.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: base)
        }
        guard copied == noErr else { return nil }
        guard let units = avccToAnnexB(avcc) else { return nil }
        out.append(units)
        return (out, key)
    }

    /// 4-byte big-endian length prefixes → start codes. Nil if a length runs past the buffer.
    static func avccToAnnexB(_ avcc: Data) -> Data? {
        let bytes = [UInt8](avcc)
        var out = Data()
        var i = 0
        while i + 4 <= bytes.count {
            let len = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            guard len > 0, i + len <= bytes.count else { return nil }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(contentsOf: bytes[i..<(i + len)])
            i += len
        }
        return out
    }
}

/// The test picture: speed, clock, app state and a map snapshot, laid out for the 125X window
/// (nothing readable below y≈326, nor below y≈284 right of x≈676, on the 800×416 design size).
enum DashPicture {
    static func draw(in rect: CGRect, speedKmh: Double?, state: String, map: CGImage?, mapNote: String, frames: Int) {
        let s = rect.height / 416
        let bg = UIColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 1)
        bg.setFill(); UIRectFill(rect)

        func text(_ str: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: UIColor, bold: Bool = false) {
            let font = UIFont.systemFont(ofSize: size * s, weight: bold ? .heavy : .medium)
            (str as NSString).draw(at: CGPoint(x: x * s, y: y * s), withAttributes: [.font: font, .foregroundColor: color])
        }
        let gold = UIColor(red: 1, green: 0.62, blue: 0.16, alpha: 1)
        let muted = UIColor(white: 0.62, alpha: 1)

        // Speed.
        let speedText = speedKmh.map { String(Int($0.rounded())) } ?? "—"
        text(speedText, 30, 40, 150, .white, bold: true)
        text("km/h · GPS", 38, 228, 26, muted)

        // Clock (changes every second: proves the picture is live, not frozen).
        let clock = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        text(clock, 30, 270, 30, gold, bold: true)

        // Map.
        let mapRect = CGRect(x: 410 * s, y: 22 * s, width: 370 * s, height: 250 * s)
        let clip = UIBezierPath(roundedRect: mapRect, cornerRadius: 14 * s)
        if let map {
            UIGraphicsGetCurrentContext()?.saveGState()
            clip.addClip()
            UIImage(cgImage: map).draw(in: mapRect)
            UIGraphicsGetCurrentContext()?.restoreGState()
            gold.setFill()
            UIBezierPath(ovalIn: CGRect(x: mapRect.midX - 7 * s, y: mapRect.midY - 7 * s, width: 14 * s, height: 14 * s)).fill()
            UIColor.white.setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: mapRect.midX - 9 * s, y: mapRect.midY - 9 * s, width: 18 * s, height: 18 * s))
            ring.lineWidth = 2 * s; ring.stroke()
        } else {
            UIColor(white: 0.12, alpha: 1).setFill(); clip.fill()
        }
        UIColor(white: 0.3, alpha: 1).setStroke(); clip.lineWidth = 1.5 * s; clip.stroke()
        text(mapNote, 418, 278, 15, muted)

        // Status line (left, above the dash strip).
        text("RideScreen iOS · \(state) · \(frames) img", 30, 302, 16, muted)
    }
}
