import Testing
import Foundation
@testable import AetherEngine

/// AE#374: how long the software clock may keep running after the producer is done.
///
/// The defect this policy closes is not a crash: the synchronizer kept its rate past end of media, so
/// `currentTime` walked past `duration` (measured: 20.13 s published on a 12.0 s source) and the 1 Hz
/// `[SWDiag]` line reported an `aLead` falling at exactly 1.00 per second on a session that had simply
/// finished. Both halves read as a live defect to anyone holding the log.
@Suite("SoftwareEndOfMediaClock")
struct SoftwareEndOfMediaClockTests {

    @Test("Audio already consumed parks the clock immediately")
    func consumedTailParksNow() {
        // The normal VOD shape: the drain that precedes end of media has walked the clock to the last
        // video frame, so nothing is left ahead of it.
        #expect(SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: 11.98, lastAudioPts: 11.98) == 0)
        #expect(SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: 12.40, lastAudioPts: 11.98) == 0)
    }

    @Test("Queued audio ahead of the playhead defers the park by exactly that much")
    func queuedTailDefersPark() {
        let tail = SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: 11.87, lastAudioPts: 11.99)
        #expect(abs(tail - 0.12) < 0.0001)
    }

    @Test("A source without usable audio timing parks immediately rather than never")
    func unusableAudioPtsParksNow() {
        #expect(SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: 5, lastAudioPts: .nan) == 0)
        #expect(SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: 5, lastAudioPts: .infinity) == 0)
        #expect(SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: .nan, lastAudioPts: 5) == 0)
    }

    @Test("A broken PTS cannot buy an unbounded runway on a finished session")
    func tailIsClamped() {
        let tail = SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: 10, lastAudioPts: 90_000)
        #expect(tail == SoftwareEndOfMediaClock.maxTailPlayoutSeconds)
    }
    @Test("Video-only codec drain gets time to present its final pictures")
    func queuedVideoTailDefersPark() {
        let tail = SoftwareEndOfMediaClock.tailPlayoutSeconds(
            clockSeconds: 0.9, lastAudioPts: .nan, lastVideoPts: 1.034)
        #expect(abs(tail - 0.134) < 0.0001)
    }

    @Test("The later of decoded audio and video controls the terminal tail")
    func latestTrackWins() {
        #expect(SoftwareEndOfMediaClock.tailPlayoutSeconds(
            clockSeconds: 1, lastAudioPts: 1.1, lastVideoPts: 1.25) == 0.25)
        #expect(SoftwareEndOfMediaClock.tailPlayoutSeconds(
            clockSeconds: 1, lastAudioPts: 1.5, lastVideoPts: 1.25) == 0.5)
    }

    @Test("Completion publishes the decoded frontier rather than the stale timer tick")
    func finalClockUsesDecodedFrontier() {
        #expect(SoftwareEndOfMediaClock.finalClockSeconds(
            clockSeconds: 0.751, lastAudioPts: .nan, lastVideoPts: 1.034) == 1.034)
        #expect(SoftwareEndOfMediaClock.finalClockSeconds(
            clockSeconds: 1.2, lastAudioPts: .nan, lastVideoPts: 1.034) == 1.034)
        #expect(SoftwareEndOfMediaClock.finalClockSeconds(
            clockSeconds: 1.2, lastAudioPts: .nan, lastVideoPts: .nan) == 1.2)
        #expect(SoftwareEndOfMediaClock.finalClockSeconds(
            clockSeconds: 1.2, lastAudioPts: .nan, lastVideoPts: 90_000) == 6.2)
    }

    @Test("A delayed old EOF cannot retire a replacement pump")
    func retirementBelongsToTheFinishingPump() {
        let finishedPump: UInt64 = 8
        #expect(SoftwareEndOfMediaClock.canRetirePump(
            finishing: finishedPump, active: finishedPump) == true)
        // A seek already started pump 9 before pump 8's main-actor callback ran.
        #expect(SoftwareEndOfMediaClock.canRetirePump(
            finishing: finishedPump, active: 9) == false)
    }

}
