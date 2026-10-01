import XCTest
@testable import AetherEngine

final class VODSegmentCutterTests: XCTestCase {

    // 4 segments of 4s each, boundaries in ms (source TB 1/1000): starts 0,4,8,12 + end 16.
    private let fourSeg: [Int64] = [0, 4000, 8000, 12000, 16000]

    func testFirstKeyframeOpensBaseSegment() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        XCTAssertEqual(c.index(pts: 0, isKeyframe: true), 0)   // first IRAP stays in seg 0
    }

    func testNonKeyframesStayInCurrentSegment() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 1000, isKeyframe: false), 0)
        XCTAssertEqual(c.index(pts: 2000, isKeyframe: false), 0)
    }

    func testBoundaryKeyframeOpensNextSegment() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 4000, isKeyframe: true), 1)   // IRAP at 4s opens seg 1
        XCTAssertEqual(c.index(pts: 8000, isKeyframe: true), 2)
        XCTAssertEqual(c.index(pts: 12000, isKeyframe: true), 3)
    }

    /// The #92 fix: open-GOP RASL leading pictures arrive in decode order AFTER the CRA but carry a PTS
    /// BEFORE it. They must stay in the CRA's segment, not be re-routed to the previous one.
    func testRaslLeadingPicturesStayWithTheirKeyframe() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 4000, isKeyframe: true), 1)    // CRA opens seg 1
        XCTAssertEqual(c.index(pts: 3958, isKeyframe: false), 1)   // RASL, pts < CRA -> stays in seg 1
        XCTAssertEqual(c.index(pts: 3917, isKeyframe: false), 1)
        XCTAssertEqual(c.index(pts: 4083, isKeyframe: false), 1)   // trailing -> seg 1
    }

    /// GOP shorter than the segment: an intra-segment keyframe that has not reached the next boundary
    /// must NOT open a new segment.
    func testIntraSegmentKeyframeDoesNotCut() {
        let twoSeg: [Int64] = [0, 8000, 16000]   // 8s segments
        var c = VODSegmentCutter(sourceBoundaries: twoSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 4000, isKeyframe: true), 0)   // mid-segment IRAP stays in seg 0
        XCTAssertEqual(c.index(pts: 8000, isKeyframe: true), 1)   // boundary IRAP opens seg 1
    }

    func testBaseIndexOffsetForRestart() {
        let b: [Int64] = [264_000, 268_000, 272_000, 276_000]   // 3 segments: 264, 265, 266
        var c = VODSegmentCutter(sourceBoundaries: b, planAnchorPts: 0, baseIndex: 264)
        XCTAssertEqual(c.index(pts: 264_000, isKeyframe: true), 264)
        XCTAssertEqual(c.index(pts: 268_000, isKeyframe: true), 265)
        XCTAssertEqual(c.index(pts: 272_000, isKeyframe: true), 266)
    }

    func testSparseKeyframeJumpAdvancesMultiple() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 12000, isKeyframe: true), 3)   // skips 1,2 in one step
    }

    func testNeverAdvancesPastLastSegment() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        // Keyframes well past the final boundary clamp at the last segment (count-1 boundaries => seg 3).
        XCTAssertEqual(c.index(pts: 99_000, isKeyframe: true), 3)
        XCTAssertEqual(c.index(pts: 99_000, isKeyframe: true), 3)
    }

    func testNoptsKeyframeStaysPut() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: Int64.min, isKeyframe: true), 0)
    }

    /// AE#268: packets arrive with the producer's shift already subtracted, so they are on the item
    /// axis while the plan's boundaries are source PTS. On a source whose content starts at 1.48 s
    /// (every MPEG-TS), comparing the two directly put each cut a whole anchor late; on a plan whose
    /// boundaries ARE the source's IRAPs it never cut at all, because such a keyframe's item-axis pts
    /// is exactly one anchor below its own boundary.
    func testNonZeroPlanAnchorCutsOnTheItemAxis() {
        let anchor: Int64 = 1480
        let boundaries: [Int64] = [1480, 11480, 21480, 31480]   // IRAPs of a 10 s-segmented source
        var c = VODSegmentCutter(sourceBoundaries: boundaries, planAnchorPts: anchor, baseIndex: 0)
        XCTAssertEqual(c.index(pts: 0, isKeyframe: true), 0)
        XCTAssertEqual(c.index(pts: 9999, isKeyframe: false), 0)
        XCTAssertEqual(c.index(pts: 10_000, isKeyframe: true), 1)   // the source's own second IRAP
        XCTAssertEqual(c.index(pts: 20_000, isKeyframe: true), 2)
    }

    /// #368 contract: the producer's chunk-seam rebase feeds this cutter CONTINUOUS item-axis dts,
    /// so a seam advances at most one boundary like any other packet. A raw 2^33 wrap fed directly
    /// (what the rebase prevents) saturates at the tail clamp in a single call — the field failure.
    func testRebasedChunkSeamAdvancesOneBoundaryWhileRawWrapSaturates() {
        var rebased = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = rebased.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(rebased.index(pts: 3960, isKeyframe: false), 0)   // last pre-seam frame
        XCTAssertEqual(rebased.index(pts: 4000, isKeyframe: true), 1)    // seam IRAP, rebased dts
        XCTAssertEqual(rebased.index(pts: 8000, isKeyframe: true), 2)

        var raw = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = raw.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(raw.index(pts: 8_589_934_592, isKeyframe: true), 3)   // 2^33: tail clamp
    }

    /// A restart whose gate overshot its target still opens at `baseIndex`: the producer rebases the
    /// gating keyframe onto the segment's advertised start, and the cutter sees exactly that.
    func testRestartGateOvershootStillOpensBaseIndex() {
        let anchor: Int64 = 1480
        let boundaries: [Int64] = [641_480, 651_480, 661_480, 671_480]
        var c = VODSegmentCutter(sourceBoundaries: boundaries, planAnchorPts: anchor, baseIndex: 64)
        XCTAssertEqual(c.index(pts: 640_000, isKeyframe: true), 64)   // rebased onto seg 64's start
        XCTAssertEqual(c.index(pts: 650_000, isKeyframe: true), 65)
    }

    // MARK: - Plan time domain (engine lab: Matroska Cues are presentation times)

    /// Matroska plan (Cue times = keyframe PTS) and B-frame keyframes whose DTS sits two frames
    /// (83 ms at 24 fps) below their PTS. Gating on the DTS never reached a boundary, so every cut
    /// slipped a GOP and the final plan segment never opened. The Sintel 1080p remux in the engine
    /// lab is the field shape: keyframes at 8.042 / 18.459 / ... / 53.084, DTS 83 ms earlier.
    func testMatroskaPlanGatesOnPresentationTime() {
        let cues: [Int64] = [0, 8042, 18459, 53084, 60875]
        var c = VODSegmentCutter(sourceBoundaries: cues, planAnchorPts: 0, baseIndex: 0)
        func key(_ pts: Int64) -> Int {
            c.index(pts: VODSegmentCutter.gateTimestamp(pts: pts, dts: pts - 83, planIsPresentationTime: true),
                    isKeyframe: true)
        }
        XCTAssertEqual(key(0), 0)
        XCTAssertEqual(key(8042), 1)
        XCTAssertEqual(key(18459), 2)
        XCTAssertEqual(key(53084), 3, "the final plan segment must open on its own keyframe")
    }

    /// The pre-fix behaviour, pinned so the failure mode stays documented: the same packets gated on
    /// DTS against a presentation-time plan stay one segment behind and never open the last one.
    func testDecodeTimeAgainstPresentationPlanSlipsAGOP() {
        let cues: [Int64] = [0, 8042, 18459, 53084, 60875]
        var c = VODSegmentCutter(sourceBoundaries: cues, planAnchorPts: 0, baseIndex: 0)
        let dts = { (pts: Int64) in VODSegmentCutter.gateTimestamp(pts: pts, dts: pts - 83, planIsPresentationTime: false) }
        XCTAssertEqual(c.index(pts: dts(8042), isKeyframe: true), 0)
        XCTAssertEqual(c.index(pts: dts(18459), isKeyframe: true), 1)
        XCTAssertEqual(c.index(pts: dts(53084), isKeyframe: true), 2)
    }

    /// mov/mp4 plans are decode times (#358): the gate keeps reading the DTS there.
    func testMovPlanStillGatesOnDecodeTime() {
        XCTAssertEqual(VODSegmentCutter.gateTimestamp(pts: 4083, dts: 4000, planIsPresentationTime: false), 4000)
        XCTAssertEqual(VODSegmentCutter.gateTimestamp(pts: 4083, dts: Int64.min, planIsPresentationTime: false), 4083)
        XCTAssertEqual(VODSegmentCutter.gateTimestamp(pts: Int64.min, dts: 4000, planIsPresentationTime: true), 4000)
    }
}
