import XCTest
import AetherLibavutil
@testable import AetherEngine

/// Engine lab `g-hdr10-hevc`: an HDR10 MKV whose container carries no Colour element while the HEVC
/// SPS VUI says PQ / BT.2020. Read as SDR, the item failed with CoreMedia -12927.
final class BitstreamColorRecoveryTests: XCTestCase {
    typealias S = BitstreamColorRecovery.Signal

    func testUnspecifiedContainerAdoptsTheVUI() {
        let container = S(transfer: AVCOL_TRC_UNSPECIFIED, primaries: AVCOL_PRI_UNSPECIFIED, matrix: AVCOL_SPC_BT2020_NCL)
        let vui = S(transfer: AVCOL_TRC_SMPTE2084, primaries: AVCOL_PRI_BT2020, matrix: AVCOL_SPC_BT2020_NCL)
        let out = BitstreamColorRecovery.merged(container: container, bitstream: vui)
        XCTAssertEqual(out.transfer, AVCOL_TRC_SMPTE2084)
        XCTAssertEqual(out.primaries, AVCOL_PRI_BT2020)
        XCTAssertEqual(out.matrix, AVCOL_SPC_BT2020_NCL)
    }

    func testContainerStatementAlwaysWins() {
        // An SDR-tagged container is a statement, not an omission: the VUI does not override it.
        let container = S(transfer: AVCOL_TRC_BT709, primaries: AVCOL_PRI_BT709, matrix: AVCOL_SPC_BT709)
        let vui = S(transfer: AVCOL_TRC_SMPTE2084, primaries: AVCOL_PRI_BT2020, matrix: AVCOL_SPC_BT2020_NCL)
        XCTAssertEqual(BitstreamColorRecovery.merged(container: container, bitstream: vui), container)
    }

    func testReservedValuesCountAsUnspecified() {
        let container = S(transfer: AVCOL_TRC_RESERVED, primaries: AVCOL_PRI_RESERVED0, matrix: AVCOL_SPC_RESERVED)
        let vui = S(transfer: AVCOL_TRC_ARIB_STD_B67, primaries: AVCOL_PRI_BT2020, matrix: AVCOL_SPC_BT2020_NCL)
        XCTAssertEqual(BitstreamColorRecovery.merged(container: container, bitstream: vui), vui)
    }

    func testEmptyVUILeavesTheContainerAlone() {
        // DV Profile 5 commonly ships an empty VUI: nothing to adopt, nothing changes.
        let container = S(transfer: AVCOL_TRC_UNSPECIFIED, primaries: AVCOL_PRI_UNSPECIFIED, matrix: AVCOL_SPC_UNSPECIFIED)
        XCTAssertEqual(BitstreamColorRecovery.merged(container: container, bitstream: S()), container)
    }
}
