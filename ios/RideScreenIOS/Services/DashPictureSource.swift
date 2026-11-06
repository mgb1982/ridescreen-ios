import CoreGraphics
import CoreMedia
import CoreVideo
import MapKit
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
    // Smoothed rider position/heading actually drawn (on [q]).
    private var shownRider: MKMapPoint?
    private var shownHeading: Double = 0
    private var tickCount = 0
    // Stats for the per-minute log line (guarded by [lock]).
    private var statFrames = 0
    private var statDrawSeconds = 0.0

    // Inputs from the UI (guarded by [lock]).
    private var speedKmh: Double?
    private var appState = "app abierta"
    private var mapState = DashMapState()

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    func update(speedKmh: Double?, appState: String) {
        lock.lock(); self.speedKmh = speedKmh; self.appState = appState; lock.unlock()
    }

    /// Frames encoded and average drawing time since the last call (for the per-minute log line).
    func takeStats() -> (frames: Int, drawMs: Double) {
        lock.lock(); defer { statFrames = 0; statDrawSeconds = 0; lock.unlock() }
        return (statFrames, statFrames > 0 ? statDrawSeconds / Double(statFrames) * 1000 : 0)
    }

    func setMapState(_ state: DashMapState) {
        lock.lock(); mapState = state; lock.unlock()
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
            // BGRA pool: we draw with CoreGraphics. Without this the pool hands out the encoder's
            // native biplanar YUV buffers, CGContext can't draw into them and no frame is ever encoded.
            encoderSpecification: nil, imageBufferAttributes: Self.bgraAttributes, compressedDataAllocator: nil,
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
        tickCount += 1
        // Parked: 2 fps is plenty and saves battery. Moving: 10 fps. A requested keyframe goes now.
        lock.lock(); let moving = mapState.speed > 1 || mapState.fix == nil; lock.unlock()
        if !forceKeyframe && !moving && tickCount % 5 != 0 { return }
        if session == nil { makeSession() }
        let drawStart = CFAbsoluteTimeGetCurrent()
        guard let session, let buffer = render() else { return }
        let drawTime = CFAbsoluteTimeGetCurrent() - drawStart
        lock.lock(); statFrames += 1; statDrawSeconds += drawTime; lock.unlock()
        let pts = CMTime(value: Int64(tickCount), timescale: 10)
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
            if self.encodedFrames == 1 || self.encodedFrames % 300 == 0 {
                self.log("[ENC] encoded frame #\(self.encodedFrames) (\(data.count)b, key=\(key))")
            }
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

    private static let bgraAttributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                         kCVPixelBufferCGImageCompatibilityKey: true,
                                         kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    private var renderFailures = 0

    private func render() -> CVPixelBuffer? {
        let pb = drawFrame()
        if pb == nil {
            renderFailures += 1
            if renderFailures == 1 || renderFailures % 50 == 0 { log("[ENC] !! could not draw the picture (#\(renderFailures))") }
        }
        return pb
    }

    private func drawFrame() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                     kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        if let pool = session.flatMap({ VTCompressionSessionGetPixelBufferPool($0) }) {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            if let made = pb, CVPixelBufferGetPixelFormatType(made) != kCVPixelFormatType_32BGRA { pb = nil }
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
        let state = appState, map = mapState
        lock.unlock()
        let now = Date()
        // Speed straight from the latest fix (no 1 s UI timer in between); "—" when GPS is lost.
        let fresh = map.fix != nil && now.timeIntervalSince(map.fixTime) < 5
        let speed: Double? = fresh ? map.speed * 3.6 : nil
        // Ease towards the extrapolated position and heading instead of jumping on every fix.
        if let target = map.position(at: now) {
            if let shown = shownRider, shown.distance(to: target) < 150 {
                shownRider = MKMapPoint(x: shown.x + (target.x - shown.x) * 0.35, y: shown.y + (target.y - shown.y) * 0.35)
                shownHeading = DashGeo.normalize(shownHeading + DashGeo.normalize(map.heading - shownHeading) * 0.3)
            } else {
                shownRider = target; shownHeading = map.heading
            }
        } else {
            shownRider = nil
        }
        let frames = encodedFrames
        if encodedFrames == 0 && frameIndex == 0 { log("[ENC] drawing \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) BGRA") }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        DashPicture.draw(in: CGRect(x: 0, y: 0, width: width, height: height), speedKmh: speed, state: state,
                         map: map, rider: shownRider, heading: shownHeading, now: now, frames: frames)
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

/// The dash picture: a moving, heading-up map on the left and the next manoeuvre, speed and clock on
/// the right, laid out for the 125X window (nothing readable below y≈326, nor below y≈284 right of
/// x≈676, on the 800×416 design size).
enum DashPicture {
    static let mapArea = CGRect(x: 0, y: 0, width: 500, height: 326)
    /// The rider sits low in the map so most of it shows what is ahead.
    static let riderAnchor = CGPoint(x: 250, y: 236)

    static func draw(in rect: CGRect, speedKmh: Double?, state: String, map: DashMapState, rider: MKMapPoint?,
                     heading: Double, now: Date, frames: Int) {
        let s = rect.height / 416
        UIColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 1).setFill(); UIRectFill(rect)
        let gold = UIColor(red: 1, green: 0.62, blue: 0.16, alpha: 1)
        let muted = UIColor(white: 0.62, alpha: 1)

        @discardableResult
        func text(_ str: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: UIColor, bold: Bool = false) -> CGSize {
            let font = UIFont.systemFont(ofSize: size * s, weight: bold ? .heavy : .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            (str as NSString).draw(at: CGPoint(x: x * s, y: y * s), withAttributes: attrs)
            return (str as NSString).size(withAttributes: attrs)
        }

        drawMap(map, rider: rider, heading: heading, scale: s, gold: gold, muted: muted)

        // Right panel.
        let speedText = speedKmh.map { String(Int($0.rounded())) } ?? "—"
        let clock = DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .short)
        if let nav = map.nav {
            if let arrow = UIImage(systemName: nav.turn.symbol,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 80 * s, weight: .bold)) {
                let img = arrow.withTintColor(nav.turn == .arrive ? gold : .white, renderingMode: .alwaysOriginal)
                let box = CGRect(x: 515 * s, y: 18 * s, width: 100 * s, height: 100 * s)
                let fit = min(box.width / img.size.width, box.height / img.size.height)
                let size = CGSize(width: img.size.width * fit, height: img.size.height * fit)
                img.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
            }
            let arrived = nav.turn == .arrive && nav.distance <= 0
            if !arrived { text(formatDistance(nav.distance), 625, 38, 44, .white, bold: true) }
            let font = UIFont.systemFont(ofSize: 21 * s, weight: .semibold)
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            (nav.instruction as NSString).draw(
                with: CGRect(x: 515 * s, y: 128 * s, width: 275 * s, height: 80 * s),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: font, .foregroundColor: UIColor.white, .paragraphStyle: style], context: nil)
            if !arrived {
                text("Meta \(formatDistance(nav.remaining))", 515, 214, 18, muted)
            }
            // Speed and clock: left of x≈676 below y≈284 (the dash strip covers the right corner).
            let w = text(speedText, 515, 236, 56, .white, bold: true).width / s
            text("km/h", 515 + w + 8, 266, 18, muted)
            text(clock, 515, 300, 20, gold, bold: true)
        } else {
            let w = text(speedText, 515, 24, 110, .white, bold: true).width / s
            text("km/h", 515 + w + 10, 104, 22, muted)
            text(clock, 515, 160, 34, gold, bold: true)
            text("Sin destino", 515, 222, 18, muted)
        }

        // Status (small, bottom-left of the map, above the dash strip).
        let status = "RideScreen iOS · \(state) · \(frames) img" + (map.note.isEmpty ? "" : " · \(map.note)")
        let font = UIFont.systemFont(ofSize: 12 * s, weight: .medium)
        let size = (status as NSString).size(withAttributes: [.font: font])
        UIColor(white: 0, alpha: 0.55).setFill()
        UIBezierPath(roundedRect: CGRect(x: 6 * s, y: 302 * s, width: size.width + 12 * s, height: size.height + 4 * s),
                     cornerRadius: 6 * s).fill()
        (status as NSString).draw(at: CGPoint(x: 12 * s, y: 304 * s), withAttributes: [.font: font, .foregroundColor: muted])
    }

    /// Screen position (design units × scale) of a map point, heading-up around the rider.
    static func project(_ p: MKMapPoint, rider: MKMapPoint, heading: Double, pixelsPerMapPoint k: Double,
                        anchor: CGPoint) -> CGPoint {
        let dx = (p.x - rider.x) * k, dy = (p.y - rider.y) * k
        let t = -heading * .pi / 180  // rotate the map against the heading so the heading points up
        return CGPoint(x: anchor.x + CGFloat(dx * cos(t) - dy * sin(t)),
                       y: anchor.y + CGFloat(dx * sin(t) + dy * cos(t)))
    }

    private static func drawMap(_ map: DashMapState, rider: MKMapPoint?, heading: Double, scale s: CGFloat,
                                gold: UIColor, muted: UIColor) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let area = CGRect(x: mapArea.minX * s, y: mapArea.minY * s, width: mapArea.width * s, height: mapArea.height * s)
        UIColor(white: 0.1, alpha: 1).setFill(); UIRectFill(area)
        let anchor = CGPoint(x: riderAnchor.x * s, y: riderAnchor.y * s)
        guard let rider else {
            (map.note as NSString).draw(at: CGPoint(x: 24 * s, y: 140 * s),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 20 * s, weight: .semibold),
                                                         .foregroundColor: muted])
            return
        }
        let ppm = MKMapPointsPerMeterAtLatitude(rider.coordinate.latitude)
        let k = Double(area.width) / (map.viewMeters * ppm)
        ctx.saveGState()
        ctx.clip(to: area)
        if let image = map.image, !map.imageRect.isNull {
            ctx.saveGState()
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.rotate(by: CGFloat(-heading * .pi / 180))
            ctx.scaleBy(x: CGFloat(k), y: CGFloat(k))
            let r = map.imageRect
            ctx.interpolationQuality = .low
            UIImage(cgImage: image).draw(in: CGRect(x: r.minX - rider.x, y: r.minY - rider.y, width: r.width, height: r.height))
            ctx.restoreGState()
        }
        // No map around the rider (no coverage, e.g. after a tunnel): say so; route and arrow still work.
        let covered = map.image != nil && !map.imageRect.isNull
            && hypot(rider.x - map.imageRect.midX, rider.y - map.imageRect.midY) < map.imageRect.width * 0.4
        if !covered {
            ("Sin mapa · reintentando" as NSString).draw(
                at: CGPoint(x: 24 * s, y: 24 * s),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18 * s, weight: .semibold), .foregroundColor: muted])
        }
        // Route.
        if map.route.count > 1 {
            let path = UIBezierPath()
            for (i, p) in map.route.enumerated() {
                let q = project(p, rider: rider, heading: heading, pixelsPerMapPoint: k, anchor: anchor)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            path.lineJoinStyle = .round; path.lineCapStyle = .round
            UIColor(white: 0, alpha: 0.5).setStroke(); path.lineWidth = 11 * s; path.stroke()
            UIColor(red: 0.25, green: 0.6, blue: 1, alpha: 1).setStroke(); path.lineWidth = 7 * s; path.stroke()
        }
        // Rider arrow, always pointing up (heading-up map).
        let a = UIBezierPath()
        a.move(to: CGPoint(x: anchor.x, y: anchor.y - 18 * s))
        a.addLine(to: CGPoint(x: anchor.x + 13 * s, y: anchor.y + 14 * s))
        a.addLine(to: CGPoint(x: anchor.x, y: anchor.y + 7 * s))
        a.addLine(to: CGPoint(x: anchor.x - 13 * s, y: anchor.y + 14 * s))
        a.close()
        gold.setFill(); a.fill()
        UIColor.white.setStroke(); a.lineWidth = 2.5 * s; a.stroke()
        // North marker: a small "N" on the edge, so a rotated map stays readable.
        let north = project(MKMapPoint(x: rider.x, y: rider.y - 1e9), rider: rider, heading: heading,
                            pixelsPerMapPoint: 1, anchor: .zero)
        let len = max(1, hypot(north.x, north.y))
        let c = CGPoint(x: area.maxX - 26 * s + north.x / len * 14 * s, y: 26 * s + north.y / len * 14 * s)
        ("N" as NSString).draw(at: CGPoint(x: c.x - 6 * s, y: c.y - 9 * s),
                               withAttributes: [.font: UIFont.systemFont(ofSize: 15 * s, weight: .heavy), .foregroundColor: gold])
        ctx.restoreGState()
        UIColor(white: 0.25, alpha: 1).setFill()
        UIRectFill(CGRect(x: area.maxX, y: 0, width: 2 * s, height: area.height))
    }

    static func formatDistance(_ meters: Double) -> String {
        if meters < 1_000 { return "\(Int((meters / 10).rounded()) * 10) m" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1; f.maximumFractionDigits = 1
        return "\(f.string(from: NSNumber(value: meters / 1_000)) ?? "?") km"
    }
}
