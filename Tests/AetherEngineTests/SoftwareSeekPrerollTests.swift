import Testing
@testable import AetherEngine

struct SoftwareSeekPrerollTests {
    @Test func slowDecoderDoesNotStartClockOnAnEmptyQueue() {
        #expect(SoftwareSeekPreroll.shouldWait(target: 20, newestVideoPTS: nil,
                                             rendererReady: true, elapsed: 0.2) == true)
        #expect(SoftwareSeekPreroll.shouldWait(target: 20, newestVideoPTS: 19.9,
                                             rendererReady: true, elapsed: 0.2) == true)
    }

    @Test func decodedRunwayReleasesTheClock() {
        #expect(SoftwareSeekPreroll.shouldWait(target: 20, newestVideoPTS: 20.2,
                                             rendererReady: true, elapsed: 0.2) == false)
    }

    @Test func fullRendererMustRunToDrainEvenWithoutEnoughRunway() {
        #expect(SoftwareSeekPreroll.shouldWait(target: 20, newestVideoPTS: 20.03,
                                             rendererReady: false, elapsed: 0.2) == false)
    }

    @Test func missingOrCorruptVideoHasABoundedHold() {
        #expect(SoftwareSeekPreroll.shouldWait(target: 20, newestVideoPTS: nil,
                                             rendererReady: true, elapsed: 1.5) == false)
        #expect(SoftwareSeekPreroll.shouldWait(target: 20, newestVideoPTS: .nan,
                                             rendererReady: true, elapsed: 1.5) == false)
    }
    @Test func eofCallbackKeepsTheReadGenerationAcrossDecoderDrainAndActorHop() {
        let generationAtRead: UInt64 = 41
        // Decoder draining or the queued main-actor callback can span a reposition.
        let generationAfterDrain: UInt64 = 42
        #expect(SoftwarePlaybackHost.endOfMediaStands(
            generationAtRead: generationAtRead, generationNow: generationAfterDrain) == false)
        #expect(SoftwarePlaybackHost.endOfMediaStands(
            generationAtRead: generationAtRead, generationNow: generationAtRead) == true)
    }

}
