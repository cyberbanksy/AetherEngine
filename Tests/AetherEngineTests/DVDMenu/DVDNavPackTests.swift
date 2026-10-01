import Foundation
import Testing
@testable import AetherEngine

/// PCI / DSI parsing against hand-built NAV sectors laid out per dvd.sourceforge.net pci_pkt.html /
/// dsi_pkt.html, plus the highlight navigation helpers.
struct DVDNavPackTests {
    /// A 2048-byte NAV sector: pack header, PCI at 0x26 (payload 0x2D), DSI at 0x400 (payload 0x407).
    private func navSector(pci: [Int: [UInt8]] = [:], dsi: [Int: [UInt8]] = [:]) -> [UInt8] {
        var s = [UInt8](repeating: 0, count: 2048)
        s.replaceSubrange(0..<4, with: [0x00, 0x00, 0x01, 0xBA])
        s.replaceSubrange(0x26..<0x2D, with: [0x00, 0x00, 0x01, 0xBF, 0x03, 0xD4, 0x00])
        s.replaceSubrange(0x400..<0x407, with: [0x00, 0x00, 0x01, 0xBF, 0x03, 0xFA, 0x01])
        for (o, bytes) in pci { s.replaceSubrange(0x2D + o ..< 0x2D + o + bytes.count, with: bytes) }
        for (o, bytes) in dsi { s.replaceSubrange(0x407 + o ..< 0x407 + o + bytes.count, with: bytes) }
        return s
    }

    private let buttonEntry: [UInt8] = [0x46, 0x40, 0xC8, 0x03, 0x20, 0x64, 0x02, 0x03, 0x04, 0x05,
                                        0x20, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02]

    @Test func buttonEntryGeometryNeighboursAndCommand() throws {
        let b = try #require(DVDButton(number: 1, raw: buttonEntry))
        #expect(b.colorScheme == 1)
        #expect(b.x0 == 100 && b.x1 == 200 && b.y0 == 50 && b.y1 == 100)
        #expect(!b.autoAction)
        #expect(b.up == 2 && b.down == 3 && b.left == 4 && b.right == 5)
        #expect(b.command.instruction == .link(.subset(.nextCell, button: 0)))
        var auto = buttonEntry
        auto[3] |= 0x80
        #expect(DVDButton(number: 1, raw: auto)?.autoAction == true)
        #expect(DVDButton(number: 1, raw: auto)?.y0 == 50)
    }

    @Test func colourSchemeNibbles() {
        let c = DVDButtonColors(raw: [0x03, 0x12, 0x0F, 0xF0, 0xF0, 0x0F, 0x03, 0x12])
        // index = pixel code: [background, pattern, emphasis 1, emphasis 2]
        #expect(c.selectionColor == [2, 1, 3, 0])
        #expect(c.selectionContrast == [0, 0xF, 0xF, 0])
        #expect(c.actionColor == [0xF, 0, 0, 0xF])
        #expect(c.actionContrast == [2, 1, 3, 0])
    }

    @Test func pciHighlightInformation() throws {
        var pci: [Int: [UInt8]] = [
            0x00: [0x00, 0x00, 0x00, 0x2A],                    // nv_pck_lbn
            0x08: [0x00, 0x00, 0x08, 0x00],                    // vobu_uop_ctl: UOP11 root menu call
            0x0C: [0x00, 0x00, 0x10, 0x00],                    // vobu_s_ptm
            0x10: [0x00, 0x00, 0x20, 0x00],                    // vobu_e_ptm
            0x18: [0x01, 0x02, 0x03, 0xC5],                    // c_eltm 01:02:03:05 @ 30
            0x60: [0x00, 0x01],                                // hli_ss: all new
            0x62: [0x00, 0x00, 0x00, 0x00], 0x66: [0xFF, 0xFF, 0xFF, 0xFF], 0x6A: [0x00, 0x00, 0x30, 0x00],
            0x6E: [0x21, 0x40],                                // 2 groups: group 1 normal, group 2 letterbox... (types 1, 4)
            0x70: [0x01, 0x02, 0x00, 0x00, 0x02, 0x00],       // start 1, 2 buttons, numeric 0, forced select 2
            0x76: [0x03, 0x12, 0x0F, 0xF0, 0xF0, 0x0F, 0x03, 0x12],
        ]
        pci[0x8E] = buttonEntry
        var second = buttonEntry
        second[10...17] = [0x30, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00]   // JumpTT 1
        pci[0x8E + 18] = second
        var g2 = buttonEntry
        g2[0] = 0x80; g2[1] = 0x00; g2[2] = 0x10                               // group 2 slot 1: scheme 2, x 0-16
        pci[0x8E + 18 * 18] = g2
        let nav = try #require(DVDNavPack.parse(sector: navSector(pci: pci, dsi: [0x08: [0, 0, 0, 0x0F]])))
        let p = nav.pci
        #expect(p.navPackLBN == 42)
        #expect(p.prohibitedOperations == .rootMenuCall)
        #expect(p.vobuStartPTM == 0x1000 && p.vobuEndPTM == 0x2000)
        #expect(p.cellElapsed == DVDTime(hours: 1, minutes: 2, seconds: 3, frames: 5, frameRate: 30))
        let h = p.highlight
        #expect(h.status == 1)
        #expect(h.endPTM == 0xFFFF_FFFF && h.buttonSelectEndPTM == 0x3000)
        #expect(h.groupCount == 2)
        #expect(h.groupTypes == [1, 4, 0])
        #expect(h.startButton == 1 && h.buttonCount == 2 && h.forcedSelectButton == 2 && h.forcedActionButton == 0)
        #expect(h.colors.count == 3 && h.colors[0].selectionColor == [2, 1, 3, 0])
        let group1 = h.buttons(group: 1)
        #expect(group1.map(\.number) == [1, 2])
        #expect(group1[1].command.instruction == .jump(.title(1)))
        let group2 = h.buttons(group: 2)
        #expect(group2.first?.colorScheme == 2 && group2.first?.x1 == 16)
        #expect(h.group(forDisplayMode: 0) == 1)
        #expect(h.group(forDisplayMode: 2) == 2)        // pan&scan bit (4) is on group 2
        #expect(nav.dsi.vobuEndAddress == 15)
    }

    @Test func dsiSearchInformation() throws {
        let dsi: [Int: [UInt8]] = [
            0x00: [0x00, 0x00, 0x12, 0x34],              // nv_pck_scr
            0x04: [0x00, 0x00, 0x00, 0x2A],              // nv_pck_lbn
            0x08: [0x00, 0x00, 0x00, 0x2A],              // vobu_ea
            0x18: [0x00, 0x03], 0x1B: [0x02],            // vob 3, cell 2
            0x1C: [0x00, 0x00, 0x10, 0x45],              // c_eltm 00:00:10:05 @ 25
            0x20: [0xA0, 0x00],                          // ilvu: PREU + Unit_Start
            0x26: [0xFF, 0xFF, 0xFF, 0xFF], 0x2A: [0xFF, 0xFF],
            0xB4: [0x80, 0x00, 0x00, 0x05], 0xB8: [0x00, 0x09],     // seamless angle 1: backward 5, 9 sectors
            0xEA: [0xBF, 0xFF, 0xFF, 0xFF],              // no following VOBU with video
            0xEE: [0x80, 0x00, 0x01, 0x00],              // fwd 120 s: +256
            0x13A: [0x80, 0x00, 0x00, 0x0A],             // next VOBU +10
            0x13E: [0x3F, 0xFF, 0xFF, 0xFF],             // no previous VOBU
            0x192: [0x3F, 0xFF],                         // audio 0: no more audio
            0x1A2: [0x7F, 0xFF, 0xFF, 0xFF],
        ]
        let d = try #require(DVDNavPack.parse(sector: navSector(dsi: dsi))).dsi
        #expect(d.navPackSCR == 0x1234 && d.navPackLBN == 42 && d.vobuEndAddress == 42)
        #expect(d.vobID == 3 && d.cellID == 2)
        #expect(d.cellElapsed == DVDTime(hours: 0, minutes: 0, seconds: 10, frames: 5, frameRate: 25))
        #expect(d.ilvuFlags == 0xA000)
        #expect(d.nextILVUStart == 0xFFFF_FFFF && d.nextILVUSize == 0xFFFF)
        #expect(d.seamlessAngleOffsets.first == 0x8000_0005 && d.seamlessAngleSizes.first == 9)
        #expect(DVDDSI.searchOffset(d.nextVideoVOBU) == nil)
        #expect(DVDDSI.searchOffset(d.forward[0]) == 256)
        #expect(d.nextVOBUOffset == 10)
        #expect(!d.isLastVOBUInCell)
        #expect(DVDDSI.searchOffset(d.previousVOBU) == nil)
        #expect(d.audioSync.first == 0x3FFF)
        #expect(d.subpictureSync.first == 0x7FFF_FFFF)
        #expect(d.forward.count == 19 && d.backward.count == 19 && d.subpictureSync.count == 32)
    }

    @Test func rejectsNonNavSectors() {
        var s = navSector()
        s[0x2C] = 0x01                                    // PCI substream id must be 0
        #expect(DVDNavPack.parse(sector: s) == nil)
        #expect(DVDNavPack.parse(sector: [UInt8](repeating: 0, count: 100)) == nil)
        #expect(DVDNavPack.isNavPack(navSector()[...]))
        #expect(!DVDNavPack.isNavPack(s[...]))
    }

    @Test func highlightNavigationAndHitTesting() throws {
        func b(_ n: Int, y: Int, up: Int, down: Int) -> DVDButton {
            var raw = [UInt8](repeating: 0, count: 18)
            raw[0] = 0x40 | UInt8(100 >> 4); raw[1] = UInt8((100 & 0xF) << 4) | UInt8(300 >> 8); raw[2] = UInt8(300 & 0xFF)
            raw[3] = UInt8(y >> 4); raw[4] = UInt8((y & 0xF) << 4) | UInt8((y + 60) >> 8); raw[5] = UInt8((y + 60) & 0xFF)
            raw[6] = UInt8(up); raw[7] = UInt8(down); raw[8] = UInt8(n); raw[9] = UInt8(n)
            return DVDButton(number: n, raw: raw)!
        }
        let buttons = [b(1, y: 100, up: 3, down: 2), b(2, y: 200, up: 1, down: 3), b(3, y: 300, up: 2, down: 1)]
        #expect(DVDHighlightNavigator.move(.down, from: 1, in: buttons) == 2)
        #expect(DVDHighlightNavigator.move(.up, from: 1, in: buttons) == 3)
        #expect(DVDHighlightNavigator.move(.left, from: 2, in: buttons) == 2)
        #expect(DVDHighlightNavigator.move(.down, from: 9, in: buttons) == 1)     // unknown current -> first button
        #expect(DVDHighlightNavigator.button(atX: 150, y: 230, in: buttons)?.number == 2)
        #expect(DVDHighlightNavigator.button(atX: 50, y: 230, in: buttons) == nil)
    }
}
