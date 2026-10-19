import Foundation

// Navigation-level IFO parsing for DVD-Video menus (clean-room; docs/dvd-menus.md lists the spec pages).
// DVDIFOParser (the pre-existing title/chapter enumerator) stays untouched; this file parses the full
// VMGI / VTSI navigation data the VM needs: first-play PGC, menu PGC tables per language unit, title PGC
// table, PTT search table, cell + VOBU address maps, and the menu/title stream attributes.

// MARK: - User operations

/// User-operation prohibition bits (UOP0-UOP24). A set bit forbids the operation. The masks from TT_SRPT
/// (UOP0/1 only), the PGC and the current VOBU's PCI are OR-ed together.
struct DVDUserOperations: OptionSet, Equatable, Sendable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }

    static let timePlayOrSearch     = DVDUserOperations(rawValue: 1 << 0)
    static let pttPlayOrSearch      = DVDUserOperations(rawValue: 1 << 1)
    static let titlePlay            = DVDUserOperations(rawValue: 1 << 2)
    static let stop                 = DVDUserOperations(rawValue: 1 << 3)
    static let goUp                 = DVDUserOperations(rawValue: 1 << 4)
    static let timeOrPTTSearch      = DVDUserOperations(rawValue: 1 << 5)
    static let topOrPrevPGSearch    = DVDUserOperations(rawValue: 1 << 6)
    static let nextPGSearch         = DVDUserOperations(rawValue: 1 << 7)
    static let forwardScan          = DVDUserOperations(rawValue: 1 << 8)
    static let backwardScan         = DVDUserOperations(rawValue: 1 << 9)
    static let titleMenuCall        = DVDUserOperations(rawValue: 1 << 10)
    static let rootMenuCall         = DVDUserOperations(rawValue: 1 << 11)
    static let subpictureMenuCall   = DVDUserOperations(rawValue: 1 << 12)
    static let audioMenuCall        = DVDUserOperations(rawValue: 1 << 13)
    static let angleMenuCall        = DVDUserOperations(rawValue: 1 << 14)
    static let pttMenuCall          = DVDUserOperations(rawValue: 1 << 15)
    static let resume               = DVDUserOperations(rawValue: 1 << 16)
    static let buttonSelectOrActivate = DVDUserOperations(rawValue: 1 << 17)
    static let stillOff             = DVDUserOperations(rawValue: 1 << 18)
    static let pauseOn              = DVDUserOperations(rawValue: 1 << 19)
    static let audioStreamChange    = DVDUserOperations(rawValue: 1 << 20)
    static let subpictureStreamChange = DVDUserOperations(rawValue: 1 << 21)
    static let angleChange          = DVDUserOperations(rawValue: 1 << 22)
    static let karaokeMixChange     = DVDUserOperations(rawValue: 1 << 23)
    static let videoModeChange      = DVDUserOperations(rawValue: 1 << 24)
}

// MARK: - Stream attributes

struct DVDVideoAttributes: Equatable, Sendable {
    let raw: UInt16
    /// 0 = MPEG-1, 1 = MPEG-2.
    var codingMode: Int { Int(raw >> 14) & 0x3 }
    /// 0 = NTSC, 1 = PAL.
    var standard: Int { Int(raw >> 12) & 0x3 }
    /// 0 = 4:3, 3 = 16:9.
    var aspect: Int { Int(raw >> 10) & 0x3 }
    var isWidescreen: Bool { aspect == 3 }
    var autoPanScanDisallowed: Bool { raw & 0x0200 != 0 }
    var autoLetterboxDisallowed: Bool { raw & 0x0100 != 0 }
    /// 0 = 720, 1 = 704, 2 = 352 (full height), 3 = 352 (half height).
    var resolution: Int { Int(raw >> 3) & 0x7 }
    var letterboxed: Bool { raw & 0x0004 != 0 }
    var isPAL: Bool { standard == 1 }

    var size: (width: Int, height: Int) {
        let h = isPAL ? 576 : 480
        switch resolution {
        case 1: return (704, h)
        case 2: return (352, h)
        case 3: return (352, h / 2)
        default: return (720, h)
        }
    }
}

/// ISO 639 language code bytes -> "en", or nil for unspecified / non-letter bytes.
private func dvdLanguage(_ a: UInt8, _ b: UInt8) -> String? {
    guard (0x61...0x7A).contains(a | 0x20), (0x61...0x7A).contains(b | 0x20) else { return nil }
    return String(bytes: [a | 0x20, b | 0x20], encoding: .ascii)
}

struct DVDAudioAttributes: Equatable, Sendable {
    let raw: [UInt8]   // 8 bytes
    /// 0 = AC-3, 2 = MPEG-1, 3 = MPEG-2 ext, 4 = LPCM, 6 = DTS.
    var codingMode: Int { Int(raw[0] >> 5) }
    var multichannelExtension: Bool { raw[0] & 0x10 != 0 }
    var languageType: Int { Int(raw[0] >> 2) & 0x3 }
    var applicationMode: Int { Int(raw[0]) & 0x3 }
    var quantization: Int { Int(raw[1] >> 6) }
    var sampleRateCode: Int { Int(raw[1] >> 4) & 0x3 }
    var channels: Int { Int(raw[1] & 0x7) + 1 }
    var language: String? { languageType == 1 ? dvdLanguage(raw[2], raw[3]) : nil }
    var codeExtension: Int { Int(raw[5]) }
}

struct DVDSubpictureAttributes: Equatable, Sendable {
    let raw: [UInt8]   // 6 bytes
    var codingMode: Int { Int(raw[0] >> 5) }
    var languageType: Int { Int(raw[0]) & 0x3 }
    var language: String? { languageType == 1 ? dvdLanguage(raw[2], raw[3]) : nil }
    var codeExtension: Int { Int(raw[5]) }
}

struct DVDStreamAttributes: Equatable, Sendable {
    let video: DVDVideoAttributes
    let audio: [DVDAudioAttributes]
    let subpicture: [DVDSubpictureAttributes]

    /// Video attrs at `base`, audio count at base+2, 8 audio entries at base+4, subpicture count at
    /// base+0x54, subpicture entries (6 bytes each) at base+0x56.
    init?(_ b: DVDBytes, base: Int, maxSubpictures: Int) {
        guard let v = b.u16(base), let na = b.u16(base + 2), let ns = b.u16(base + 0x54) else { return nil }
        video = DVDVideoAttributes(raw: v)
        audio = (0..<min(Int(na), 8)).compactMap { i in b.slice(base + 4 + i * 8, 8).map(DVDAudioAttributes.init) }
        subpicture = (0..<min(Int(ns), maxSubpictures)).compactMap { i in
            b.slice(base + 0x56 + i * 6, 6).map(DVDSubpictureAttributes.init)
        }
    }
}

// MARK: - PGC

/// One entry of a PGC's cell playback information table.
struct DVDCellPlayback: Equatable, Sendable {
    /// 0 = normal, 1 = first, 2 = middle, 3 = last cell of an angle block.
    let cellType: Int
    /// 0 = normal, 1 = angle block.
    let blockType: Int
    let seamless: Bool
    let interleaved: Bool
    let stcDiscontinuity: Bool
    let seamlessAngle: Bool
    let restricted: Bool
    /// Seconds to hold the last frame after the cell; 0 = none, 255 = until the user releases it.
    let stillTime: UInt8
    /// 1-based index into the PGC's cell commands, 0 = none.
    let cellCommand: Int
    let playbackTime: DVDTime
    /// Sectors are relative to the start of the domain's VOBS (menu VOBS or title VOBS).
    let firstVOBUStart: UInt32
    let firstILVUEnd: UInt32
    let lastVOBUStart: UInt32
    let lastVOBUEnd: UInt32

    var isAngleBlock: Bool { blockType == 1 }

    init(cellType: Int = 0, blockType: Int = 0, seamless: Bool = false, interleaved: Bool = false,
         stcDiscontinuity: Bool = false, seamlessAngle: Bool = false, restricted: Bool = false,
         stillTime: UInt8 = 0, cellCommand: Int = 0,
         playbackTime: DVDTime = DVDTime(hours: 0, minutes: 0, seconds: 1, frames: 0, frameRate: 30),
         firstVOBUStart: UInt32 = 0, firstILVUEnd: UInt32 = 0, lastVOBUStart: UInt32 = 0, lastVOBUEnd: UInt32 = 0) {
        self.cellType = cellType; self.blockType = blockType; self.seamless = seamless
        self.interleaved = interleaved; self.stcDiscontinuity = stcDiscontinuity; self.seamlessAngle = seamlessAngle
        self.restricted = restricted; self.stillTime = stillTime; self.cellCommand = cellCommand
        self.playbackTime = playbackTime; self.firstVOBUStart = firstVOBUStart; self.firstILVUEnd = firstILVUEnd
        self.lastVOBUStart = lastVOBUStart; self.lastVOBUEnd = lastVOBUEnd
    }

    init?(_ b: DVDBytes, _ o: Int) {
        guard let c0 = b.u8(o), let c1 = b.u8(o + 1), let still = b.u8(o + 2), let cmd = b.u8(o + 3),
              let time = DVDTime(b, o + 4), let s0 = b.u32(o + 8), let s1 = b.u32(o + 12),
              let s2 = b.u32(o + 16), let s3 = b.u32(o + 20) else { return nil }
        cellType = Int(c0 >> 6); blockType = Int(c0 >> 4) & 0x3
        seamless = c0 & 0x08 != 0; interleaved = c0 & 0x04 != 0
        stcDiscontinuity = c0 & 0x02 != 0; seamlessAngle = c0 & 0x01 != 0
        restricted = c1 & 0x40 != 0
        stillTime = still; cellCommand = Int(cmd); playbackTime = time
        firstVOBUStart = s0; firstILVUEnd = s1; lastVOBUStart = s2; lastVOBUEnd = s3
    }
}

struct DVDCellPosition: Equatable, Sendable {
    let vobID: Int
    let cellID: Int
}

/// A program chain: the unit the VM executes (pre commands, cells, post commands).
struct DVDPGC: Equatable, Sendable {
    let programCount: Int
    let cellCount: Int
    let playbackTime: DVDTime?
    let prohibitedOperations: DVDUserOperations
    /// PGC_AST_CTL: 8 entries, bit 15 = available, bits 10-8 = stream / substream number.
    let audioControl: [UInt16]
    /// PGC_SPST_CTL: 32 entries, bit 31 = available, then 4:3 / wide / letterbox / pan-scan stream numbers.
    let subpictureControl: [UInt32]
    let nextPGCN: Int
    let prevPGCN: Int
    let goUpPGCN: Int
    /// 0 = none, 255 = infinite.
    let stillTime: UInt8
    /// 0 = sequential; otherwise bit 7 = shuffle (1) / random (0), bits 6-0 = program count.
    let playbackMode: UInt8
    /// 16 colours, each 0x00YYCrCb.
    let palette: [UInt32]
    let preCommands: [DVDCommand]
    let postCommands: [DVDCommand]
    let cellCommands: [DVDCommand]
    /// Entry cell (1-based) of each program (1-based program n = programMap[n-1]).
    let programMap: [Int]
    let cells: [DVDCellPlayback]
    let cellPositions: [DVDCellPosition]

    /// The audio stream id (MPEG stream / AC-3 substream number) for logical audio track `track` (0-7).
    func audioStream(track: Int) -> Int? {
        guard audioControl.indices.contains(track), audioControl[track] & 0x8000 != 0 else { return nil }
        return Int(audioControl[track] >> 8) & 0x7
    }

    /// The subpicture stream id for logical track `track` (0-31): byte 0 = 4:3, 1 = wide, 2 = letterbox, 3 = pan&scan.
    func subpictureStream(track: Int, mode: Int = 0) -> Int? {
        guard subpictureControl.indices.contains(track), subpictureControl[track] & 0x8000_0000 != 0 else { return nil }
        return Int(subpictureControl[track] >> UInt32(24 - 8 * min(max(mode, 0), 3))) & 0x1F
    }

    /// Program number (1-based) containing 1-based cell `cell`.
    func program(containing cell: Int) -> Int {
        var pg = 1
        for (i, entry) in programMap.enumerated() where entry <= cell { pg = i + 1 }
        return pg
    }

    static func parse(_ b: DVDBytes, at base: Int) -> DVDPGC? {
        guard b.has(base, 0xEC), let nPrograms = b.u8(base + 2), let nCells = b.u8(base + 3),
              let uops = b.u32(base + 8) else { return nil }
        let audio = (0..<8).compactMap { b.u16(base + 0x0C + $0 * 2) }
        let subp = (0..<32).compactMap { b.u32(base + 0x1C + $0 * 4) }
        let palette = (0..<16).compactMap { b.u32(base + 0xA4 + $0 * 4) }
        let cmdOff = Int(b.u16(base + 0xE4) ?? 0)
        let mapOff = Int(b.u16(base + 0xE6) ?? 0)
        let cellOff = Int(b.u16(base + 0xE8) ?? 0)
        let posOff = Int(b.u16(base + 0xEA) ?? 0)

        var pre: [DVDCommand] = [], post: [DVDCommand] = [], cellCmds: [DVDCommand] = []
        if cmdOff != 0, let np = b.u16(base + cmdOff), let npo = b.u16(base + cmdOff + 2),
           let nc = b.u16(base + cmdOff + 4) {
            // A legal table has at most 128 commands in total; clamp so a hostile count cannot balloon.
            let total = min(Int(np) + Int(npo) + Int(nc), 128)
            var cmds: [DVDCommand] = []
            for i in 0..<total {
                guard let raw = b.slice(base + cmdOff + 8 + i * 8, 8) else { break }
                cmds.append(DVDCommand(raw))
            }
            let p = min(Int(np), cmds.count)
            let q = min(Int(npo), cmds.count - p)
            pre = Array(cmds[0..<p])
            post = Array(cmds[p..<(p + q)])
            cellCmds = Array(cmds[(p + q)...])
        }
        var programMap: [Int] = []
        if mapOff != 0 {
            programMap = (0..<Int(nPrograms)).compactMap { b.u8(base + mapOff + $0).map(Int.init) }
        }
        var cells: [DVDCellPlayback] = []
        if cellOff != 0 {
            cells = (0..<Int(nCells)).compactMap { DVDCellPlayback(b, base + cellOff + $0 * 24) }
        }
        var positions: [DVDCellPosition] = []
        if posOff != 0 {
            positions = (0..<Int(nCells)).compactMap { i in
                guard let vob = b.u16(base + posOff + i * 4), let cell = b.u8(base + posOff + i * 4 + 3) else { return nil }
                return DVDCellPosition(vobID: Int(vob), cellID: Int(cell))
            }
        }
        return DVDPGC(
            programCount: Int(nPrograms), cellCount: Int(nCells), playbackTime: DVDTime(b, base + 4),
            prohibitedOperations: DVDUserOperations(rawValue: uops), audioControl: audio, subpictureControl: subp,
            nextPGCN: Int(b.u16(base + 0x9C) ?? 0), prevPGCN: Int(b.u16(base + 0x9E) ?? 0),
            goUpPGCN: Int(b.u16(base + 0xA0) ?? 0), stillTime: b.u8(base + 0xA2) ?? 0,
            playbackMode: b.u8(base + 0xA3) ?? 0, palette: palette,
            preCommands: pre, postCommands: post, cellCommands: cellCmds,
            programMap: programMap, cells: cells, cellPositions: positions)
    }
}

/// A PGC search-pointer entry: category + PGC. In menu tables the category carries the entry flag and
/// menu type; in the title table it carries the entry flag and the VTS title number.
struct DVDPGCEntry: Equatable, Sendable {
    let category: UInt32
    let pgc: DVDPGC

    var isEntry: Bool { category & 0x8000_0000 != 0 }
    /// Menu tables: 2 = title (VMGM), 3 = root, 4 = subpicture, 5 = audio, 6 = angle, 7 = PTT (VTSM).
    var menuType: Int { Int(category >> 24) & 0x0F }
    /// Title table: the VTS title number this PGC belongs to.
    var titleNumber: Int { Int(category >> 24) & 0x7F }
}

/// Menu types used by JumpSS / CallSS and the menu PGC categories.
enum DVDMenuType: Int, Sendable {
    case title = 2, root = 3, subpicture = 4, audio = 5, angle = 6, chapter = 7
}

/// A language unit of a menu PGCI_UT: one language's set of menu PGCs.
struct DVDMenuLanguageUnit: Equatable, Sendable {
    let language: String?
    let existenceFlags: UInt8
    let pgcs: [DVDPGCEntry]

    /// 1-based PGC number of the entry PGC for `menu`, if this language unit has one.
    func entryPGCN(for menu: Int) -> Int? {
        pgcs.firstIndex { $0.isEntry && $0.menuType == menu }.map { $0 + 1 }
    }
}

/// Parses a PGCIT (search pointers + PGCs). `base` is the table start; offsets in it are table-relative.
private func parsePGCTable(_ b: DVDBytes, at base: Int) -> [DVDPGCEntry] {
    guard let n = b.u16(base) else { return [] }
    var out: [DVDPGCEntry] = []
    for i in 0..<min(Int(n), 32767) {
        let srp = base + 8 + i * 8
        guard let cat = b.u32(srp), let off = b.u32(srp + 4),
              let pgc = DVDPGC.parse(b, at: base + Int(off)) else { break }
        out.append(DVDPGCEntry(category: cat, pgc: pgc))
    }
    return out
}

private func parseMenuTable(_ b: DVDBytes, at base: Int) -> [DVDMenuLanguageUnit] {
    guard let n = b.u16(base) else { return [] }
    var out: [DVDMenuLanguageUnit] = []
    for i in 0..<min(Int(n), 100) {
        let e = base + 8 + i * 8
        guard let l0 = b.u8(e), let l1 = b.u8(e + 1), let flags = b.u8(e + 3), let off = b.u32(e + 4) else { break }
        out.append(DVDMenuLanguageUnit(language: dvdLanguage(l0, l1), existenceFlags: flags,
                                       pgcs: parsePGCTable(b, at: base + Int(off))))
    }
    return out
}

/// C_ADT entry: where a cell (VOB id + cell id) lives in its VOBS.
struct DVDCellAddress: Equatable, Sendable {
    let vobID: Int
    let cellID: Int
    let startSector: UInt32
    let endSector: UInt32
}

private func parseCellAddressTable(_ b: DVDBytes, at base: Int) -> [DVDCellAddress] {
    guard let end = b.u32(base + 4) else { return [] }
    let count = max(0, (Int(end) + 1 - 8) / 12)
    return (0..<min(count, 65535)).compactMap { i in
        let e = base + 8 + i * 12
        guard let vob = b.u16(e), let cell = b.u8(e + 2), let s = b.u32(e + 4), let t = b.u32(e + 8) else { return nil }
        return DVDCellAddress(vobID: Int(vob), cellID: Int(cell), startSector: s, endSector: t)
    }
}

private func parseVOBUAddressMap(_ b: DVDBytes, at base: Int) -> [UInt32] {
    guard let end = b.u32(base) else { return [] }
    let count = max(0, (Int(end) + 1 - 4) / 4)
    return (0..<min(count, 1 << 22)).compactMap { b.u32(base + 4 + $0 * 4) }
}

/// Reads a sector pointer field and returns the byte offset of the table, or nil when absent / out of range.
private func tableOffset(_ b: DVDBytes, field: Int) -> Int? {
    guard let s = b.u32(field), s > 0 else { return nil }
    let o = Int(s) * 2048
    return b.has(o, 8) ? o : nil
}

// MARK: - VMGI

/// A TT_SRPT entry: one user-visible title.
struct DVDTitleEntry: Equatable, Sendable {
    let titleType: UInt8
    let angleCount: Int
    let pttCount: Int
    let parentalMask: UInt16
    let vtsn: Int
    let vtsTitle: Int
    let vtsStartSector: UInt32

    /// UOP0 / UOP1 from the title type byte.
    var prohibitedOperations: DVDUserOperations { DVDUserOperations(rawValue: UInt32(titleType & 0x03)) }
}

/// The Video Manager (VIDEO_TS.IFO).
struct DVDVMGI: Equatable, Sendable {
    let titleSetCount: Int
    /// Byte 1 of VMG_CAT: regions the disc is NOT allowed to play in (bit 0 = region 1).
    let prohibitedRegionMask: UInt8
    let firstPlayPGC: DVDPGC?
    /// VMGM VOBS (VIDEO_TS.VOB) start sector relative to the IFO, 0 when the disc has no VMG menus.
    let menuVOBSSector: UInt32
    let titles: [DVDTitleEntry]
    let menus: [DVDMenuLanguageUnit]
    let menuCellAddresses: [DVDCellAddress]
    let menuVOBUAddresses: [UInt32]
    let menuAttributes: DVDStreamAttributes?

    static let magic = Array("DVDVIDEO-VMG".utf8)

    static func parse(_ data: [UInt8]) -> DVDVMGI? {
        let b = DVDBytes(data)
        guard b.slice(0, 12) == magic else { return nil }
        let fpOffset = Int(b.u32(0x84) ?? 0)
        var titles: [DVDTitleEntry] = []
        if let tt = tableOffset(b, field: 0xC4), let n = b.u16(tt) {
            for i in 0..<min(Int(n), 99) {
                let e = tt + 8 + i * 12
                guard let type = b.u8(e), let ang = b.u8(e + 1), let ptts = b.u16(e + 2),
                      let mask = b.u16(e + 4), let vtsn = b.u8(e + 6), let ttn = b.u8(e + 7),
                      let start = b.u32(e + 8) else { break }
                titles.append(DVDTitleEntry(titleType: type, angleCount: Int(ang), pttCount: Int(ptts),
                                            parentalMask: mask, vtsn: Int(vtsn), vtsTitle: Int(ttn),
                                            vtsStartSector: start))
            }
        }
        return DVDVMGI(
            titleSetCount: Int(b.u16(0x3E) ?? 0),
            prohibitedRegionMask: b.u8(0x23) ?? 0,
            firstPlayPGC: fpOffset > 0 ? DVDPGC.parse(b, at: fpOffset) : nil,
            menuVOBSSector: b.u32(0xC0) ?? 0,
            titles: titles,
            menus: tableOffset(b, field: 0xC8).map { parseMenuTable(b, at: $0) } ?? [],
            menuCellAddresses: tableOffset(b, field: 0xD8).map { parseCellAddressTable(b, at: $0) } ?? [],
            menuVOBUAddresses: tableOffset(b, field: 0xDC).map { parseVOBUAddressMap(b, at: $0) } ?? [],
            menuAttributes: DVDStreamAttributes(b, base: 0x100, maxSubpictures: 1))
    }
}

// MARK: - VTSI

/// A VTS_PTT entry: chapter -> (PGC, program).
struct DVDPTT: Equatable, Sendable {
    let pgcn: Int
    let pgn: Int
}

/// One PGC's VTS_TMAPT: entries at tmu, 2*tmu, ... seconds on the PGC clock.
struct DVDTimeMap: Equatable, Sendable {
    let intervalSeconds: Int
    /// Bit 31 marks a discontinuity; the remaining bits are a VOB-set sector address.
    let entries: [UInt32]

    static func parseTable(_ b: DVDBytes, at base: Int) -> [DVDTimeMap] {
        guard let count = b.u16(base), let lastByte = b.u32(base + 4),
              b.has(base, Int(lastByte) + 1), Int(lastByte) + 1 >= 8 + Int(count) * 4 else { return [] }
        var maps: [DVDTimeMap] = []
        for i in 0..<Int(count) {
            guard let offset = b.u32(base + 8 + i * 4) else { return [] }
            let start = base + Int(offset)
            guard Int(offset) >= 8 + Int(count) * 4, start + 4 <= base + Int(lastByte) + 1,
                  let interval = b.u8(start), interval > 0, let entries = b.u16(start + 2),
                  start + 4 + Int(entries) * 4 <= base + Int(lastByte) + 1 else {
                maps.append(DVDTimeMap(intervalSeconds: 0, entries: []))
                continue
            }
            maps.append(DVDTimeMap(intervalSeconds: Int(interval), entries:
                (0..<Int(entries)).compactMap { b.u32(start + 4 + $0 * 4) }))
        }
        return maps
    }
}

/// A Video Title Set (VTS_nn_0.IFO).
struct DVDVTSI: Equatable, Sendable {
    let menuVOBSSector: UInt32
    let titleVOBSSector: UInt32
    /// ptts[vtsTitle - 1][ptt - 1].
    let ptts: [[DVDPTT]]
    let titlePGCs: [DVDPGCEntry]
    var titleTimeMaps: [DVDTimeMap] = []
    let menus: [DVDMenuLanguageUnit]
    let menuCellAddresses: [DVDCellAddress]
    let menuVOBUAddresses: [UInt32]
    let titleCellAddresses: [DVDCellAddress]
    let titleVOBUAddresses: [UInt32]
    let menuAttributes: DVDStreamAttributes?
    let titleAttributes: DVDStreamAttributes?

    static let magic = Array("DVDVIDEO-VTS".utf8)

    static func parse(_ data: [UInt8]) -> DVDVTSI? {
        let b = DVDBytes(data)
        guard b.slice(0, 12) == magic else { return nil }
        var ptts: [[DVDPTT]] = []
        if let base = tableOffset(b, field: 0xC8), let n = b.u16(base), let end = b.u32(base + 4) {
            let count = min(Int(n), 99)
            let offsets = (0..<count).compactMap { b.u32(base + 8 + $0 * 4).map(Int.init) }
            for (i, off) in offsets.enumerated() {
                let stop = i + 1 < offsets.count ? offsets[i + 1] : Int(end) + 1
                let entries = max(0, (stop - off) / 4)
                ptts.append((0..<min(entries, 999)).compactMap { j in
                    guard let pgcn = b.u16(base + off + j * 4), let pgn = b.u16(base + off + j * 4 + 2) else { return nil }
                    return DVDPTT(pgcn: Int(pgcn), pgn: Int(pgn))
                })
            }
        }
        return DVDVTSI(
            menuVOBSSector: b.u32(0xC0) ?? 0,
            titleVOBSSector: b.u32(0xC4) ?? 0,
            ptts: ptts,
            titlePGCs: tableOffset(b, field: 0xCC).map { parsePGCTable(b, at: $0) } ?? [],
            titleTimeMaps: tableOffset(b, field: 0xD4).map { DVDTimeMap.parseTable(b, at: $0) } ?? [],
            menus: tableOffset(b, field: 0xD0).map { parseMenuTable(b, at: $0) } ?? [],
            menuCellAddresses: tableOffset(b, field: 0xD8).map { parseCellAddressTable(b, at: $0) } ?? [],
            menuVOBUAddresses: tableOffset(b, field: 0xDC).map { parseVOBUAddressMap(b, at: $0) } ?? [],
            titleCellAddresses: tableOffset(b, field: 0xE0).map { parseCellAddressTable(b, at: $0) } ?? [],
            titleVOBUAddresses: tableOffset(b, field: 0xE4).map { parseVOBUAddressMap(b, at: $0) } ?? [],
            menuAttributes: DVDStreamAttributes(b, base: 0x100, maxSubpictures: 1),
            titleAttributes: DVDStreamAttributes(b, base: 0x200, maxSubpictures: 32))
    }

    /// The entry PGC (1-based) for VTS title `vtsTitle`: the PGCIT entry flagged as that title's entry,
    /// falling back to the PGC of the title's first PTT.
    func entryPGCN(forTitle vtsTitle: Int) -> Int? {
        if let i = titlePGCs.firstIndex(where: { $0.isEntry && $0.titleNumber == vtsTitle }) { return i + 1 }
        guard ptts.indices.contains(vtsTitle - 1), let first = ptts[vtsTitle - 1].first else { return nil }
        return first.pgcn
    }
}

// MARK: - Whole disc

/// The navigation data of a whole DVD-Video volume: the VMGI plus every VTSI, keyed by VTS number.
struct DVDNavigationData: Equatable, Sendable {
    let vmgi: DVDVMGI
    let titleSets: [Int: DVDVTSI]

    /// Loads from a file fetcher (`"VIDEO_TS.IFO"` / `"VTS_01_0.IFO"` -> bytes). Falls back to the .BUP
    /// backup copy when an IFO is unreadable, like a hardware player. Returns nil without a usable VMGI.
    static func load(readFile: (String) -> [UInt8]?) -> DVDNavigationData? {
        func ifo(_ stem: String) -> [UInt8]? { readFile(stem + ".IFO") ?? readFile(stem + ".BUP") }
        guard let vmgi = ifo("VIDEO_TS").flatMap(DVDVMGI.parse) ?? readFile("VIDEO_TS.BUP").flatMap(DVDVMGI.parse)
        else { return nil }
        var sets: [Int: DVDVTSI] = [:]
        let count = max(vmgi.titleSetCount, vmgi.titles.map(\.vtsn).max() ?? 0)
        for n in 1...max(1, min(count, 99)) {
            let stem = String(format: "VTS_%02d_0", n)
            if let v = readFile(stem + ".IFO").flatMap(DVDVTSI.parse) ?? readFile(stem + ".BUP").flatMap(DVDVTSI.parse) {
                sets[n] = v
            }
        }
        return DVDNavigationData(vmgi: vmgi, titleSets: sets)
    }

    /// Loads from a DVD-Video ISO through the engine's ISO9660 reader.
    static func load(iso reader: IOReader) throws -> DVDNavigationData? {
        let iso = try ISO9660Reader(reader: reader)
        let files = try iso.list(directory: "VIDEO_TS")
        return load { name in
            guard let f = files.first(where: { $0.name.uppercased() == name }) else { return nil }
            let bytes = DiscReader.readAll(reader, [(offset: Int64(f.startSector * iso.sectorSize), length: Int64(f.length))])
            return bytes.isEmpty ? nil : bytes
        }
    }
}
