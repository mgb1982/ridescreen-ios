import CoreMedia
import OSLog
import ReplayKit

/// Receives system-approved screen samples. The bike transport is added in a later milestone.
final class SampleHandler: RPBroadcastSampleHandler {
    private let logger = Logger(subsystem: "com.mgb1982.RideScreenIOS.BroadcastExtension", category: "ScreenCapture")
    private var videoSampleCount = 0
    private var lastReport = Date()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        videoSampleCount = 0
        lastReport = Date()
        logger.info("ReplayKit broadcast started")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, CMSampleBufferIsValid(sampleBuffer) else { return }
        videoSampleCount += 1
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 10 else { return }
        logger.info("ReplayKit capture active; video samples in interval: \(self.videoSampleCount)")
        videoSampleCount = 0
        lastReport = now
    }

    override func broadcastFinished() {
        logger.info("ReplayKit broadcast finished")
    }

    override func broadcastPaused() {
        logger.info("ReplayKit broadcast paused")
    }

    override func broadcastResumed() {
        logger.info("ReplayKit broadcast resumed")
    }
}
