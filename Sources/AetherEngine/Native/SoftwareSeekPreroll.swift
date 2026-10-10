import Foundation

/// A software decoder must rebuild its reference frames after a seek before the clock
/// advances. Let it queue a short runway, but release a full renderer immediately:
/// at rate zero that queue cannot drain, so waiting for more runway would deadlock.
enum SoftwareSeekPreroll {
    static let runwaySeconds = 0.15
    static let maximumHoldSeconds = 1.5

    static func shouldWait(target: Double, newestVideoPTS: Double?,
                           rendererReady: Bool, elapsed: Double) -> Bool {
        guard rendererReady, elapsed < maximumHoldSeconds else { return false }
        guard let newestVideoPTS, newestVideoPTS.isFinite else { return true }
        return newestVideoPTS - target < runwaySeconds
    }
}
