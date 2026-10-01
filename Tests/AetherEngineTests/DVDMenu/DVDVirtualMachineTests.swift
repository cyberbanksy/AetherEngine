import Foundation
import Testing
@testable import AetherEngine

/// Execution semantics of the DVD navigation VM, one command group at a time, on synthetic discs.
struct DVDVirtualMachineTests {
    private typealias D = DVDTestDisc

    private func button(_ n: Int, _ hex: String, up: Int = 0, down: Int = 0, auto: Bool = false) -> DVDButton {
        var raw = [UInt8](repeating: 0, count: 18)
        raw[3] = auto ? 0x80 : 0
        raw[6] = UInt8(up); raw[7] = UInt8(down)
        raw.replaceSubrange(10..<18, with: DVDCommand(hex: hex)!.raw)
        return DVDButton(number: n, raw: raw)!
    }

    /// A VM already playing title 1 (cell 1).
    private func inTitle(_ nav: DVDNavigationData = D.make()) -> (DVDVirtualMachine, DVDVMState) {
        let vm = DVDVirtualMachine(navigation: nav)
        var s = vm.initialState()
        _ = vm.handle(&s, .playTitle(1))
        return (vm, s)
    }

    // MARK: SPRM defaults

    @Test func sprmDefaults() {
        let s = DVDVMState(settings: DVDPlayerSettings(menuLanguage: "de"))
        #expect(s.sprm[0] == 0x6465)          // "de"
        #expect(s.sprm[1] == 15)
        #expect(s.sprm[2] == 62)
        #expect(s.sprm[3] == 1)
        #expect(s.sprm[4] == 1 && s.sprm[5] == 1 && s.sprm[7] == 1)
        #expect(s.sprm[8] == 1024)
        #expect(s.highlightedButton == 1)
        #expect(s.sprm[13] == 15)
        #expect(s.sprm[16] == 0xFFFF && s.sprm[18] == 0xFFFF)
        #expect(s.sprm[20] == 0xFF)
        #expect(s.gprm == Array(repeating: 0, count: 16))
    }

    // MARK: Group 0

    @Test func gotoIsOneBasedWithinTheBlock() {
        let r = D.runFirstPlay(["71 00 00 00 00 01 00 00", "00 01 00 00 00 00 00 04",
                                "71 00 00 00 00 02 00 00", "71 00 00 01 00 05 00 00"])
        #expect(r.state.gprm[0] == 1)
        #expect(r.state.gprm[1] == 5)
        #expect(r.action == .exit)               // FP without cells or a transfer: nothing to play
    }

    @Test func conditionalGotoAndBreak() {
        let r = D.runFirstPlay(["71 00 00 00 00 03 00 00",        // g0 = 3
                                "00 A1 00 00 00 03 00 04",        // if g0 == 3 goto 4
                                "71 00 00 01 00 01 00 00",        // g1 = 1 (skipped)
                                "71 00 00 02 00 01 00 00",        // g2 = 1
                                "00 02 00 00 00 00 00 00",        // break
                                "71 00 00 03 00 01 00 00"])       // g3 = 1 (not reached)
        #expect(r.state.gprm[1] == 0)
        #expect(r.state.gprm[2] == 1)
        #expect(r.state.gprm[3] == 0)
    }

    @Test func gotoOutOfRangeEndsTheBlock() {
        let r = D.runFirstPlay(["00 01 00 00 00 00 00 09", "71 00 00 00 00 01 00 00"])
        #expect(r.state.gprm[0] == 0)
    }

    @Test func setTmpPML() {
        let r = D.runFirstPlay(["00 03 00 00 00 00 04 03", "71 00 00 00 00 09 00 00", "71 00 00 01 00 01 00 00"])
        #expect(r.state.sprm[13] == 4)
        #expect(r.state.gprm[0] == 0)
        #expect(r.state.gprm[1] == 1)
    }

    // MARK: Group 3

    @Test func arithmetic() {
        let r = D.runFirstPlay([
            "71 00 00 00 00 0A 00 00",   // g0 = 10
            "73 00 00 00 00 05 00 00",   // g0 += 5      -> 15
            "74 00 00 00 00 03 00 00",   // g0 -= 3      -> 12
            "75 00 00 00 00 02 00 00",   // g0 *= 2      -> 24
            "76 00 00 00 00 05 00 00",   // g0 /= 5      -> 4
            "71 00 00 01 00 11 00 00",   // g1 = 17
            "77 00 00 01 00 05 00 00",   // g1 %= 5      -> 2
            "71 00 00 02 00 F0 00 00",   // g2 = 0xF0
            "79 00 00 02 00 3C 00 00",   // g2 &= 0x3C   -> 0x30
            "7A 00 00 02 00 01 00 00",   // g2 |= 1      -> 0x31
            "7B 00 00 02 00 FF 00 00",   // g2 ^= 0xFF   -> 0xCE
            "61 00 00 03 00 84 00 00",   // g3 = s4 (TTN, default 1)
        ])
        #expect(r.state.gprm[0] == 4)
        #expect(r.state.gprm[1] == 2)
        #expect(r.state.gprm[2] == 0xCE)
        #expect(r.state.gprm[3] == 1)
    }

    @Test func arithmeticEdgeCases() {
        let r = D.runFirstPlay([
            "71 00 00 00 FF F0 00 00",   // g0 = 0xFFF0
            "73 00 00 00 00 20 00 00",   // g0 += 0x20   saturates at 0xFFFF
            "71 00 00 01 00 02 00 00",   // g1 = 2
            "74 00 00 01 00 05 00 00",   // g1 -= 5      floors at 0
            "71 00 00 02 00 07 00 00",   // g2 = 7
            "76 00 00 02 00 00 00 00",   // g2 /= 0      unchanged
            "77 00 00 02 00 00 00 00",   // g2 %= 0      unchanged
            "75 00 00 00 00 02 00 00",   // g0 *= 2      saturates
        ])
        #expect(r.state.gprm[0] == 0xFFFF)
        #expect(r.state.gprm[1] == 0)
        #expect(r.state.gprm[2] == 7)
    }

    @Test func swapExchangesTwoGPRMs() {
        let r = D.runFirstPlay(["71 00 00 00 00 01 00 00", "71 00 00 01 00 02 00 00", "62 00 00 00 00 01 00 00"])
        #expect(r.state.gprm[0] == 2)
        #expect(r.state.gprm[1] == 1)
    }

    @Test func randomIsInRangeAndDeterministic() {
        let pre = (0..<8).map { String(format: "78 00 00 %02X 00 06 00 00", $0) }   // g0...g7 = rnd(6)
        let a = D.runFirstPlay(pre).state.gprm
        let b = D.runFirstPlay(pre).state.gprm
        #expect(a == b)
        #expect(a.prefix(8).allSatisfy { (1...6).contains($0) })
        #expect(Set(a.prefix(8)).count > 1)
    }

    @Test func conditionalSetFormat3() {
        let set = "73 C0 01 02 00 05 00 0A"                     // if g1 >= 10: g2 += 5
        #expect(D.runFirstPlay([set], gprm: [1: 10]).state.gprm[2] == 5)
        #expect(D.runFirstPlay([set], gprm: [1: 9]).state.gprm[2] == 0)
    }

    @Test func setThenLink() {
        // g1 = 3 then LinkPGCN 2 in the VMGM domain
        let nav = D.make(fp: D.pgc(pre: ["30 06 00 00 00 42 00 00"], cells: []),
                         vmgm: [D.menuEntry(D.pgc(pre: ["71 04 00 01 00 03 00 02"]), menu: 2),
                                D.menuEntry(D.pgc(), menu: nil)])
        let vm = DVDVirtualMachine(navigation: nav)
        var s = vm.initialState()
        let a = vm.handle(&s, .start)
        #expect(s.gprm[1] == 3)
        #expect(a.target?.pgcn == 2)
        #expect(a.target?.domain == .vmgMenu)
    }

    // MARK: Group 2

    @Test func setSTNDirectAndIndirect() {
        let r = D.runFirstPlay(["51 00 00 83 C1 82 00 00"])
        #expect(r.state.sprm[1] == 3 && r.state.sprm[2] == 0x41 && r.state.sprm[3] == 2)
        let i = D.runFirstPlay(["41 00 00 81 00 00 00 00"], gprm: [1: 5])
        #expect(i.state.sprm[1] == 5)
        #expect(i.state.sprm[2] == 62)                        // untouched
    }

    @Test func highlightKaraokeAndGPRMMode() {
        let r = D.runFirstPlay(["56 00 00 00 0C 00 00 00", "54 00 00 00 00 05 00 00", "53 00 00 2A 00 03 00 00"])
        #expect(r.state.sprm[8] == 3072)
        #expect(r.state.highlightedButton == 3)
        #expect(r.state.sprm[11] == 5)
        #expect(r.state.gprm[3] == 42)
        #expect(r.state.gprmCounter[3] == false)
    }

    @Test func counterModeGPRMIncrementsOnTicks() {
        var r = D.runFirstPlay(["53 00 00 0A 00 84 00 00"])   // g4 = 10, counter mode
        #expect(r.state.gprmCounter[4])
        _ = r.vm.handle(&r.state, .tick(seconds: 3))
        #expect(r.state.gprm[4] == 13)
    }

    @Test func navigationTimerLinksInTheTitleDomain() {
        // Title 1's first cell arms a 5 s timer to PGC 2.
        let titles = [D.titleEntry(D.pgc(pre: ["52 00 00 05 00 02 00 00"], cells: [D.cell(still: 255)]), vtsTitle: 1),
                      D.titleEntry(D.pgc(cells: [D.cell(start: 48)]), vtsTitle: 2)]
        let (vm, s0) = inTitle(D.make(titlePGCs: titles))
        var s = s0
        #expect(s.sprm[9] == 5 && s.sprm[10] == 2)
        #expect(vm.handle(&s, .tick(seconds: 4)) == .continuePlayback)
        #expect(s.sprm[9] == 1)
        let a = vm.handle(&s, .tick(seconds: 1))
        #expect(a.target?.pgcn == 2)
        #expect(s.sprm[10] == 0)
    }

    @Test func systemSetThenLink() {
        // SetHL_BTNN 2 then LinkTailPGC: post commands run and the following pre command is skipped.
        let nav = D.make(fp: D.pgc(pre: ["56 01 00 00 08 00 00 0D", "71 00 00 0E 00 01 00 00"],
                                   post: ["71 00 00 0F 00 63 00 00"], cells: []))
        let vm = DVDVirtualMachine(navigation: nav)
        var s = vm.initialState()
        _ = vm.handle(&s, .start)
        #expect(s.highlightedButton == 2)
        #expect(s.gprm[14] == 0)
        #expect(s.gprm[15] == 99)
    }

    // MARK: Groups 4-6

    /// FP pre = [cmd, g14 = 1], post = [g15 = 99]. A taken LinkTailPGC skips g14 = 1.
    private func combined(_ cmd: String, gprm: [Int: UInt16]) -> DVDVMState {
        let nav = D.make(fp: D.pgc(pre: [cmd, "71 00 00 0E 00 01 00 00"], post: ["71 00 00 0F 00 63 00 00"], cells: []))
        let vm = DVDVirtualMachine(navigation: nav)
        var s = vm.initialState()
        for (k, v) in gprm { s.gprm[k] = v }
        _ = vm.handle(&s, .start)
        return s
    }

    @Test func setCLnkSetsThenComparesTheResult() {
        // 93 A0 0005 0007 00 0D: g0 += 5; if g0 == 7 LinkTailPGC
        let taken = combined("93 A0 00 05 00 07 00 0D", gprm: [0: 2])
        #expect(taken.gprm[0] == 7 && taken.gprm[14] == 0)
        let notTaken = combined("93 A0 00 05 00 07 00 0D", gprm: [0: 1])
        #expect(notTaken.gprm[0] == 6 && notTaken.gprm[14] == 1)
    }

    @Test func cSetCLnkGatesSetAndLink() {
        // A1 A1 02 03 0004 00 0D: if g3 == 4 { g1 = g2; LinkTailPGC }
        let t = combined("A1 A1 02 03 00 04 00 0D", gprm: [2: 9, 3: 4])
        #expect(t.gprm[1] == 9 && t.gprm[14] == 0)
        let f = combined("A1 A1 02 03 00 04 00 0D", gprm: [2: 9, 3: 5])
        #expect(f.gprm[1] == 0 && f.gprm[14] == 1)
    }

    @Test func cSetLnkAlwaysLinks() {
        // C1 A1 02 03 0004 00 0D: if g3 == 4 g1 = g2; LinkTailPGC regardless
        let t = combined("C1 A1 02 03 00 04 00 0D", gprm: [2: 9, 3: 4])
        #expect(t.gprm[1] == 9 && t.gprm[14] == 0)
        let f = combined("C1 A1 02 03 00 04 00 0D", gprm: [2: 9, 3: 5])
        #expect(f.gprm[1] == 0 && f.gprm[14] == 0)
    }

    // MARK: Links

    @Test func cellAndProgramLinks() {
        let (vm, s0) = inTitle()
        var s = s0
        #expect(s.cell == 1 && s.pgn == 1)
        #expect(vm.handle(&s, .activateButton(button(1, "20 01 00 00 00 00 00 02"))).target?.cellNumber == 2)   // NextCell
        #expect(vm.handle(&s, .activateButton(button(1, "20 01 00 00 00 00 00 03"))).target?.cellNumber == 1)   // PrevCell
        #expect(vm.handle(&s, .activateButton(button(1, "20 07 00 00 00 00 00 03"))).target?.cellNumber == 3)   // LinkCN 3
        #expect(s.pgn == 2 && s.sprm[7] == 2)
        #expect(vm.handle(&s, .activateButton(button(1, "20 01 00 00 00 00 00 01"))).target?.cellNumber == 3)   // TopCell
        #expect(vm.handle(&s, .activateButton(button(1, "20 01 00 00 00 00 00 07"))).target?.cellNumber == 1)   // PrevPG
        #expect(vm.handle(&s, .activateButton(button(1, "20 01 00 00 00 00 00 06"))).target?.cellNumber == 3)   // NextPG
        #expect(vm.handle(&s, .activateButton(button(1, "20 01 00 00 00 00 00 05"))).target?.cellNumber == 3)   // TopPG
        #expect(vm.handle(&s, .activateButton(button(1, "20 06 00 00 00 00 00 01"))).target?.cellNumber == 1)   // LinkPGN 1
        #expect(vm.handle(&s, .activateButton(button(1, "20 05 00 00 00 00 00 02"))).target?.cellNumber == 3)   // LinkPTTN 2
        #expect(s.sprm[7] == 2)
    }

    @Test func linkWithButtonSetsHighlight() {
        let (vm, s0) = inTitle()
        var s = s0
        _ = vm.handle(&s, .activateButton(button(1, "20 01 00 00 00 00 10 00")))   // LinkNoLink, button 4
        #expect(s.highlightedButton == 4)
        #expect(s.cell == 1)
    }

    @Test func pgcLinks() {
        let nav = D.make(vmgm: [D.menuEntry(D.pgc(cells: [D.cell(still: 255)], next: 2, goUp: 2), menu: 2),
                                D.menuEntry(D.pgc(cells: [D.cell(still: 255)], prev: 1), menu: nil)])
        let vm = DVDVirtualMachine(navigation: nav)
        var s = vm.initialState()
        _ = vm.handle(&s, .menuCall(.title))
        #expect(s.domain == .vmgMenu && s.pgcn == 1)
        #expect(vm.handle(&s, .activateButton(button(1, "20 01 00 00 00 00 00 0A"))).target?.pgcn == 2)   // NextPGC
        #expect(vm.handle(&s, .activateButton(button(1, "20 01 00 00 00 00 00 0B"))).target?.pgcn == 1)   // PrevPGC
        #expect(vm.handle(&s, .goUp).target?.pgcn == 2)                                                    // GoUp
        #expect(vm.handle(&s, .activateButton(button(1, "20 04 00 00 00 00 00 01"))).target?.pgcn == 1)   // LinkPGCN 1
        // No next link from PGC 2's "next": the block falls through, playback continues.
        _ = vm.handle(&s, .activateButton(button(1, "20 04 00 00 00 00 00 02")))
        #expect(vm.handle(&s, .activateButton(button(1, "20 01 00 00 00 00 00 0A"))) == .continuePlayback)
    }

    // MARK: Jumps

    @Test func jumpTTSetsTitleRegisters() {
        let vm = DVDVirtualMachine(navigation: D.make())
        var s = vm.initialState()
        let a = vm.handle(&s, .playTitle(2))
        #expect(a.target?.domain == .title)
        #expect(a.target?.vobs == .title(vts: 1))
        #expect(a.target?.pgcn == 2)
        #expect(s.sprm[4] == 2 && s.sprm[5] == 2 && s.sprm[6] == 2 && s.sprm[7] == 1)
    }

    @Test func jumpVTSPTTStartsAtTheChaptersProgram() {
        let r = D.runFirstPlay(["30 02 00 00 00 01 00 00"])     // JumpTT 1
        var s = r.state
        let a = r.vm.handle(&s, .activateButton(button(1, "30 05 00 02 00 01 00 00")))   // JumpVTS_PTT 1, 2
        #expect(a.target?.cellNumber == 3)
        #expect(s.sprm[7] == 2)
    }

    @Test func jumpSSTargets() {
        let fp = D.runFirstPlay(["30 06 00 00 00 42 00 00"])        // VMGM title menu
        #expect(fp.state.domain == .vmgMenu && fp.action.target?.vobs == .vmgMenu)
        let vtsm = D.runFirstPlay(["30 06 00 02 01 87 00 00"])      // VTSM vts 1, title 2, chapter menu
        #expect(vtsm.state.domain == .vtsMenu && vtsm.state.vtsn == 1 && vtsm.state.pgcn == 2)
        #expect(vtsm.state.sprm[5] == 2 && vtsm.state.sprm[4] == 2)
        #expect(vtsm.action.target?.vobs == .vtsMenu(vts: 1))
        let pgc = D.runFirstPlay(["30 06 00 02 00 C0 00 00"])       // VMGM pgc 2
        #expect(pgc.state.domain == .vmgMenu && pgc.state.pgcn == 2)
        let exit = D.runFirstPlay(["30 01 00 00 00 00 00 00", "71 00 00 00 00 01 00 00"])
        #expect(exit.action == .exit && exit.state.phase == .stopped && exit.state.gprm[0] == 0)
    }

    @Test func jumpToMissingTargetFallsThrough() {
        let r = D.runFirstPlay(["30 02 00 00 00 09 00 00", "71 00 00 00 00 01 00 00"])
        #expect(r.state.gprm[0] == 1)
    }

    @Test func callSSAndResume() {
        let (vm, s0) = inTitle()
        var s = s0
        _ = vm.handle(&s, .cellPlaybackEnded)                  // -> cell 2
        _ = vm.handle(&s, .position(sectorOffset: 7))
        let menu = vm.handle(&s, .activateButton(button(1, "30 08 00 00 00 83 00 00")))   // CallSS VTSM root
        #expect(menu.target?.domain == .vtsMenu)
        #expect(s.resume == DVDResumePoint(vtsn: 1, title: 1, vtsTitle: 1, pgcn: 1, cell: 2, sectorOffset: 7, ptt: 1))
        let back = vm.handle(&s, .activateButton(button(1, "20 01 00 00 00 00 0C 10")))   // RSM, button 3
        #expect(back.target?.domain == .title)
        #expect(back.target?.cellNumber == 2)
        #expect(back.target?.startSectorOffset == 7)
        #expect(s.highlightedButton == 3)
    }

    @Test func callSSWithResumeCell() {
        let (vm, s0) = inTitle()
        var s = s0
        _ = vm.handle(&s, .activateButton(button(1, "30 08 00 00 03 42 00 00")))   // CallSS VMGM title menu, rsm cell 3
        #expect(s.domain == .vmgMenu)
        let back = vm.handle(&s, .resume)
        #expect(back.target?.cellNumber == 3)
        #expect(back.target?.startSectorOffset == 0)
    }

    @Test func resumeWithoutAResumePointDoesNothing() {
        let vm = DVDVirtualMachine(navigation: D.make())
        var s = vm.initialState()
        _ = vm.handle(&s, .start)
        #expect(vm.handle(&s, .resume) == .continuePlayback)
    }

    // MARK: Cell / PGC flow

    @Test func cellStillCellCommandAndPGCStill() {
        let titles = [D.titleEntry(D.pgc(post: ["71 00 00 0F 00 01 00 00", "30 01 00 00 00 00 00 00"],
                                         cellCommands: ["71 00 00 0E 00 07 00 00"],
                                         cells: [D.cell(still: 5, command: 1), D.cell(start: 16)], still: 255), vtsTitle: 1)]
        let (vm, s0) = inTitle(D.make(titlePGCs: titles, ptts: [[DVDPTT(pgcn: 1, pgn: 1)]]))
        var s = s0
        #expect(vm.handle(&s, .cellPlaybackEnded) == .still(seconds: 5))
        #expect(s.gprm[14] == 0)
        #expect(vm.handle(&s, .stillEnded).target?.cellNumber == 2)
        #expect(s.gprm[14] == 7)                                  // cell command ran after the still
        #expect(vm.handle(&s, .cellPlaybackEnded) == .still(seconds: nil))   // PGC still 255
        #expect(vm.handle(&s, .stillOff) == .exit)
        #expect(s.gprm[15] == 1)
    }

    @Test func postFallThroughFollowsNextPGC() {
        let titles = [D.titleEntry(D.pgc(next: 2), vtsTitle: 1), D.titleEntry(D.pgc(cells: [D.cell(start: 48)]), vtsTitle: 2)]
        let (vm, s0) = inTitle(D.make(titlePGCs: titles))
        var s = s0
        #expect(vm.handle(&s, .cellPlaybackEnded).target?.pgcn == 2)
        #expect(vm.handle(&s, .cellPlaybackEnded) == .exit)
    }

    @Test func angleBlockPlaysTheSelectedAngle() {
        let cells = [D.cell(start: 0),
                     D.cell(start: 10, cellType: 1, blockType: 1), D.cell(start: 20, cellType: 2, blockType: 1),
                     D.cell(start: 30, cellType: 3, blockType: 1),
                     D.cell(start: 40)]
        let titles = [D.titleEntry(D.pgc(pre: ["51 00 00 00 00 82 00 00"], cells: cells), vtsTitle: 1)]   // angle 2
        let (vm, s0) = inTitle(D.make(titlePGCs: titles, ptts: [[DVDPTT(pgcn: 1, pgn: 1)]]))
        var s = s0
        let angle = vm.handle(&s, .cellPlaybackEnded)
        #expect(angle.target?.cellNumber == 3)
        #expect(angle.target?.cell.firstVOBUStart == 20)
        #expect(vm.handle(&s, .cellPlaybackEnded).target?.cellNumber == 5)   // skips the rest of the block
    }

    // MARK: User operations

    @Test func pgcProhibitionRefusesUserOperations() {
        let titles = [D.titleEntry(D.pgc(cells: [D.cell(), D.cell(start: 16), D.cell(start: 32)], programMap: [1, 3],
                                         prohibited: [.nextPGSearch, .rootMenuCall]), vtsTitle: 1)]
        let (vm, s0) = inTitle(D.make(titlePGCs: titles))
        var s = s0
        #expect(vm.handle(&s, .nextChapter) == .prohibited(.nextPGSearch))
        #expect(vm.handle(&s, .menuCall(.root)) == .prohibited(.rootMenuCall))
        #expect(s.cell == 1)
        #expect(vm.handle(&s, .menuCall(.title)).target?.domain == .vmgMenu)
    }

    @Test func vobuAndTitleProhibitions() {
        let (vm, s0) = inTitle(D.make(titleType: 0x02))            // UOP1: PTT play / search
        var s = s0
        #expect(vm.handle(&s, .playChapter(2)) == .prohibited(.pttPlayOrSearch))
        #expect(vm.handle(&s, .nextChapter, vobuProhibited: [.nextPGSearch]) == .prohibited(.nextPGSearch))
        #expect(vm.handle(&s, .nextChapter).target?.cellNumber == 3)
        #expect(vm.prohibitedOperations(s).contains(.pttPlayOrSearch))
    }

    @Test func menuKeysFromTheTitleSaveAResumePoint() {
        let (vm, s0) = inTitle()
        var s = s0
        _ = vm.handle(&s, .position(sectorOffset: 3))
        let root = vm.handle(&s, .menuCall(.root))
        #expect(root.target?.domain == .vtsMenu && s.pgcn == 1)
        #expect(s.resume?.cell == 1 && s.resume?.sectorOffset == 3)
        #expect(vm.handle(&s, .menuCall(.chapter)).target?.pgcn == 2)       // from VTSM: plain jump
        #expect(vm.handle(&s, .resume).target?.startSectorOffset == 3)
    }

    @Test func rootMenuKeyBeforeAnyTitleSetIsIgnored() {
        let vm = DVDVirtualMachine(navigation: D.make())
        var s = vm.initialState()
        _ = vm.handle(&s, .menuCall(.title))
        #expect(vm.handle(&s, .menuCall(.root)) == .continuePlayback)
    }

    // MARK: Robustness

    @Test func runawayLinkLoopFaults() {
        let r = D.runFirstPlay(["20 01 00 00 00 00 00 09"])     // LinkTopPGC in a pre command
        guard case .fault = r.action else { Issue.record("expected fault, got \(r.action)"); return }
    }

    @Test func runawayGotoLoopFaults() {
        let r = D.runFirstPlay(["00 01 00 00 00 00 00 01"])     // goto 1 forever
        guard case .fault = r.action else { Issue.record("expected fault, got \(r.action)"); return }
    }

    @Test func menuLanguageUnitFollowsSPRM0() {
        let fr = DVDMenuLanguageUnit(language: "fr", existenceFlags: 0x80,
                                     pgcs: [D.menuEntry(D.pgc(cells: [D.cell(start: 99)]), menu: 2)])
        let base = D.make()
        let vmgi = DVDVMGI(titleSetCount: 1, prohibitedRegionMask: 0, firstPlayPGC: base.vmgi.firstPlayPGC,
                           menuVOBSSector: 6, titles: base.vmgi.titles, menus: base.vmgi.menus + [fr],
                           menuCellAddresses: [], menuVOBUAddresses: [], menuAttributes: nil)
        let nav = DVDNavigationData(vmgi: vmgi, titleSets: base.titleSets)
        let french = DVDVirtualMachine(navigation: nav, settings: DVDPlayerSettings(menuLanguage: "fr"))
        var s = french.initialState()
        #expect(french.handle(&s, .menuCall(.title)).target?.cell.firstVOBUStart == 99)
        let other = DVDVirtualMachine(navigation: nav, settings: DVDPlayerSettings(menuLanguage: "ja"))
        var t = other.initialState()
        #expect(other.handle(&t, .menuCall(.title)).target?.cell.firstVOBUStart == 0)   // falls back to the first unit
    }

    @Test func stepIsPure() {
        let vm = DVDVirtualMachine(navigation: D.make())
        let s = vm.initialState()
        let a = vm.step(s, .start)
        let b = vm.step(s, .start)
        #expect(a.state == b.state && a.action == b.action)
        #expect(s == vm.initialState())
    }
}
