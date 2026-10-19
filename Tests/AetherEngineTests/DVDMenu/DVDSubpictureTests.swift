import Foundation
import Testing
import os
import AetherLibavcodec
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

    @Test func assemblerJoinsFragments() {
        var a = DVDSubpictureAssembler()
        #expect(a.feed([0x00, 0x08, 0x00, 0x04], pts: 90000) == nil)
        let done = a.feed([0xAA, 0xBB, 0xCC, 0xDD], pts: nil)
        #expect(done?.unit == [0x00, 0x08, 0x00, 0x04, 0xAA, 0xBB, 0xCC, 0xDD])
        #expect(done?.pts == 90000)
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

    @Test func selectedAngleDefinesTitleClock() {
        let time = DVDTime(hours: 0, minutes: 0, seconds: 10, frames: 0, frameRate: 25)
        let cells = [
            DVDCellPlayback(playbackTime: time),
            DVDCellPlayback(cellType: 1, blockType: 1, playbackTime: time),
            DVDCellPlayback(cellType: 3, blockType: 1, playbackTime: time),
            DVDCellPlayback(stcDiscontinuity: true, playbackTime: time)
        ]
        let pgc = DVDTestDisc.pgc(cells: cells, programMap: [1, 2, 4])
        let timeline = DVDDiscSource.cellTimeline(of: pgc, angle: 2)
        #expect(timeline.cells == [0, 2, 3])
        #expect(timeline.starts == [0, 10, 10, 20])
        #expect(timeline.duration == 30)
    }

    private final class CountingCellReader: IOReader {
        struct State { var cursor: Int64 = 0; var bytesRead: Int64 = 0 }
        let state = OSAllocatedUnfairLock(initialState: State())
        let length: Int64 = 8 * 1024 * 1024 * 1024

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            let count = state.withLock {
                let count = Int32(min(Int64(size), length - $0.cursor))
                $0.cursor += Int64(count)
                $0.bytesRead += Int64(count)
                return count
            }
            buffer?.initialize(repeating: 0, count: Int(count))
            return count
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            state.withLock {
                if whence == 65536 { return length }
                let next = offset + (whence == SEEK_CUR ? $0.cursor : whence == SEEK_END ? length : 0)
                guard (0...length).contains(next) else { return -1 }
                $0.cursor = next
                return next
            }
        }

        func close() {}
        func makeIndependentReader() -> IOReader? { CountingCellReader() }
    }

    @Test func tenMinuteSeekLandsAtTheAlignedByteOffsetWithoutATimeMap() {
        let base = CountingCellReader()
        let reader = DVDTitleIOReader(base: base, cells: [
            .init(byteStart: 0, byteLength: base.length, startSeconds: 0,
                  durationSeconds: 2400, sourceStartSeconds: 100)
        ], duration: 2400)
        #expect(reader.seek(to: 600))
        let target = base.length / 4
        #expect(reader.seek(offset: 0, whence: SEEK_CUR) == target)
        #expect(base.state.withLock { $0.bytesRead } == 0)
        #expect(reader.timestampShift(at: target) == 100)
    }

    @Test(arguments: [false, true])
    func missingCellTimeMapUsesTheProportionalLanding(mapInOtherCell: Bool) {
        let base = CountingCellReader()
        let cellLength = base.length / 2
        let reader = DVDTitleIOReader(base: base, cells: [
            .init(byteStart: 0, byteLength: cellLength, startSeconds: 0,
                  durationSeconds: 1200, sourceStartSeconds: 100),
            .init(byteStart: cellLength, byteLength: cellLength, startSeconds: 1200,
                  durationSeconds: 1200, sourceStartSeconds: 1300)
        ], duration: 2400, timeMap: mapInOtherCell ? [.init(seconds: 10, byteOffset: 2048)] : [])
        #expect(reader.seek(to: 1800))
        #expect(reader.seek(offset: 0, whence: SEEK_CUR) == cellLength + cellLength / 2)
        #expect(base.state.withLock { $0.bytesRead } == 0)
    }

    @Test func syntheticTimeMapSeeksBeforeTheTargetDespiteVariableBitrate() throws {
        var ifo = [UInt8](repeating: 0, count: 4096)
        ifo.replaceSubrange(0..<12, with: DVDVTSI.magic)
        func put32(_ offset: Int, _ value: UInt32) {
            for byte in 0..<4 { ifo[offset + byte] = UInt8(truncatingIfNeeded: value >> (24 - byte * 8)) }
        }
        put32(0xD4, 1)
        ifo[2049] = 1
        put32(2052, 23)
        put32(2056, 12)
        ifo[2060] = 10
        ifo[2063] = 2
        put32(2064, 100)
        put32(2068, 0x8000_0384) // Discontinuous VOBU at sector 900, not a proportional landing.
        let parsed = try #require(DVDVTSI.parse(ifo))
        let map = try #require(parsed.titleTimeMaps.first)
        #expect(map.intervalSeconds == 10)
        let base = CountingCellReader()
        let points = map.entries.enumerated().map { index, sector in
            DVDTitleIOReader.SeekPoint(seconds: Double(index + 1) * Double(map.intervalSeconds),
                                       byteOffset: Int64(sector & 0x7FFF_FFFF) * 2048)
        }
        let reader = DVDTitleIOReader(base: base, cells: [
            .init(byteStart: 0, byteLength: base.length, startSeconds: 0,
                  durationSeconds: 2400, sourceStartSeconds: 100)
        ], duration: 2400, timeMap: points)
        for (seconds, sector) in [(9.0, 0), (10, 100), (19, 100), (20, 900), (29, 900)] {
            #expect(reader.seek(to: seconds))
            #expect(reader.seek(offset: 0, whence: SEEK_CUR) == Int64(sector) * 2048)
        }
        #expect(base.state.withLock { $0.bytesRead } == 0)
        put32(2052, 19) // A truncated entry cannot be read from the next IFO table.
        #expect(DVDVTSI.parse(ifo)?.titleTimeMaps == [DVDTimeMap(intervalSeconds: 0, entries: [])])
    }

    @Test(arguments: ["zeroInterval", "invalidOffset", "truncatedEntries"])
    func malformedTimeMapPreservesOtherPGCMaps(damage: String) {
        var bytes = [UInt8](repeating: 0, count: 44)
        func put32(_ offset: Int, _ value: UInt32) {
            for byte in 0..<4 { bytes[offset + byte] = UInt8(truncatingIfNeeded: value >> (24 - byte * 8)) }
        }
        bytes[1] = 3
        put32(4, 43)
        for (index, offset) in [20, 28, 36].enumerated() {
            put32(8 + index * 4, UInt32(offset))
            bytes[offset] = 10
            bytes[offset + 3] = 1
            put32(offset + 4, UInt32(100 * (index + 1)))
        }
        switch damage {
        case "zeroInterval":
            bytes[28] = 0
            bytes[31] = 0
        case "invalidOffset":
            put32(12, 44)
        default:
            bytes[31] = 4
        }
        let maps = DVDTimeMap.parseTable(DVDBytes(bytes), at: 0)
        #expect(maps == [DVDTimeMap(intervalSeconds: 10, entries: [100]),
                         DVDTimeMap(intervalSeconds: 0, entries: []),
                         DVDTimeMap(intervalSeconds: 10, entries: [300])])
    }

    @Test func navShiftsResolveOnFirstUseAndCacheDamagedCells() throws {
        let base = CountingCellReader()
        let resolved = OSAllocatedUnfairLock(initialState: [Int]())
        let reader = DVDTitleIOReader(base: base, cells: [
            .init(byteStart: 0, byteLength: 4096, startSeconds: 0, durationSeconds: 10, sourceStartSeconds: nil),
            .init(byteStart: 4096, byteLength: 4096, startSeconds: 10, durationSeconds: 10, sourceStartSeconds: nil),
            .init(byteStart: 8192, byteLength: 4096, startSeconds: 20, durationSeconds: 10, sourceStartSeconds: nil)
        ], duration: 30) { index in
            resolved.withLock { $0.append(index) }
            return index == 0 ? 100 : index == 1 ? 2 : nil
        }
        #expect(reader.timestampShift(at: 0) == 100)
        #expect(resolved.withLock { $0 } == [0])
        #expect(reader.seek(to: 10))
        #expect(reader.timestampShift(at: 4096) == -8)
        #expect(reader.timestampShift(at: 8192) == -8)
        #expect(reader.timestampShift(at: 8192) == -8)
        #expect(resolved.withLock { $0 } == [0, 1, 2])
        let fork = try #require(reader.makeIndependentReader() as? DVDTitleIOReader)
        #expect(fork.timestampShift(at: 0) == 100)
        #expect(fork.timestampShift(at: 4096) == -8)
        #expect(fork.timestampShift(at: 8192) == -8)
        #expect(resolved.withLock { $0 } == [0, 1, 2])
    }

    @Test func sectorSeekAndDiscontinuousCellClock() throws {
        let base = try #require(FileIOReader(url: DVDMenuPlayerTests.fixture("menu-test.iso")))
        let reader = DVDTitleIOReader(base: base,
            cells: [
                .init(byteStart: 0, byteLength: 4096, startSeconds: 0, durationSeconds: 10, sourceStartSeconds: 100),
                .init(byteStart: 4096, byteLength: 4096, startSeconds: 10, durationSeconds: 10, sourceStartSeconds: 2)
            ], duration: 20)
        #expect(reader.seek(to: 12))
        #expect(reader.seek(offset: 0, whence: SEEK_CUR) == 4096)
        #expect(reader.timestampShift(at: 4096) == -8)
        #expect(2 - reader.timestampShift(at: 4096) == 10)
        #expect(reader.seek(to: 3))
        #expect(reader.seek(offset: 0, whence: SEEK_CUR) == 0)
        let fork = try #require(reader.makeIndependentReader() as? DVDTitleIOReader)
        #expect(fork.seek(to: 12))
        #expect(fork.seek(offset: 0, whence: SEEK_CUR) == 4096)
        #expect(reader.seek(offset: 0, whence: SEEK_CUR) == 0)
    }

    @Test func demuxerChapterEntryStartsAtTheCellSector() throws {
        let harness = try DVDMenuPlayerTests.Harness("menu-test.iso", titleMode: .external)
        harness.player.start(skipToMainTitle: true)
        let request = try #require(harness.titleRequests.first)
        let disc = harness.player.disc
        let pgc = try #require(disc.navigation.titleSets[1]?.titlePGCs.first?.pgc)
        let reader = try #require(disc.makeTitleReader(request))
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: reader, formatHint: "mpeg")
        #expect(demuxer.seek(to: request.cellStartSeconds[1]))
        let cellOne = pgc.cells[0]
        let cellTwoByteStart = Int64(cellOne.lastVOBUEnd - cellOne.firstVOBUStart + 1) * 2048
        #expect(reader.seek(offset: 0, whence: SEEK_CUR) == cellTwoByteStart)
        let video = demuxer.videoStreamIndex
        try #require(video >= 0)
        var firstPacketPosition: Int64?
        var firstVideoSeconds: Double?
        while let packet = try demuxer.readPacket() {
            var owned = Optional(packet)
            defer { trackedPacketFree(&owned) }
            if firstPacketPosition == nil { firstPacketPosition = packet.pointee.pos }
            if packet.pointee.stream_index == video,
               let stream = demuxer.stream(at: video) {
                let tb = stream.pointee.time_base
                firstVideoSeconds = Double(packet.pointee.pts) * Double(tb.num) / Double(tb.den)
                break
            }
        }
        let position = try #require(firstPacketPosition)
        let cellTwo = pgc.cells[1]
        let cellTwoByteEnd = cellTwoByteStart + Int64(cellTwo.lastVOBUEnd - cellTwo.firstVOBUStart + 1) * 2048
        #expect(position >= cellTwoByteStart)
        #expect(position < cellTwoByteEnd)
        #expect(abs(try #require(firstVideoSeconds) - request.cellStartSeconds[1]) < 0.1)
    }

    @Test(arguments: [0, 1]) func damagedCellNAVKeepsTheTitleReadable(cellIndex: Int) throws {
        let harness = try DVDMenuPlayerTests.Harness("menu-test.iso", titleMode: .external)
        harness.player.start(skipToMainTitle: true)
        let request = try #require(harness.titleRequests.first)
        let disc = harness.player.disc
        let pgc = try #require(disc.navigation.titleSets[1]?.titlePGCs.first?.pgc)
        let layout = try #require(disc.layout(.title(vts: 1)))
        let cell = pgc.cells[cellIndex]
        let extent = try #require(layout.byteExtents(sectors: cell.firstVOBUStart..<(cell.firstVOBUStart + 1)).first)
        var bytes = try Data(contentsOf: DVDMenuPlayerTests.fixture("menu-test.iso"))
        bytes.replaceSubrange(Int(extent.offset)..<(Int(extent.offset) + 2048), with: repeatElement(UInt8(0), count: 2048))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iso")
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes.write(to: url)
        let damaged = try DVDDiscSource(url: url)
        let reader = try #require(damaged.makeTitleReader(request) as? DVDTitleIOReader)
        defer { reader.close(); damaged.reader.close() }
        let byteStart = pgc.cells.prefix(cellIndex).reduce(Int64(0)) {
            $0 + Int64($1.lastVOBUEnd - $1.firstVOBUStart + 1) * 2048
        }
        #expect(reader.seek(to: request.cellStartSeconds[cellIndex]))
        #expect(reader.seek(offset: 0, whence: SEEK_CUR) == byteStart)
        let expectedShift = cellIndex == 0 ? 0 : reader.timestampShift(at: 0)
        #expect(abs(reader.timestampShift(at: byteStart) - expectedShift) < 0.000001)
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
