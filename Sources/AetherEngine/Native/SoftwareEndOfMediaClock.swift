import Foundation

/// AE#374: what the software path's master clock does once the producer is done.
///
/// `AVSampleBufferRenderSynchronizer` is the master clock for the whole software session, and nothing
/// used to stop it at end of media: the demux loop drained, published `.ended` and parked its own
/// threads, but left the synchronizer at rate 1. So `currentTime` kept walking past `duration` for as
/// long as the host held the session, and the 1 Hz `[SWDiag]` line kept reporting an `aLead` falling at
/// exactly 1.00 per second, which is the shape of a session drifting rather than of one that finished.
/// A downstream host read those lines as evidence of a clock defect, and so did this repo. The native
/// path parks on its final sample; this is what makes the two agree.
enum SoftwareEndOfMediaClock {

    /// Longest the clock may keep running after the last packet, so a queued audio tail plays out
    /// instead of being cut off. Bounded because the anchor is a stream value: a broken PTS must not
    /// buy an unbounded runway on a session that is already over.
    static let maxTailPlayoutSeconds: TimeInterval = 5.0

    static func canRetirePump(finishing: UInt64, active: UInt64) -> Bool {
        finishing == active
    }

    static func finalClockSeconds(clockSeconds: Double, lastAudioPts: Double,
                                  lastVideoPts: Double) -> Double {
        guard let frontier = [lastAudioPts, lastVideoPts].filter({ $0.isFinite }).max() else { return clockSeconds }
        return clockSeconds.isFinite ? min(frontier, clockSeconds + maxTailPlayoutSeconds) : frontier
    }

    /// Seconds to let the clock run before parking it. Decoder EOF draining can produce
    /// video after the last audio, or on a video-only source, so use the later valid frontier.
    static func tailPlayoutSeconds(clockSeconds: Double, lastAudioPts: Double,
                                   lastVideoPts: Double = .nan) -> TimeInterval {
        guard clockSeconds.isFinite else { return 0 }
        let frontiers = [lastAudioPts, lastVideoPts].filter { $0.isFinite }
        guard let lastPTS = frontiers.max() else { return 0 }
        let remaining = lastPTS - clockSeconds
        guard remaining > 0 else { return 0 }
        return min(remaining, maxTailPlayoutSeconds)
    }
}
