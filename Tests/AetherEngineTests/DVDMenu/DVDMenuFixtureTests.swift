import Foundation
import Testing
@testable import AetherEngine

/// End-to-end over a real authored disc: Tests/Fixtures/dvd/menu-test.iso, built by
/// Tests/Fixtures/dvd/make-menu-fixture.sh with dvdauthor + spumux (see menu-test.xml beside it).
/// Assertions are structural (domains, PGCs, cells, commands), not absolute sector numbers.
struct DVDMenuFixtureTests {
    private static let isoURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // DVDMenu
        .deletingLastPathComponent()      // AetherEngineTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures/dvd/menu-test.iso")

    private func load() throws -> (DVDNavigationData, IOReader) {
        let reader = try #require(FileIOReader(url: Self.isoURL), "missing fixture \(Self.isoURL.path)")
        let nav = try #require(try DVDNavigationData.load(iso: reader))
        return (nav, reader)
    }

    /// The first sector of a VOB file inside the ISO (its first NAV pack).
    private func firstNavPack(_ name: String, _ reader: IOReader) throws -> DVDNavPack {
        let iso = try ISO9660Reader(reader: reader)
        let file = try #require(try iso.list(directory: "VIDEO_TS").first { $0.name == name })
        let sector = DiscReader.readAll(reader, [(offset: Int64(file.startSector * iso.sectorSize), length: 2048)])
        return try #require(DVDNavPack.parse(sector: sector))
    }

    // MARK: IFO

    @Test func vmgiStructure() throws {
        let (nav, _) = try load()
        let v = nav.vmgi
        #expect(v.titleSetCount == 1)
        #expect(v.titles.map(\.vtsn) == [1, 1])
        #expect(v.titles.map(\.vtsTitle) == [1, 2])
        #expect(v.titles.map(\.pttCount) == [2, 1])
        #expect(v.menuVOBSSector > 0)
        // FP: g1 = 1; JumpSS VMGM pgc 1
        let fp = try #require(v.firstPlayPGC)
        #expect(fp.cells.isEmpty)
        #expect(fp.preCommands.map(\.instruction) == [
            .set(DVDSetOperation(op: .mov, gprm: 1, source: .immediate(1)), then: nil),
            .jump(.vmgmPGC(1)),
        ])
        // One English language unit holding the title menu.
        #expect(v.menus.count == 1)
        let lu = try #require(v.menus.first)
        #expect(lu.language == "en")
        #expect(lu.entryPGCN(for: DVDMenuType.title.rawValue) == 1)
        let menu = lu.pgcs[0].pgc
        #expect(menu.cells.count == 1 && menu.cells[0].stillTime == 255)
        #expect(menu.preCommands.first?.instruction == .system(.highlightButton(.immediate(1024)), then: nil))
        // dvdauthor multiplexes button 3 through the post commands: g14 = g15; g15 = 0; if g14 == 3 goto 5;
        // exit; g2 = 7; JumpTT 2.
        #expect(menu.postCommands.count == 6)
        #expect(menu.postCommands[2].condition == DVDCondition(op: .equal, lhs: .gprm(14), rhs: .immediate(3)))
        #expect(menu.postCommands[2].instruction == .goto(line: 5))
        #expect(menu.postCommands[5].instruction == .jump(.title(2)))
        #expect(v.menuCellAddresses.count == 1)
        #expect(v.menuVOBUAddresses.count >= 2)
        #expect(v.menuAttributes?.video.isPAL == false)
        #expect(v.menuAttributes?.video.size.width == 720)
    }

    @Test func vtsiStructure() throws {
        let (nav, _) = try load()
        let t = try #require(nav.titleSets[1])
        #expect(t.ptts == [[DVDPTT(pgcn: 1, pgn: 1), DVDPTT(pgcn: 1, pgn: 2)], [DVDPTT(pgcn: 2, pgn: 1)]])
        #expect(t.titlePGCs.count == 2)
        #expect(t.titlePGCs.map(\.isEntry) == [true, true])
        #expect(t.titlePGCs.map(\.titleNumber) == [1, 2])
        let title1 = t.titlePGCs[0].pgc
        #expect(title1.programCount == 2 && title1.cells.count == 2 && title1.programMap == [1, 2])
        #expect(title1.postCommands.map(\.instruction) == [.jump(.callVMGMPGC(pgcn: 1, resumeCell: 1))])
        #expect(title1.cells[0].firstVOBUStart == 0)
        #expect(title1.cells[1].firstVOBUStart > title1.cells[0].lastVOBUEnd)
        #expect(title1.cellPositions.map(\.cellID) == [1, 2])
        let title2 = t.titlePGCs[1].pgc
        #expect(title2.postCommands.map(\.instruction) == [
            .goto(line: 3), .jump(.callVTSMenu(menu: 7, resumeCell: 1)), .jump(.callVMGMPGC(pgcn: 1, resumeCell: 1)),
        ])
        // VTSM: root menu (entry type 3) plus dvdauthor's chapter-menu stub (entry type 7 -> LinkPGCN 1).
        let lu = try #require(t.menus.first)
        #expect(lu.entryPGCN(for: DVDMenuType.root.rawValue) == 1)
        #expect(lu.entryPGCN(for: DVDMenuType.chapter.rawValue) == 2)
        #expect(lu.pgcs[1].pgc.preCommands.map(\.instruction) == [.link(.pgcn(1))])
        #expect(t.titleCellAddresses.count == 3)
        #expect(t.titleCellAddresses.map(\.vobID) == [1, 1, 2])
        #expect(t.titleVOBUAddresses.count >= 4)
        #expect(t.titleAttributes?.audio.count == 1)
        #expect(t.titleAttributes?.audio.first?.channels == 2)
        #expect(nav.mainTitle == 1)
        #expect(nav.hasMenus)
    }

    @Test func bupFallbackWhenTheIFOIsUnreadable() throws {
        let reader = try #require(FileIOReader(url: Self.isoURL))
        let iso = try ISO9660Reader(reader: reader)
        let files = try iso.list(directory: "VIDEO_TS")
        let nav = DVDNavigationData.load { name in
            guard name != "VIDEO_TS.IFO", let f = files.first(where: { $0.name == name }) else { return nil }
            return DiscReader.readAll(reader, [(offset: Int64(f.startSector * 2048), length: Int64(f.length))])
        }
        #expect(nav?.vmgi.titles.count == 2)
    }

    // MARK: NAV packs

    @Test func menuNavPacksCarryTheButtons() throws {
        let (_, reader) = try load()
        let vmgm = try firstNavPack("VIDEO_TS.VOB", reader)
        #expect(vmgm.pci.highlight.status == 1)
        #expect(vmgm.dsi.vobID == 1 && vmgm.dsi.cellID == 1)
        #expect(vmgm.dsi.nextVOBUOffset != nil)
        let buttons = vmgm.pci.highlight.buttons()
        #expect(buttons.count == 3)
        #expect(buttons.map(\.y0) == [100, 200, 300])
        #expect(buttons.map(\.x0) == [100, 100, 100])
        #expect(buttons.map(\.down) == [2, 3, 1])
        #expect(buttons.map(\.up) == [3, 1, 2])
        #expect(buttons[0].command.instruction == .jump(.title(1)))
        #expect(buttons[1].command.instruction == .jump(.vtsMenu(vts: 1, title: 1, menu: 3)))
        #expect(buttons[2].command.instruction ==
            .set(DVDSetOperation(op: .mov, gprm: 15, source: .immediate(3)), then: .subset(.tailPGC, button: 0)))
        #expect(DVDHighlightNavigator.move(.down, from: 1, in: buttons) == 2)
        #expect(DVDHighlightNavigator.button(atX: 200, y: 330, in: buttons)?.number == 3)

        let vtsm = try firstNavPack("VTS_01_0.VOB", reader)
        #expect(vtsm.pci.highlight.buttons().map(\.command.instruction) == [
            .jump(.vtsPTT(title: 1, ptt: 1)), .jump(.vtsPTT(title: 1, ptt: 2)), .jump(.vmgmPGC(1)),
        ])
        let title = try firstNavPack("VTS_01_1.VOB", reader)
        #expect(title.pci.highlight.status == 0)          // titles carry no highlight info
    }

    // MARK: The VM on the authored disc

    @Test func firstPlayToMenuToTitleAndBack() throws {
        let (nav, reader) = try load()
        let vm = DVDVirtualMachine(navigation: nav)
        var s = vm.initialState()
        let vmgmButtons = try firstNavPack("VIDEO_TS.VOB", reader).pci.highlight.buttons()

        // Disc insert: FP sets g1 and jumps to the VMGM title menu, which highlights button 1.
        let menu = vm.handle(&s, .start)
        #expect(s.gprm[1] == 1)
        #expect(menu.target?.domain == .vmgMenu && menu.target?.vobs == .vmgMenu && menu.target?.cellNumber == 1)
        #expect(s.highlightedButton == 1)
        // The menu cell ends into an infinite still: the menu waits for the user.
        #expect(vm.handle(&s, .cellPlaybackEnded) == .still(seconds: nil))

        // Arrow down, then up wraps: highlight bookkeeping is the host's NAV-pack job, the VM keeps SPRM 8.
        let next = DVDHighlightNavigator.move(.down, from: s.highlightedButton, in: vmgmButtons)
        _ = vm.handle(&s, .selectButton(next))
        #expect(s.highlightedButton == 2)

        // Activate button 1: "Play" -> title 1, cell 1.
        let play = vm.handle(&s, .activateButton(vmgmButtons[0]))
        #expect(play.target?.domain == .title && play.target?.vobs == .title(vts: 1))
        #expect(play.target?.pgcn == 1 && play.target?.cellNumber == 1)
        #expect(s.sprm[4] == 1 && s.sprm[5] == 1 && s.sprm[7] == 1)
        #expect(s.highlightedButton == 1)

        // Chapter 2 starts at cell 2; SPRM 7 follows.
        let cell2 = vm.handle(&s, .cellPlaybackEnded)
        #expect(cell2.target?.cellNumber == 2)
        #expect(s.sprm[7] == 2)

        // Title end: post command CallSS VMGM pgc 1 (resume cell 1) -> back on the menu with a resume point.
        let back = vm.handle(&s, .cellPlaybackEnded)
        #expect(back.target?.domain == .vmgMenu)
        #expect(s.resume?.pgcn == 1 && s.resume?.cell == 1)

        // Resume key from the menu returns to title 1 at cell 1.
        var resumed = s
        #expect(vm.handle(&resumed, .resume).target?.domain == .title)
        #expect(resumed.cell == 1)
    }

    @Test func gprmButtonDrivesTheSecondTitleAndTheChapterMenu() throws {
        let (nav, reader) = try load()
        let vm = DVDVirtualMachine(navigation: nav)
        var s = vm.initialState()
        let vmgmButtons = try firstNavPack("VIDEO_TS.VOB", reader).pci.highlight.buttons()
        let vtsmButtons = try firstNavPack("VTS_01_0.VOB", reader).pci.highlight.buttons()
        _ = vm.handle(&s, .start)
        _ = vm.handle(&s, .cellPlaybackEnded)

        // Button 3: g15 = 3; LinkTailPGC -> post: g14 = g15, g15 = 0, g14 == 3 -> g2 = 7; JumpTT 2.
        let extra = vm.handle(&s, .activateButton(vmgmButtons[2]))
        #expect(s.gprm[14] == 3 && s.gprm[15] == 0 && s.gprm[2] == 7)
        #expect(extra.target?.domain == .title && extra.target?.pgcn == 2)
        #expect(s.sprm[4] == 2 && s.sprm[5] == 2)

        // Title 2 ends: g2 == 7 so it calls the VTSM chapter menu (stub PGC 2 links to the root menu PGC 1).
        let chapterMenu = vm.handle(&s, .cellPlaybackEnded)
        #expect(chapterMenu.target?.domain == .vtsMenu && chapterMenu.target?.vobs == .vtsMenu(vts: 1))
        #expect(s.pgcn == 1)
        #expect(s.resume?.vtsTitle == 2)
        #expect(vm.handle(&s, .cellPlaybackEnded) == .still(seconds: nil))

        // Chapter menu button 2: JumpVTS_PTT title 1 chapter 2 -> PGC 1 program 2 = cell 2.
        let chapter2 = vm.handle(&s, .activateButton(vtsmButtons[1]))
        #expect(chapter2.target?.domain == .title && chapter2.target?.pgcn == 1 && chapter2.target?.cellNumber == 2)
        #expect(s.sprm[4] == 1 && s.sprm[5] == 1 && s.sprm[7] == 2)

        // Top Menu key from the title: CallSS to the VMGM title menu, then the menu's "Chapters" button
        // jumps into the VTSM root menu, whose "back" button returns to the VMGM menu.
        #expect(vm.handle(&s, .menuCall(.title)).target?.domain == .vmgMenu)
        #expect(vm.handle(&s, .activateButton(vmgmButtons[1])).target?.domain == .vtsMenu)
        #expect(vm.handle(&s, .activateButton(vtsmButtons[2])).target?.domain == .vmgMenu)
    }

    @Test func skipToMovieFromAnywhere() throws {
        let (nav, _) = try load()
        let vm = DVDVirtualMachine(navigation: nav)
        var s = vm.initialState()
        _ = vm.handle(&s, .start)
        let main = try #require(nav.mainTitle)
        let a = vm.handle(&s, .playTitle(main))
        #expect(a.target?.domain == .title && a.target?.pgcn == 1 && a.target?.cellNumber == 1)
    }
}
