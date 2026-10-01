import Foundation

// NAV pack (PCI + DSI) parsing for DVD-Video menus (clean-room; layouts from dvd.sourceforge.net
// pci_pkt.html / dsi_pkt.html and mpucoder.com/DVD/pci_pkt.html / dsi_pkt.html).
//
// Every VOBU starts with a 2048-byte NAV pack: pack header, system header, then two private-stream-2
// packets. PCI (substream 0x00) starts at sector offset 0x26 with its payload at 0x2D; DSI (substream
// 0x01) starts at 0x400 with its payload at 0x407.

/// One selection/action colour scheme (SL_COLI): palette index + contrast per pixel code (0 = background,
/// 1 = pattern, 2 = emphasis 1, 3 = emphasis 2).
struct DVDButtonColors: Equatable, Sendable {
    let selectionColor: [UInt8]       // indexed by pixel code 0...3
    let selectionContrast: [UInt8]
    let actionColor: [UInt8]
    let actionContrast: [UInt8]

    init(raw: [UInt8]) {
        // Each byte holds two nibbles: high = the higher pixel code of the pair, low = the lower.
        func pair(_ hi: UInt8, _ lo: UInt8) -> [UInt8] { [lo & 0x0F, lo >> 4, hi & 0x0F, hi >> 4] }
        // byte 0: e2 | e1, byte 1: pattern | background  ->  [bg, pattern, e1, e2]
        selectionColor = pair(raw[0], raw[1])
        selectionContrast = pair(raw[2], raw[3])
        actionColor = pair(raw[4], raw[5])
        actionContrast = pair(raw[6], raw[7])
    }
}

/// One BTN_IT entry.
struct DVDButton: Equatable, Sendable {
    /// 1-based button number within its group.
    private(set) var number: Int
    /// Colour scheme 1-3 (SL_COLI index + 1); 0 = none.
    let colorScheme: Int
    let x0: Int, x1: Int, y0: Int, y1: Int
    let autoAction: Bool
    let up: Int, down: Int, left: Int, right: Int
    var command: DVDCommand

    init?(number: Int, raw: [UInt8]) {
        guard raw.count == 18 else { return nil }
        self.number = number
        colorScheme = Int(raw[0] >> 6)
        x0 = Int(raw[0] & 0x3F) << 4 | Int(raw[1] >> 4)
        x1 = Int(raw[1] & 0x03) << 8 | Int(raw[2])
        autoAction = raw[3] & 0x80 != 0
        y0 = Int(raw[3] & 0x3F) << 4 | Int(raw[4] >> 4)
        y1 = Int(raw[4] & 0x03) << 8 | Int(raw[5])
        up = Int(raw[6] & 0x3F); down = Int(raw[7] & 0x3F)
        left = Int(raw[8] & 0x3F); right = Int(raw[9] & 0x3F)
        command = DVDCommand(Array(raw[10..<18]))
    }

    /// The same slot data under a group-relative number.
    func renumbered(_ n: Int) -> DVDButton {
        var copy = self
        copy.number = n
        return copy
    }

    func contains(x: Int, y: Int) -> Bool { x >= x0 && x <= x1 && y >= y0 && y <= y1 }
}

/// Highlight information (HLI) from a PCI packet.
struct DVDHighlightInfo: Equatable, Sendable {
    /// 0 = no highlight info in this VOBU, 1 = all new, 2 = same as previous VOBU,
    /// 3 = previous VOBU's except the commands, which come from this one.
    let status: Int
    let startPTM: UInt32
    let endPTM: UInt32
    let buttonSelectEndPTM: UInt32
    /// Button groups (1-3) and each group's display type bits (bit 0 normal, bit 1 letterbox, bit 2 pan&scan).
    let groupCount: Int
    let groupTypes: [Int]
    let startButton: Int
    let buttonCount: Int
    let numericSelectCount: Int
    let forcedSelectButton: Int
    let forcedActionButton: Int
    let colors: [DVDButtonColors]       // 3 schemes
    /// All 36 raw BTN_IT slots, in table order.
    let slots: [DVDButton]

    /// The buttons of group `group` (1-based). The 36 BTN_IT slots are split evenly between the declared
    /// groups (36 / 18+18 / 12+12+12); each group lists `buttonCount` buttons.
    func buttons(group: Int = 1) -> [DVDButton] {
        let groups = max(1, min(groupCount, 3))
        let g = max(1, min(group, groups))
        let perGroup = 36 / groups
        let start = (g - 1) * perGroup
        let n = max(0, min(buttonCount, perGroup))
        return (0..<n).compactMap { i in
            slots.indices.contains(start + i) ? slots[start + i].renumbered(i + 1) : nil
        }
    }

    /// The group to use for a display mode: 0 = normal (4:3 or 16:9 native), 1 = letterbox, 2 = pan&scan.
    func group(forDisplayMode mode: Int) -> Int {
        let bit = 1 << max(0, min(mode, 2))
        if let i = groupTypes.prefix(max(1, groupCount)).firstIndex(where: { $0 & bit != 0 }) { return i + 1 }
        return 1
    }
}

/// Presentation Control Information.
struct DVDPCI: Equatable, Sendable {
    let navPackLBN: UInt32
    let vobuCategory: UInt16
    let prohibitedOperations: DVDUserOperations
    let vobuStartPTM: UInt32
    let vobuEndPTM: UInt32
    let vobuSequenceEndPTM: UInt32
    let cellElapsed: DVDTime?
    /// Non-seamless angle offsets (9), bit 31 = backward.
    let nonSeamlessAngles: [UInt32]
    let highlight: DVDHighlightInfo

    /// `payload` is the PCI data after the substream id (979 bytes in a well-formed NAV pack).
    static func parse(payload p: [UInt8]) -> DVDPCI? {
        let b = DVDBytes(p)
        guard b.has(0, 0x8E + 36 * 18), let lbn = b.u32(0), let cat = b.u16(4), let uop = b.u32(8),
              let sptm = b.u32(0x0C), let eptm = b.u32(0x10), let septm = b.u32(0x14),
              let hss = b.u16(0x60), let hs = b.u32(0x62), let he = b.u32(0x66), let bse = b.u32(0x6A),
              let md = b.u16(0x6E), let sn = b.u8(0x70), let ns = b.u8(0x71), let nsl = b.u8(0x72),
              let fosl = b.u8(0x74), let foac = b.u8(0x75) else { return nil }
        let colors = (0..<3).compactMap { b.slice(0x76 + $0 * 8, 8).map(DVDButtonColors.init) }
        let slots = (0..<36).compactMap { i in b.slice(0x8E + i * 18, 18).flatMap { DVDButton(number: i + 1, raw: $0) } }
        let hli = DVDHighlightInfo(
            status: Int(hss & 0x3), startPTM: hs, endPTM: he, buttonSelectEndPTM: bse,
            groupCount: Int(md >> 12) & 0x3,
            groupTypes: [Int(md >> 8) & 0x7, Int(md >> 4) & 0x7, Int(md) & 0x7],
            startButton: Int(sn), buttonCount: Int(ns), numericSelectCount: Int(nsl),
            forcedSelectButton: Int(fosl), forcedActionButton: Int(foac), colors: colors, slots: slots)
        return DVDPCI(navPackLBN: lbn, vobuCategory: cat, prohibitedOperations: DVDUserOperations(rawValue: uop),
                      vobuStartPTM: sptm, vobuEndPTM: eptm, vobuSequenceEndPTM: septm,
                      cellElapsed: DVDTime(b, 0x18),
                      nonSeamlessAngles: (0..<9).compactMap { b.u32(0x3C + $0 * 4) }, highlight: hli)
    }
}

/// Data Search Information.
struct DVDDSI: Equatable, Sendable {
    let navPackSCR: UInt32
    let navPackLBN: UInt32
    /// Relative sector of the VOBU's last sector.
    let vobuEndAddress: UInt32
    let firstRefEnd: UInt32, secondRefEnd: UInt32, thirdRefEnd: UInt32
    let vobID: Int
    let cellID: Int
    let cellElapsed: DVDTime?
    /// Seamless playback info.
    let ilvuFlags: UInt16
    let ilvuEndAddress: UInt32
    let nextILVUStart: UInt32
    let nextILVUSize: UInt16
    let vobVideoStartPTM: UInt32
    let vobVideoEndPTM: UInt32
    /// Seamless angle offsets / sizes (9 each).
    let seamlessAngleOffsets: [UInt32]
    let seamlessAngleSizes: [UInt16]
    /// VOBU search info: next VOBU with video, 19 forward jumps (120 s ... 0.5 s), next, previous,
    /// 19 backward jumps (0.5 s ... 120 s), previous VOBU with video. Raw values (bit 31 = valid).
    let nextVideoVOBU: UInt32
    let forward: [UInt32]
    let nextVOBU: UInt32
    let previousVOBU: UInt32
    let backward: [UInt32]
    let previousVideoVOBU: UInt32
    let audioSync: [UInt16]
    let subpictureSync: [UInt32]

    /// Offset in sectors from a VOBU_SRI pointer: nil when the valid bit is clear or it is a "none" sentinel.
    static func searchOffset(_ raw: UInt32) -> Int? {
        guard raw & 0x8000_0000 != 0, raw != 0xBFFF_FFFF else { return nil }
        return Int(raw & 0x3FFF_FFFF)
    }

    /// Sectors from this NAV pack to the next VOBU, when there is one.
    var nextVOBUOffset: Int? { DVDDSI.searchOffset(nextVOBU) }

    /// Last VOBU of the cell: no next-VOBU pointer.
    var isLastVOBUInCell: Bool { nextVOBU == 0x3FFF_FFFF }

    /// `payload` is the DSI data after the substream id (1017 bytes in a well-formed NAV pack).
    static func parse(payload p: [UInt8]) -> DVDDSI? {
        let b = DVDBytes(p)
        guard b.has(0, 0x222), let scr = b.u32(0), let lbn = b.u32(4), let ea = b.u32(8),
              let r1 = b.u32(0x0C), let r2 = b.u32(0x10), let r3 = b.u32(0x14),
              let vob = b.u16(0x18), let cell = b.u8(0x1B), let ilvu = b.u16(0x20),
              let ilvuEA = b.u32(0x22), let nsa = b.u32(0x26), let nsz = b.u16(0x2A),
              let vs = b.u32(0x2C), let ve = b.u32(0x30), let nvwv = b.u32(0xEA),
              let nv = b.u32(0x13A), let pv = b.u32(0x13E), let pvwv = b.u32(0x18E) else { return nil }
        return DVDDSI(
            navPackSCR: scr, navPackLBN: lbn, vobuEndAddress: ea, firstRefEnd: r1, secondRefEnd: r2, thirdRefEnd: r3,
            vobID: Int(vob), cellID: Int(cell), cellElapsed: DVDTime(b, 0x1C),
            ilvuFlags: ilvu, ilvuEndAddress: ilvuEA, nextILVUStart: nsa, nextILVUSize: nsz,
            vobVideoStartPTM: vs, vobVideoEndPTM: ve,
            seamlessAngleOffsets: (0..<9).compactMap { b.u32(0xB4 + $0 * 6) },
            seamlessAngleSizes: (0..<9).compactMap { b.u16(0xB8 + $0 * 6) },
            nextVideoVOBU: nvwv,
            forward: (0..<19).compactMap { b.u32(0xEE + $0 * 4) },
            nextVOBU: nv, previousVOBU: pv,
            backward: (0..<19).compactMap { b.u32(0x142 + $0 * 4) },
            previousVideoVOBU: pvwv,
            audioSync: (0..<8).compactMap { b.u16(0x192 + $0 * 2) },
            subpictureSync: (0..<32).compactMap { b.u32(0x1A2 + $0 * 4) })
    }
}

/// A parsed NAV pack.
struct DVDNavPack: Equatable, Sendable {
    let pci: DVDPCI
    let dsi: DVDDSI

    static let sectorSize = 2048

    /// Parses one 2048-byte NAV sector. Validates both private-stream-2 start codes and substream ids.
    static func parse(sector s: [UInt8]) -> DVDNavPack? {
        guard s.count >= sectorSize,
              s[0x26] == 0, s[0x27] == 0, s[0x28] == 1, s[0x29] == 0xBF, s[0x2C] == 0x00,
              s[0x400] == 0, s[0x401] == 0, s[0x402] == 1, s[0x403] == 0xBF, s[0x406] == 0x01 else { return nil }
        let pciLen = Int(s[0x2A]) << 8 | Int(s[0x2B])          // includes the substream id byte
        let dsiLen = Int(s[0x404]) << 8 | Int(s[0x405])
        guard pciLen > 1, 0x2C + pciLen <= 0x400, dsiLen > 1, 0x406 + dsiLen <= sectorSize,
              let pci = DVDPCI.parse(payload: Array(s[0x2D ..< 0x2C + pciLen])),
              let dsi = DVDDSI.parse(payload: Array(s[0x407 ..< 0x406 + dsiLen])) else { return nil }
        return DVDNavPack(pci: pci, dsi: dsi)
    }

    /// True when a sector looks like a NAV pack (pack start code + PCI private stream 2 at 0x26).
    static func isNavPack(_ s: ArraySlice<UInt8>) -> Bool {
        let b = s.startIndex
        guard s.count >= 0x2D else { return false }
        return s[b] == 0 && s[b + 1] == 0 && s[b + 2] == 1 && s[b + 3] == 0xBA &&
            s[b + 0x26] == 0 && s[b + 0x27] == 0 && s[b + 0x28] == 1 && s[b + 0x29] == 0xBF && s[b + 0x2C] == 0
    }
}

// MARK: - Highlight navigation

/// Remote / keyboard directions for menu navigation.
enum DVDDirection: Sendable { case up, down, left, right }

/// Pure helpers for moving the highlight and hit-testing touches / pointer clicks against the buttons.
enum DVDHighlightNavigator {
    /// The button (1-based) selected after pressing `direction` from `current`. Returns `current` when
    /// the table has no neighbour in that direction.
    static func move(_ direction: DVDDirection, from current: Int, in buttons: [DVDButton]) -> Int {
        guard let b = buttons.first(where: { $0.number == current }) else { return buttons.first?.number ?? current }
        let target: Int
        switch direction {
        case .up: target = b.up
        case .down: target = b.down
        case .left: target = b.left
        case .right: target = b.right
        }
        return buttons.contains(where: { $0.number == target }) ? target : current
    }

    /// The button under a point in the menu's video coordinate space (e.g. 720x480), for touch / pointer input.
    static func button(atX x: Int, y: Int, in buttons: [DVDButton]) -> DVDButton? {
        buttons.first { $0.contains(x: x, y: y) }
    }
}
