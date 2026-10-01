import XCTest
@testable import AetherEngine

/// Engine lab (`q-range-ignored*` rows): an origin that answers ranged requests with 200 and the
/// whole body is detected on the open's first, bounded request and reopened as a sequential origin,
/// instead of spending the reconnect ladder on refusals that can only repeat (45 s+ hang at open).
final class RangeIgnoringOriginTests: XCTestCase {

    func testBoundedRequestAnsweredInFullIsRangeIgnoring() {
        // bytes=0-33554431 answered 200 with a 66 MB body.
        XCTAssertTrue(AVIOReader.responseIgnoredBoundedRange(
            status: 200, expectedContentLength: 66_720_068, requestedRangeEnd: 33_554_431))
    }

    func testPartialContentIsNotRangeIgnoring() {
        XCTAssertFalse(AVIOReader.responseIgnoredBoundedRange(
            status: 206, expectedContentLength: 33_554_432, requestedRangeEnd: 33_554_431))
    }

    func testFileShorterThanTheSpanMayAnswerInFull() {
        // A 10 MB file asked for 32 MB: a 200 with the whole (shorter) body is legitimate.
        XCTAssertFalse(AVIOReader.responseIgnoredBoundedRange(
            status: 200, expectedContentLength: 10_485_760, requestedRangeEnd: 33_554_431))
    }

    func testUnknownLengthOrUnboundedRequestIsNotEvidence() {
        XCTAssertFalse(AVIOReader.responseIgnoredBoundedRange(
            status: 200, expectedContentLength: -1, requestedRangeEnd: 33_554_431))
        XCTAssertFalse(AVIOReader.responseIgnoredBoundedRange(
            status: 200, expectedContentLength: 66_720_068, requestedRangeEnd: nil))
    }

    func testTypedFailureReopensURLSourcesSequentiallyOnce() {
        let failure: Error = AVIOReaderError.originIgnoresRange
        XCTAssertTrue(RangeIgnoringOrigins.shouldReopenSequentially(
            failure: failure, isCustomSource: false, isLive: false, alreadySequential: false))
        // Already sequential: no second reopen (no loop).
        XCTAssertFalse(RangeIgnoringOrigins.shouldReopenSequentially(
            failure: failure, isCustomSource: false, isLive: false, alreadySequential: true))
        // Custom readers have no URL to reopen; live has its own reconnect contract.
        XCTAssertFalse(RangeIgnoringOrigins.shouldReopenSequentially(
            failure: failure, isCustomSource: true, isLive: false, alreadySequential: false))
        XCTAssertFalse(RangeIgnoringOrigins.shouldReopenSequentially(
            failure: failure, isCustomSource: false, isLive: true, alreadySequential: false))
        XCTAssertFalse(RangeIgnoringOrigins.shouldReopenSequentially(
            failure: AVIOReaderError.httpStatus(403), isCustomSource: false, isLive: false, alreadySequential: false))
    }

    func testRegistryRemembersOriginForTheNextLoad() {
        let url = URL(string: "http://127.0.0.1:1/q/range-ignored/test/\(UUID().uuidString).mp4")!
        XCTAssertFalse(RangeIgnoringOrigins.shouldRetrySequentially(url: url, isLive: false, alreadySequential: false))
        RangeIgnoringOrigins.mark(url)
        XCTAssertTrue(RangeIgnoringOrigins.shouldRetrySequentially(url: url, isLive: false, alreadySequential: false))
        XCTAssertFalse(RangeIgnoringOrigins.shouldRetrySequentially(url: url, isLive: true, alreadySequential: false))
        XCTAssertFalse(RangeIgnoringOrigins.shouldRetrySequentially(
            url: URL(fileURLWithPath: "/tmp/x.mp4"), isLive: false, alreadySequential: false))
        RangeIgnoringOrigins.remove(url)
    }
}
