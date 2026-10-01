import Foundation

// Sector-level access to a DVD-Video volume for the navigation source (docs/dvd-menus.md, phase 2).
// A cell's sectors are relative to its VOB set: VIDEO_TS.VOB (VMGM menus), VTS_nn_0.VOB (VTSM menus) or
// VTS_nn_1..9.VOB concatenated (titles). This file maps those VOB-set sectors onto byte ranges of the
// image and walks a cell VOBU by VOBU through the NAV packs.

/// A VOB set laid out as a list of byte extents of the underlying image.
struct DVDVOBSetLayout: Equatable, Sendable {
    /// Byte extents (offset in the image, length) of the set's files, in order.
    let extents: [(offset: Int64, length: Int64)]

    static func == (a: DVDVOBSetLayout, b: DVDVOBSetLayout) -> Bool {
        a.extents.count == b.extents.count && zip(a.extents, b.extents).allSatisfy { $0.offset == $1.offset && $0.length == $1.length }
    }

    var sectorCount: UInt32 { UInt32(extents.reduce(Int64(0)) { $0 + $1.length } / 2048) }

    /// Image byte extents covering VOB-set sectors `range` (end exclusive), split across file boundaries.
    func byteExtents(sectors range: Range<UInt32>) -> [(offset: Int64, length: Int64)] {
        var out: [(offset: Int64, length: Int64)] = []
        var want = Int64(range.lowerBound) * 2048
        let end = Int64(range.upperBound) * 2048
        var fileStart: Int64 = 0
        for e in extents {
            let fileEnd = fileStart + e.length
            if want < fileEnd && want < end {
                let from = want - fileStart
                let to = min(fileEnd, end) - fileStart
                if to > from { out.append((offset: e.offset + from, length: to - from)) }
                want = fileStart + to
            }
            fileStart = fileEnd
            if want >= end { break }
        }
        return out
    }
}

/// One VOBU found while walking a cell.
struct DVDVOBU: Equatable, Sendable {
    /// First sector (the NAV pack), relative to the VOB set.
    let sector: UInt32
    /// Sectors in this VOBU, NAV pack included.
    let sectorCount: UInt32
    let nav: DVDNavPack?
}

/// A DVD-Video image opened for navigation: file table, navigation data, sector reads.
final class DVDDiscSource: @unchecked Sendable {
    let reader: IOReader
    let navigation: DVDNavigationData
    private let files: [DiscFile]
    private let sectorSize: Int
    private let lock = NSLock()

    init(reader: IOReader) throws {
        let iso = try ISO9660Reader(reader: reader)
        let files = try iso.list(directory: "VIDEO_TS")
        self.reader = reader
        self.files = files
        self.sectorSize = iso.sectorSize
        guard let nav = DVDNavigationData.load(readFile: { name in
            guard let f = files.first(where: { $0.name.uppercased() == name }) else { return nil }
            let b = DiscReader.readAll(reader, [(offset: Int64(f.startSector * iso.sectorSize), length: Int64(f.length))])
            return b.isEmpty ? nil : b
        }) else { throw DiscError.malformed("VIDEO_TS.IFO unreadable") }
        self.navigation = nav
    }

    convenience init(url: URL) throws {
        guard let r = FileIOReader(url: url) else { throw DiscError.malformed("cannot open \(url.lastPathComponent)") }
        try self.init(reader: r)
    }

    private func extent(_ name: String) -> (offset: Int64, length: Int64)? {
        files.first { $0.name.uppercased() == name }.map { (offset: Int64($0.startSector * sectorSize), length: Int64($0.length)) }
    }

    func layout(_ set: DVDVOBSet) -> DVDVOBSetLayout? {
        switch set {
        case .vmgMenu:
            return extent("VIDEO_TS.VOB").map { DVDVOBSetLayout(extents: [$0]) }
        case .vtsMenu(let n):
            return extent(String(format: "VTS_%02d_0.VOB", n)).map { DVDVOBSetLayout(extents: [$0]) }
        case .title(let n):
            let parts = (1...9).compactMap { extent(String(format: "VTS_%02d_%d.VOB", n, $0)) }
            return parts.isEmpty ? nil : DVDVOBSetLayout(extents: parts)
        }
    }

    /// Reads `count` sectors starting at VOB-set sector `sector`. Short at the end of the set.
    func readSectors(_ set: DVDVOBSet, from sector: UInt32, count: UInt32) -> [UInt8] {
        guard let layout = layout(set) else { return [] }
        let exts = layout.byteExtents(sectors: sector ..< sector &+ count)
        let total = exts.reduce(0) { $0 + Int($1.length) }
        guard total > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        var out = [UInt8](repeating: 0, count: total)
        var at = 0
        for e in exts {
            guard reader.seek(offset: e.offset, whence: SEEK_SET) >= 0 else { break }
            var got = 0
            let want = Int(e.length)
            out.withUnsafeMutableBufferPointer { p in
                while got < want {
                    let n = reader.read(p.baseAddress!.advanced(by: at + got), size: Int32(want - got))
                    if n <= 0 { break }
                    got += Int(n)
                }
            }
            at += got
            if got < want { break }
        }
        if at < total { out.removeLast(total - at) }
        return out
    }

    /// Walks a cell VOBU by VOBU from its first VOBU (or `startSectorOffset` into it) to its last,
    /// following each NAV pack's VOBU end address. A sector that is not a NAV pack ends the walk with the
    /// remainder of the cell as one unparsed span, so damaged cells still play.
    func walkCell(_ cell: DVDCellPlayback, in set: DVDVOBSet, startSectorOffset: UInt32 = 0) -> [DVDVOBU] {
        var out: [DVDVOBU] = []
        var s = cell.firstVOBUStart &+ startSectorOffset
        let last = cell.lastVOBUEnd
        var guardCount = 0
        while s <= last, guardCount < 1_000_000 {
            guardCount += 1
            let sector = readSectors(set, from: s, count: 1)
            guard sector.count == 2048, let nav = DVDNavPack.parse(sector: sector) else {
                out.append(DVDVOBU(sector: s, sectorCount: last - s + 1, nav: nil))
                break
            }
            let count = max(1, min(nav.dsi.vobuEndAddress + 1, last - s + 1))
            out.append(DVDVOBU(sector: s, sectorCount: count, nav: nav))
            s += count
        }
        return out
    }

    /// A seekable reader over VOB-set sectors (end exclusive): what the demuxer reads for a cell / PGC.
    func makeReader(_ set: DVDVOBSet, sectorRanges: [Range<UInt32>]) -> IOReader? {
        guard let layout = layout(set) else { return nil }
        let exts = sectorRanges.flatMap { layout.byteExtents(sectors: $0) }
        guard !exts.isEmpty, let base = reader.makeIndependentReader() ?? Optional(reader) else { return nil }
        return ConcatIOReader(base: base, extents: exts)
    }

    /// The sector ranges of a PGC's cells from `fromCell` (1-based) on, skipping the angle-block cells
    /// that `angle` does not select. Used to hand a title PGC to the normal playback pipeline.
    static func cellRanges(of pgc: DVDPGC, fromCell: Int = 1, angle: Int = 1, startSectorOffset: UInt32 = 0) -> [Range<UInt32>] {
        var ranges: [Range<UInt32>] = []
        var blockIndex = 0
        for (i, c) in pgc.cells.enumerated() where i + 1 >= fromCell {
            if c.isAngleBlock {
                blockIndex = c.cellType == 1 ? 1 : blockIndex + 1
                if blockIndex != max(1, angle) { continue }
            }
            var start = c.firstVOBUStart
            if i + 1 == fromCell { start = start &+ startSectorOffset }
            guard c.lastVOBUEnd >= start else { continue }
            let r = start ..< c.lastVOBUEnd + 1
            if let prev = ranges.last, prev.upperBound == r.lowerBound {
                ranges[ranges.count - 1] = prev.lowerBound ..< r.upperBound
            } else {
                ranges.append(r)
            }
        }
        return ranges
    }
}
