import XCTest
@testable import AetherEngine

/// Engine lab (`g-vp9`, `g-av1-svt`, `ff-multisub`, ... 10 % seek): on the software route the demuxer
/// reads ahead to end of file well before the clock gets there. A backward seek landing while the loop
/// drained that tail used to fall through to end-of-media, so the clock parked ~2 s after the landing
/// and the session finished with most of the file still to play.
final class SoftwareEndOfMediaSeekTests: XCTestCase {

    func testEndOfFileWithoutASeekIsEndOfMedia() {
        XCTAssertTrue(SoftwarePlaybackHost.endOfMediaStands(generationAtRead: 7, generationNow: 7))
    }

    func testSeekDuringTheTailDrainKeepsTheLoopRunning() {
        XCTAssertFalse(SoftwarePlaybackHost.endOfMediaStands(generationAtRead: 7, generationNow: 8))
    }

    // MARK: - Published -> source axis (engine lab: broadcast TS with a non-zero PTS origin)

    /// `ff-h264-paff-ts`: PTS start at 23021.8 s. A seek to published 7.56 s must reposition the
    /// demuxer and anchor the synchronizer at source 23029.36 s, not at absolute 7.56 s.
    func testSeekTargetMovesOntoTheSourceAxis() {
        XCTAssertEqual(SoftwarePlaybackHost.sourceSeconds(forPublished: 7.56, sessionZero: 23021.8),
                       23029.36, accuracy: 1e-9)
    }

    func testZeroBasedSourcesAreUnchanged() {
        XCTAssertEqual(SoftwarePlaybackHost.sourceSeconds(forPublished: 12.5, sessionZero: 0), 12.5)
        XCTAssertEqual(SoftwarePlaybackHost.sourceSeconds(forPublished: 12.5, sessionZero: .nan), 12.5)
    }
}
