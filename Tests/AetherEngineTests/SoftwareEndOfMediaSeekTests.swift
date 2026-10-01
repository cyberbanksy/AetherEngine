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
}
