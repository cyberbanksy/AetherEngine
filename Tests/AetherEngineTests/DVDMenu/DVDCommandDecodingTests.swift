import Foundation
import Testing
@testable import AetherEngine

/// Decoding of every navigation command group, using the byte templates from the public instruction
/// tables (mpucoder.com/DVD/vmi*.html; dvd.sourceforge.net/dvdinfo/vmi.html).
struct DVDCommandDecodingTests {
    private func decode(_ hex: String) -> DVDCommand { DVDCommand(hex: hex)! }

    // MARK: Group 0: flow

    @Test func nopGotoBreakSetTmpPML() {
        #expect(decode("00 00 00 00 00 00 00 00").instruction == .nop)
        #expect(decode("00 01 00 00 00 00 00 05").instruction == .goto(line: 5))
        #expect(decode("00 02 00 00 00 00 00 00").instruction == .breakBlock)
        #expect(decode("00 03 00 00 00 00 04 09").instruction == .setTemporaryParentalLevel(level: 4, line: 9))
        #expect(decode("00 00 00 00 00 00 00 00").condition == nil)
    }

    @Test func format1RegisterAndImmediateCompares() {
        // 00 M1 00 XX 00 YY 00 NN, M = 1-7 register compare
        let reg = decode("00 21 00 03 00 84 00 02")
        #expect(reg.condition == DVDCondition(op: .equal, lhs: .gprm(3), rhs: .register(.sprm(4))))
        #expect(reg.instruction == .goto(line: 2))
        // M = 9-F: literal compare, KKKK in bytes 4-5
        let imm = decode("00 A1 00 80 00 2A 00 05")
        #expect(imm.condition == DVDCondition(op: .equal, lhs: .sprm(0), rhs: .immediate(42)))
        let ops: [(String, DVDCompareOp)] = [("91", .bitTest), ("A1", .equal), ("B1", .notEqual), ("C1", .greaterOrEqual),
                                              ("D1", .greater), ("E1", .lessOrEqual), ("F1", .less)]
        for (byte1, op) in ops {
            #expect(decode("00 \(byte1) 00 01 00 02 00 01").condition?.op == op)
        }
    }

    @Test func registerCodes() {
        #expect(DVDRegister(code: 0x00) == .gprm(0))
        #expect(DVDRegister(code: 0x0F) == .gprm(15))
        #expect(DVDRegister(code: 0x80) == .sprm(0))
        #expect(DVDRegister(code: 0x97) == .sprm(23))
        #expect(DVDRegister(code: 0x10) == .invalid(0x10))
        #expect(DVDRegister(code: 0x98) == .invalid(0x98))
    }

    @Test func invalidEncodings() {
        #expect(decode("00 04 00 00 00 00 00 00").instruction == .invalid)        // flow CMD 4-F
        #expect(decode("20 02 00 00 00 00 00 00").instruction == .invalid)        // link CMD 2
        #expect(decode("20 01 00 00 00 00 00 04").instruction == .invalid)        // link subset 04
        #expect(decode("30 04 00 00 00 00 00 00").instruction == .invalid)        // jump CMD 4
        #expect(decode("E0 00 00 00 00 00 00 00").instruction == .invalid)        // group 7
        #expect(decode("6C 00 00 01 00 02 00 00").instruction == .invalid)        // set op C
        #expect(decode("71 21 00 01 00 02 00 01").instruction == .invalid)        // compare + link conflict
    }

    // MARK: Group 1: links

    @Test func linkSubset() {
        let subset: [(UInt8, DVDLinkSubset)] = [(0x00, .noLink), (0x01, .topCell), (0x02, .nextCell), (0x03, .prevCell),
                                                (0x05, .topPG), (0x06, .nextPG), (0x07, .prevPG), (0x09, .topPGC),
                                                (0x0A, .nextPGC), (0x0B, .prevPGC), (0x0C, .goUpPGC), (0x0D, .tailPGC),
                                                (0x10, .resume)]
        for (code, sub) in subset {
            let c = DVDCommand([0x20, 0x01, 0, 0, 0, 0, 0x0C, code])          // HH = 4 * 3
            #expect(c.instruction == .link(.subset(sub, button: 3)))
        }
    }

    @Test func linkPGCNPTTNPGNCN() {
        #expect(decode("20 04 00 00 00 00 00 07").instruction == .link(.pgcn(7)))
        #expect(decode("20 04 00 00 00 00 01 2C").instruction == .link(.pgcn(300)))
        // LinkPTTN: HHHHHHTT TTTTTTTT
        #expect(decode("20 05 00 00 00 00 09 05").instruction == .link(.pttn(0x105, button: 2)))
        #expect(decode("20 06 00 00 00 00 04 03").instruction == .link(.pgn(3, button: 1)))
        #expect(decode("20 07 00 00 00 00 00 02").instruction == .link(.cell(2, button: 0)))
        let cond = decode("20 61 00 84 00 81 00 0B")
        #expect(cond.condition == DVDCondition(op: .lessOrEqual, lhs: .sprm(4), rhs: .register(.sprm(1))))
        #expect(cond.instruction == .link(.subset(.prevPGC, button: 0)))
    }

    // MARK: Group 1: jumps and calls

    @Test func jumps() {
        #expect(decode("30 01 00 00 00 00 00 00").instruction == .jump(.exit))
        #expect(decode("30 02 00 00 00 05 00 00").instruction == .jump(.title(5)))
        #expect(decode("30 03 00 00 00 02 00 00").instruction == .jump(.vtsTitle(2)))
        #expect(decode("30 05 00 0A 00 03 00 00").instruction == .jump(.vtsPTT(title: 3, ptt: 10)))
        #expect(decode("30 06 00 00 00 00 00 00").instruction == .jump(.firstPlay))
        #expect(decode("30 06 00 00 00 42 00 00").instruction == .jump(.vmgmMenu(2)))
        #expect(decode("30 06 00 02 03 83 00 00").instruction == .jump(.vtsMenu(vts: 3, title: 2, menu: 3)))
        #expect(decode("30 06 00 04 00 C0 00 00").instruction == .jump(.vmgmPGC(4)))
    }

    @Test func calls() {
        #expect(decode("30 08 00 00 02 00 00 00").instruction == .jump(.callFirstPlay(resumeCell: 2)))
        #expect(decode("30 08 00 00 00 42 00 00").instruction == .jump(.callVMGMMenu(menu: 2, resumeCell: 0)))
        #expect(decode("30 08 00 00 05 87 00 00").instruction == .jump(.callVTSMenu(menu: 7, resumeCell: 5)))
        #expect(decode("30 08 00 01 01 C0 00 00").instruction == .jump(.callVMGMPGC(pgcn: 1, resumeCell: 1)))
    }

    @Test func jumpFormat2Compare() {
        // 30 M2 00 00 00 TT XX YY: register compare in bytes 6-7
        let c = decode("30 32 00 00 00 02 01 02")
        #expect(c.condition == DVDCondition(op: .notEqual, lhs: .gprm(1), rhs: .register(.gprm(2))))
        #expect(c.instruction == .jump(.title(2)))
    }

    // MARK: Group 2: SetSystem

    @Test func setSTN() {
        // Direct: bit 7 = "set this one", low 7 bits = value. Audio 3, angle 2, subpicture untouched.
        #expect(decode("51 00 00 83 00 82 00 00").instruction ==
            .system(.streams(audio: .immediate(3), subpicture: nil, angle: .immediate(2)), then: nil))
        // Indirect: low bits name a GPRM.
        #expect(decode("41 00 00 81 85 00 00 00").instruction ==
            .system(.streams(audio: .register(.gprm(1)), subpicture: .register(.gprm(5)), angle: nil), then: nil))
    }

    @Test func setNVTMRGPRMMDAMXMDHLBTNN() {
        #expect(decode("52 00 00 3C 00 07 00 00").instruction == .system(.navigationTimer(seconds: .immediate(60), pgcn: 7), then: nil))
        #expect(decode("42 00 00 03 00 07 00 00").instruction == .system(.navigationTimer(seconds: .register(.gprm(3)), pgcn: 7), then: nil))
        #expect(decode("53 00 00 0A 00 84 00 00").instruction == .system(.gprmMode(gprm: 4, source: .immediate(10), counter: true), then: nil))
        #expect(decode("43 00 00 02 00 05 00 00").instruction == .system(.gprmMode(gprm: 5, source: .register(.gprm(2)), counter: false), then: nil))
        #expect(decode("54 00 00 00 00 0C 00 00").instruction == .system(.karaokeMix(.immediate(12)), then: nil))
        #expect(decode("56 00 00 00 08 00 00 00").instruction == .system(.highlightButton(.immediate(2048)), then: nil))
        #expect(decode("46 00 00 00 00 03 00 00").instruction == .system(.highlightButton(.register(.gprm(3))), then: nil))
    }

    @Test func setSystemWithLinkOrCompare() {
        // 56 0K ... HH LL with K = 1: SetHL_BTNN then LinkTailPGC
        #expect(decode("56 01 00 00 04 00 00 0D").instruction ==
            .system(.highlightButton(.immediate(1024)), then: .subset(.tailPGC, button: 0)))
        // 56 M0 ... XX YY: format 2 compare
        let c = decode("56 20 00 00 04 00 01 02")
        #expect(c.condition == DVDCondition(op: .equal, lhs: .gprm(1), rhs: .register(.gprm(2))))
    }

    // MARK: Group 3: Set

    @Test func setOperators() {
        let ops: [(UInt8, DVDSetOp)] = [(1, .mov), (2, .swap), (3, .add), (4, .sub), (5, .mul), (6, .div),
                                        (7, .mod), (8, .rnd), (9, .and), (0xA, .or), (0xB, .xor)]
        for (n, op) in ops {
            let c = DVDCommand([0x70 | n, 0, 0, 0x02, 0x00, 0x09, 0, 0])
            #expect(c.instruction == .set(DVDSetOperation(op: op, gprm: 2, source: .immediate(9)), then: nil))
        }
        #expect(decode("61 00 00 0E 00 0F 00 00").instruction ==
            .set(DVDSetOperation(op: .mov, gprm: 14, source: .register(.gprm(15))), then: nil))
        #expect(decode("61 00 00 01 00 84 00 00").instruction ==
            .set(DVDSetOperation(op: .mov, gprm: 1, source: .register(.sprm(4))), then: nil))
    }

    @Test func setFormat3CompareAndLink() {
        // 7J M0 XX RR SSSS KKKK: compare XX (byte 2) with literal in bytes 6-7
        let c = decode("73 C0 01 02 00 05 00 0A")
        #expect(c.condition == DVDCondition(op: .greaterOrEqual, lhs: .gprm(1), rhs: .immediate(10)))
        #expect(c.instruction == .set(DVDSetOperation(op: .add, gprm: 2, source: .immediate(5)), then: nil))
        // Register form: YY in byte 7
        let r = decode("71 50 03 02 00 05 00 04")
        #expect(r.condition == DVDCondition(op: .greater, lhs: .gprm(3), rhs: .register(.gprm(4))))
        // 71 01 ... 00 0D: dvdauthor's "g15 = 3; LinkTailPGC" button command (from the fixture)
        #expect(decode("71 01 00 0F 00 03 00 0D").instruction ==
            .set(DVDSetOperation(op: .mov, gprm: 15, source: .immediate(3)), then: .subset(.tailPGC, button: 0)))
        #expect(decode("71 04 00 01 00 03 00 05").instruction ==
            .set(DVDSetOperation(op: .mov, gprm: 1, source: .immediate(3)), then: .pgcn(5)))
    }

    // MARK: Groups 4-6

    @Test func setCLnk() {
        // 9J MR SSSS KKKK HH LL: g0 = 1; if g0 == 1 LinkNextCell
        let c = decode("91 A0 00 01 00 01 00 02")
        #expect(c.condition == DVDCondition(op: .equal, lhs: .gprm(0), rhs: .immediate(1)))
        #expect(c.instruction == .combined(.setThenConditionalLink,
                                           set: DVDSetOperation(op: .mov, gprm: 0, source: .immediate(1)),
                                           link: .subset(.nextCell, button: 0)))
        // Indirect: 8J MR 00 SS 00 YY HH LL
        let i = decode("83 23 00 01 00 02 08 06")
        #expect(i.condition == DVDCondition(op: .equal, lhs: .gprm(3), rhs: .register(.gprm(2))))
        #expect(i.instruction == .combined(.setThenConditionalLink,
                                           set: DVDSetOperation(op: .add, gprm: 3, source: .register(.gprm(1))),
                                           link: .subset(.nextPG, button: 2)))
    }

    @Test func cSetCLnkAndCSetLnk() {
        // AJ MR SS XX KKKK HH LL: if g4 >= 3 { g1 = g2; LinkTopPGC }
        let a = decode("A1 C1 02 04 00 03 00 09")
        #expect(a.condition == DVDCondition(op: .greaterOrEqual, lhs: .gprm(4), rhs: .immediate(3)))
        #expect(a.instruction == .combined(.conditionalSetAndLink,
                                           set: DVDSetOperation(op: .mov, gprm: 1, source: .register(.gprm(2))),
                                           link: .subset(.topPGC, button: 0)))
        // BJ MR SSSS XX YY HH LL (direct set, register compare only)
        let b = decode("B3 21 00 05 03 04 00 02")
        #expect(b.condition == DVDCondition(op: .equal, lhs: .gprm(3), rhs: .register(.gprm(4))))
        #expect(b.instruction == .combined(.conditionalSetAndLink,
                                           set: DVDSetOperation(op: .add, gprm: 1, source: .immediate(5)),
                                           link: .subset(.nextCell, button: 0)))
        #expect(decode("B3 A1 00 05 03 04 00 02").instruction == .invalid)   // direct set + literal compare: illegal
        let c = decode("C1 C1 02 04 00 03 00 0D")
        #expect(c.instruction == .combined(.conditionalSetAlwaysLink,
                                           set: DVDSetOperation(op: .mov, gprm: 1, source: .register(.gprm(2))),
                                           link: .subset(.tailPGC, button: 0)))
    }

    @Test func descriptionIsReadable() {
        #expect(decode("30 02 00 00 00 05 00 00").description.hasPrefix("30 02 00 00 00 05 00 00"))
        #expect(DVDCommand(hex: "30 02") == nil)
    }
}
