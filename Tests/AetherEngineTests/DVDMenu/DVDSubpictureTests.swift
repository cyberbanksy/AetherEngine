import Foundation
import Testing
@testable import AetherEngine

/// The clean-room SPU decoder (dvd.sourceforge.net spu.html), the highlight renderer, the PS scanner,
/// and the VOB-set sector mapping.
struct DVDSubpictureTests {
    /// Packs run-length codes MSB-first into nibbles; each line is byte-aligned.
    private func rle(_ lines: [[(count: Int, code: UInt8)]]) -> [UInt8] {
        var nibbles: [UInt8] = []
        for line in lines {
            for (n, c) in line {
                let v = UInt16(n) << 2 | UInt16(c)
                let width = n == 0 ? 4 : n < 4 ? 1 : n < 16 ? 2 : n < 64 ? 3 : 4
                for k in (0..<width).reversed() { nibbles.append(UInt8((v >> (4 * UInt16(k))) & 0xF)) }
            }
            if nibbles.count % 2 == 1 { nibbles.append(0) }
        }
        return stride(from: 0, to: nibbles.count, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] }
    }

    /// A unit with a w x h area at (x, y), top / bottom fields, colours e2 e1 p b = 3 2 1 0 and the given contrast.
    private func unit(x: Int, y: Int, top: [[(count: Int, code: UInt8)]], bottom: [[(count: Int, code: UInt8)]],
                      width: Int, contrast: UInt16 = 0xFFF0, stopDelay: UInt16? = nil) -> [UInt8] {
        let t = rle(top), b = rle(bottom)
        let height = top.count + bottom.count
        let topOff = 4, botOff = 4 + t.count
        var dcsq: [UInt8] = []
        let dcsqAt = 4 + t.count + b.count
        let x1 = x + width - 1, y1 = y + height - 1
        var cmds: [UInt8] = [0x00, 0x03, 0x32, 0x10, 0x04, UInt8(contrast >> 8), UInt8(contrast & 0xFF),
                             0x05, UInt8(x >> 4), UInt8((x & 0xF) << 4 | x1 >> 8), UInt8(x1 & 0xFF),
                             UInt8(y >> 4), UInt8((y & 0xF) << 4 | y1 >> 8), UInt8(y1 & 0xFF),
                             0x06, UInt8(topOff >> 8), UInt8(topOff & 0xFF), UInt8(botOff >> 8), UInt8(botOff & 0xFF), 0xFF]
        if let stopDelay {
            let second = dcsqAt + 4 + cmds.count
            dcsq = [0, 0, UInt8(second >> 8), UInt8(second & 0xFF)] + cmds
            dcsq += [UInt8(stopDelay >> 8), UInt8(stopDelay & 0xFF), UInt8(second >> 8), UInt8(second & 0xFF), 0x02, 0xFF]
            cmds = []
        } else {
            dcsq = [0, 0, UInt8(dcsqAt >> 8), UInt8(dcsqAt & 0xFF)] + cmds
        }
        let size = dcsqAt + dcsq.count
        return [UInt8(size >> 8), UInt8(size & 0xFF), UInt8(dcsqAt >> 8), UInt8(dcsqAt & 0xFF)] + t + b + dcsq
    }

    @Test func decodesControlSequenceAndInterlacedRLE() throws {
        // 8 x 4 area: top field rows 0, 2; bottom rows 1, 3. Exercises 4-, 8-, 12- and 16-bit codes.
        let raw = unit(x: 10, y: 20,
                       top: [[(3, 1), (5, 2)], [(0, 3)]],
                       bottom: [[(8, 0)], [(2, 1), (0, 2)]], width: 8, stopDelay: 175)
        let u = try #require(DVDSubpictureUnit.parse(raw))
        #expect(u.isForced)
        #expect(u.colors == [0, 1, 2, 3])
        #expect(u.contrast == [0, 0xF, 0xF, 0xF])
        #expect(u.displayArea.map { [$0.x0, $0.y0, $0.x1, $0.y1] } == [10, 20, 17, 23])
        #expect(u.stopDelay90k == UInt32(175 * 1024))
        let bm = try #require(u.decodePixels())
        #expect(bm.width == 8 && bm.height == 4)
        #expect(Array(bm.codes[0..<8]) == [1, 1, 1, 2, 2, 2, 2, 2])
        #expect(Array(bm.codes[8..<16]) == Array(repeating: 0, count: 8))
        #expect(Array(bm.codes[16..<24]) == Array(repeating: 3, count: 8))
        #expect(Array(bm.codes[24..<32]) == [1, 1, 2, 2, 2, 2, 2, 2])
        #expect(bm.code(atX: 10, y: 20) == 1 && bm.code(atX: 13, y: 20) == 2 && bm.code(atX: 9, y: 20) == nil)
    }

    @Test func longRunsUse12And16BitCodes() throws {
        let raw = unit(x: 0, y: 0, top: [[(20, 1), (70, 2), (0, 3)]], bottom: [[(0, 0)]], width: 100)
        let bm = try #require(DVDSubpictureUnit.parse(raw)?.decodePixels())
        #expect(bm.codes[0..<20].allSatisfy { $0 == 1 })
        #expect(bm.codes[20..<90].allSatisfy { $0 == 2 })
        #expect(bm.codes[90..<100].allSatisfy { $0 == 3 })
        #expect(bm.codes[100..<200].allSatisfy { $0 == 0 })
    }

    @Test func rejectsTruncatedUnits() {
        #expect(DVDSubpictureUnit.parse([0x00, 0x40, 0x00, 0x10]) == nil)
        #expect(DVDSubpictureUnit.parse([]) == nil)
    }

    @Test func highlightRecoloursOnlyTheButtonRectangle() throws {
        let raw = unit(x: 0, y: 0, top: [[(0, 1)], [(0, 1)]], bottom: [[(0, 1)], [(0, 1)]], width: 40)
        let u = try #require(DVDSubpictureUnit.parse(raw))
        let bm = try #require(u.decodePixels())
        // Palette: 0 white, 1 yellow, 2 red. SPU colours map pattern -> 0 (white); scheme: selection pattern
        // -> 1 (yellow), action pattern -> 2 (red), both opaque.
        let palette: [UInt32] = [0xEB8080, 0xD29210, 0x52F05A] + Array(repeating: 0x108080, count: 13)
        var raw18 = [UInt8](repeating: 0, count: 18)
        raw18[0] = 0x40; raw18[1] = 0x00; raw18[2] = 19            // x 0-19, scheme 1
        raw18[3] = 0; raw18[4] = 0; raw18[5] = 3                     // y 0-3
        let button = try #require(DVDButton(number: 1, raw: raw18))
        let scheme = DVDButtonColors(raw: [0x00, 0x10, 0x00, 0xF0, 0x00, 0x20, 0x00, 0xF0])
        let sel = DVDHighlightRenderer.renderRGBA(bitmap: bm, spuColors: [0, 0, 0, 0], spuContrast: [0, 15, 0, 0],
                                                  palette: palette, button: button, scheme: scheme, state: .selected)
        func px(_ p: [UInt8], _ x: Int) -> [UInt8] { Array(p[x * 4 ..< x * 4 + 4]) }
        #expect(sel.visible)
        let yellow = px(sel.pixels, 5), white = px(sel.pixels, 30)
        #expect(yellow[0] > 200 && yellow[1] > 200 && yellow[2] < 60 && yellow[3] == 255)
        #expect(white[0] > 230 && white[1] > 230 && white[2] > 230)
        let act = DVDHighlightRenderer.renderRGBA(bitmap: bm, spuColors: [0, 0, 0, 0], spuContrast: [0, 15, 0, 0],
                                                  palette: palette, button: button, scheme: scheme, state: .activated)
        let red = px(act.pixels, 5)
        #expect(red[0] > 200 && red[1] < 60 && red[2] < 60)
        let none = DVDHighlightRenderer.renderRGBA(bitmap: bm, spuColors: [0, 0, 0, 0], spuContrast: [0, 0, 0, 0],
                                                   palette: palette, button: nil, scheme: nil, state: .selected)
        #expect(!none.visible)
        #expect(DVDHighlightRenderer.image(rgba: sel.pixels, width: bm.width, height: bm.height)?.width == 40)
    }

    @Test func yCrCbToRGB() {
        let white = DVDHighlightRenderer.rgb(fromYCrCb: 0xEB8080)
        #expect(white.r == 255 && white.g == 255 && white.b == 255)
        let black = DVDHighlightRenderer.rgb(fromYCrCb: 0x108080)
        #expect(black.r == 0 && black.g == 0 && black.b == 0)
    }

    @Test func scannerFindsSubpicturePacketsInSectors() throws {
        let payload = unit(x: 0, y: 0, top: [[(0, 1)]], bottom: [[(0, 1)]], width: 16)
        // One pack: MPEG-2 pack header (14 bytes), then a private-stream-1 PES with PTS 2 s, substream 0x21.
        var sector = [UInt8](repeating: 0, count: 2048)
        sector.replaceSubrange(0..<14, with: [0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 0x01, 0x89, 0xC3, 0xF8])
        let pts: Int64 = 180000
        let ptsBytes: [UInt8] = [UInt8(0x21 | (pts >> 29) & 0x0E), UInt8(pts >> 22 & 0xFF), UInt8((pts >> 14) & 0xFE | 1),
                                 UInt8(pts >> 7 & 0xFF), UInt8((pts << 1) & 0xFE | 1)]
        let body: [UInt8] = [0x81, 0x80, 0x05] + ptsBytes + [0x21] + payload
        let pes: [UInt8] = [0, 0, 1, 0xBD, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
        sector.replaceSubrange(14 ..< 14 + pes.count, with: pes)
        let padLen = 2048 - 14 - pes.count - 6
        sector.replaceSubrange(14 + pes.count ..< 14 + pes.count + 6, with: [0, 0, 1, 0xBE, UInt8(padLen >> 8), UInt8(padLen & 0xFF)])
        var scanner = DVDSubpictureScanner()
        let found = scanner.scan(sector)
        #expect(found.count == 1)
        #expect(found.first?.stream == 1)
        #expect(found.first?.pts == 2.0)
        #expect(found.first?.unit.decodePixels()?.width == 16)
    }

    // MARK: Sector mapping

    @Test func vobSetExtentsSpanFiles() {
        let layout = DVDVOBSetLayout(extents: [(offset: 10 * 2048, length: 4 * 2048), (offset: 100 * 2048, length: 6 * 2048)])
        #expect(layout.sectorCount == 10)
        let e = layout.byteExtents(sectors: 2 ..< 7)
        #expect(e.count == 2)
        #expect(e[0].offset == 12 * 2048 && e[0].length == 2 * 2048)
        #expect(e[1].offset == 100 * 2048 && e[1].length == 3 * 2048)
        #expect(layout.byteExtents(sectors: 5 ..< 6).map(\.offset) == [101 * 2048])
        #expect(layout.byteExtents(sectors: 20 ..< 30).isEmpty)
    }

    @Test func pgcCellRangesMergeAndSkipOtherAngles() {
        typealias D = DVDTestDisc
        let pgc = D.pgc(cells: [D.cell(start: 0), D.cell(start: 16),
                                D.cell(start: 40, cellType: 1, blockType: 1), D.cell(start: 60, cellType: 3, blockType: 1),
                                D.cell(start: 80)])
        // Test cells span start ... start + 15.
        #expect(DVDDiscSource.cellRanges(of: pgc) == [0 ..< 32, 40 ..< 56, 80 ..< 96])
        #expect(DVDDiscSource.cellRanges(of: pgc, angle: 2) == [0 ..< 32, 60 ..< 76, 80 ..< 96])
        #expect(DVDDiscSource.cellRanges(of: pgc, fromCell: 2, startSectorOffset: 4) == [20 ..< 32, 40 ..< 56, 80 ..< 96])
    }

    @Test func walkCellFollowsNavPacks() throws {
        let disc = try DVDDiscSource(url: DVDMenuPlayerTests.fixture("menu-test.iso"))
        let pgc = try #require(disc.navigation.titleSets[1]?.titlePGCs.first?.pgc)
        for cell in pgc.cells {
            let vobus = disc.walkCell(cell, in: .title(vts: 1))
            #expect(vobus.first?.sector == cell.firstVOBUStart)
            #expect(vobus.allSatisfy { $0.nav != nil })
            #expect(vobus.reduce(0) { $0 + $1.sectorCount } == cell.lastVOBUEnd - cell.firstVOBUStart + 1)
            #expect(vobus.last?.sector == cell.lastVOBUStart)
        }
    }
}
