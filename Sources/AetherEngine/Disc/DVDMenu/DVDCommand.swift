import Foundation

// DVD-Video navigation command decoding (clean-room; see docs/dvd-menus.md for the spec references).
//
// Every navigation command is 8 bytes. Byte 0 bits 7-5 select the command group:
//   0  flow (NOP / Goto / Break / SetTmpPML)          conditional, compare format 1
//   1  Link (byte 0 = 0x20) or Jump/Call (0x30)        format 1 for Link, format 2 for Jump/Call
//   2  SetSystem (SPRM writers + SetGPRMMD)            format 2 compare, or followed by a link
//   3  Set (GPRM arithmetic)                           format 3 compare, or followed by a link
//   4  SetCLnk   set, then compare, conditional link (link subset only)
//   5  CSetCLnk  compare, then set + link only when true
//   6  CSetLnk   compare, set only when true, link always
// Byte-level layouts follow mpucoder.com/DVD/vmi*.html, cross-checked against the dvd.sourceforge.net
// vmi.html table and the Inside DVD-Video wikibook "Interaction Machine" conditional formats.

/// A register reference inside a command. 0x00-0x0F address GPRM 0-15, 0x80-0x97 SPRM 0-23; every other
/// code is invalid and reads as 0.
enum DVDRegister: Equatable, Sendable, CustomStringConvertible {
    case gprm(Int)
    case sprm(Int)
    case invalid(UInt8)

    init(code: UInt8) {
        switch code {
        case 0x00...0x0F: self = .gprm(Int(code))
        case 0x80...0x97: self = .sprm(Int(code & 0x7F))
        default: self = .invalid(code)
        }
    }

    var description: String {
        switch self {
        case .gprm(let n): "g\(n)"
        case .sprm(let n): "s\(n)"
        case .invalid(let c): "?\(String(c, radix: 16))"
        }
    }
}

/// A source value: a register, or a 16-bit literal carried in the command.
enum DVDOperand: Equatable, Sendable {
    case register(DVDRegister)
    case immediate(UInt16)
}

/// Compare operators (3-bit field, byte 1 bits 6-4). 0 = unconditional.
enum DVDCompareOp: UInt8, Sendable {
    case bitTest = 1        // BC: true when (lhs & rhs) != 0
    case equal = 2
    case notEqual = 3
    case greaterOrEqual = 4
    case greater = 5
    case lessOrEqual = 6
    case less = 7

    func evaluate(_ lhs: UInt16, _ rhs: UInt16) -> Bool {
        switch self {
        case .bitTest: (lhs & rhs) != 0
        case .equal: lhs == rhs
        case .notEqual: lhs != rhs
        case .greaterOrEqual: lhs >= rhs
        case .greater: lhs > rhs
        case .lessOrEqual: lhs <= rhs
        case .less: lhs < rhs
        }
    }
}

struct DVDCondition: Equatable, Sendable {
    let op: DVDCompareOp
    let lhs: DVDRegister
    let rhs: DVDOperand
}

/// Set operators (4-bit field). 0 = no set.
enum DVDSetOp: UInt8, Sendable {
    case mov = 1, swap, add, sub, mul, div, mod, rnd, and, or, xor
}

/// The "link subset" (Link command 0x20 0x?1, and the link half of groups 2-6), byte 7 bits 4-0.
enum DVDLinkSubset: UInt8, Sendable {
    case noLink = 0x00
    case topCell = 0x01, nextCell = 0x02, prevCell = 0x03
    case topPG = 0x05, nextPG = 0x06, prevPG = 0x07
    case topPGC = 0x09, nextPGC = 0x0A, prevPGC = 0x0B, goUpPGC = 0x0C, tailPGC = 0x0D
    case resume = 0x10
}

/// A link: a transfer within the current domain. `button` is the highlight to select (1-36), 0 = unchanged.
enum DVDLink: Equatable, Sendable {
    case subset(DVDLinkSubset, button: Int)
    case pgcn(Int)
    case pttn(Int, button: Int)
    case pgn(Int, button: Int)
    case cell(Int, button: Int)
}

/// Jump / Call: transfers across domains. Call saves a resume point (title domain only).
/// `resumeCell` 0 = resume where playback was suspended.
enum DVDJump: Equatable, Sendable {
    case exit
    case title(Int)                          // JumpTT: global title number (TT_SRPT)
    case vtsTitle(Int)                       // JumpVTS_TT: title number within the current VTS
    case vtsPTT(title: Int, ptt: Int)        // JumpVTS_PTT
    case firstPlay                           // JumpSS FP
    case vmgmMenu(Int)                       // JumpSS VMGM menu type (2 = title menu)
    case vtsMenu(vts: Int, title: Int, menu: Int)   // JumpSS VTSM
    case vmgmPGC(Int)                        // JumpSS VMGM pgcn
    case callFirstPlay(resumeCell: Int)
    case callVMGMMenu(menu: Int, resumeCell: Int)
    case callVTSMenu(menu: Int, resumeCell: Int)
    case callVMGMPGC(pgcn: Int, resumeCell: Int)
}

/// SetSystem group (group 2).
enum DVDSystemSet: Equatable, Sendable {
    /// SPRM 1 / 2 / 3; nil leaves that register unchanged.
    case streams(audio: DVDOperand?, subpicture: DVDOperand?, angle: DVDOperand?)
    /// SPRM 9 (seconds) and SPRM 10 (PGC to link to when it expires).
    case navigationTimer(seconds: DVDOperand, pgcn: Int)
    /// GPRM write that also sets register / counter mode.
    case gprmMode(gprm: Int, source: DVDOperand, counter: Bool)
    case karaokeMix(DVDOperand)                  // SPRM 11
    case highlightButton(DVDOperand)             // SPRM 8 (button number * 1024)
}

struct DVDSetOperation: Equatable, Sendable {
    let op: DVDSetOp
    let gprm: Int
    let source: DVDOperand
}

/// How a group 4-6 command combines its compare with its set and link.
enum DVDCombinedMode: Equatable, Sendable {
    case setThenConditionalLink        // group 4: set, compare (after the set), link if true
    case conditionalSetAndLink         // group 5: compare; if true set + link
    case conditionalSetAlwaysLink      // group 6: compare; if true set; always link
}

enum DVDInstruction: Equatable, Sendable {
    case nop
    case goto(line: Int)
    case breakBlock
    case setTemporaryParentalLevel(level: Int, line: Int)
    case link(DVDLink)
    case jump(DVDJump)
    case system(DVDSystemSet, then: DVDLink?)
    case set(DVDSetOperation?, then: DVDLink?)
    case combined(DVDCombinedMode, set: DVDSetOperation?, link: DVDLink)
    /// Reserved / illegal encodings. Executing one is a no-op (a robust player skips what it cannot decode).
    case invalid
}

/// One decoded 8-byte navigation command.
struct DVDCommand: Equatable, Sendable, CustomStringConvertible {
    let raw: [UInt8]
    let condition: DVDCondition?
    let instruction: DVDInstruction

    init(_ raw: [UInt8]) {
        precondition(raw.count == 8, "DVD navigation commands are 8 bytes")
        self.raw = raw
        (condition, instruction) = DVDCommand.decode(raw)
    }

    /// Convenience for tests and fixtures: `DVDCommand(hex: "20 01 00 00 00 00 00 02")`.
    init?(hex: String) {
        let parts = hex.split(whereSeparator: { $0 == " " }).compactMap { UInt8($0, radix: 16) }
        guard parts.count == 8 else { return nil }
        self.init(parts)
    }

    var description: String {
        let hex = raw.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "\(hex)  \(instruction)\(condition.map { " if \($0)" } ?? "")"
    }

    // MARK: - Decoding

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }

    /// Compare fields shared by every group: byte 1 bit 7 = "compare against a literal", bits 6-4 = op.
    private static func compareOp(_ b: [UInt8]) -> DVDCompareOp? { DVDCompareOp(rawValue: (b[1] >> 4) & 0x07) }
    private static func compareImmediate(_ b: [UInt8]) -> Bool { b[1] & 0x80 != 0 }

    /// Format 1 (groups 0 and Link): lhs register in byte 3, rhs register in byte 5 or literal in bytes 4-5.
    private static func format1(_ b: [UInt8]) -> DVDCondition? {
        guard let op = compareOp(b) else { return nil }
        let rhs: DVDOperand = compareImmediate(b) ? .immediate(u16(b, 4)) : .register(DVDRegister(code: b[5]))
        return DVDCondition(op: op, lhs: DVDRegister(code: b[3]), rhs: rhs)
    }

    /// Format 2 (Jump/Call, SetSystem): register to register only, bytes 6 and 7.
    private static func format2(_ b: [UInt8]) -> DVDCondition? {
        guard let op = compareOp(b) else { return nil }
        return DVDCondition(op: op, lhs: DVDRegister(code: b[6]), rhs: .register(DVDRegister(code: b[7])))
    }

    /// Format 3 (Set): lhs register in byte 2, rhs register in byte 7 or literal in bytes 6-7.
    private static func format3(_ b: [UInt8]) -> DVDCondition? {
        guard let op = compareOp(b) else { return nil }
        let rhs: DVDOperand = compareImmediate(b) ? .immediate(u16(b, 6)) : .register(DVDRegister(code: b[7]))
        return DVDCondition(op: op, lhs: DVDRegister(code: b[2]), rhs: rhs)
    }

    /// Button number carried in byte 6 bits 7-2 ("HH" = 4 * button); 0 leaves SPRM 8 unchanged.
    private static func button(_ b: [UInt8]) -> Int { Int(b[6] >> 2) }

    /// The link carried in bytes 6-7, selected by a 4-bit link kind (Link group CMD, or "K" in groups 2-3).
    private static func link(kind: UInt8, _ b: [UInt8]) -> DVDLink? {
        switch kind {
        case 1:
            guard let sub = DVDLinkSubset(rawValue: b[7] & 0x1F) else { return nil }
            return .subset(sub, button: button(b))
        case 4: return .pgcn(Int(u16(b, 6) & 0x7FFF))
        case 5: return .pttn(Int(u16(b, 6) & 0x03FF), button: button(b))
        case 6: return .pgn(Int(b[7] & 0x7F), button: button(b))
        case 7: return .cell(Int(b[7]), button: button(b))
        default: return nil
        }
    }

    /// The group 4-6 link: always the link subset in byte 7, highlight in byte 6.
    private static func subsetLink(_ b: [UInt8]) -> DVDLink? {
        guard let sub = DVDLinkSubset(rawValue: b[7] & 0x1F) else { return nil }
        return .subset(sub, button: button(b))
    }

    static func decode(_ b: [UInt8]) -> (DVDCondition?, DVDInstruction) {
        let group = b[0] >> 5
        switch group {
        case 0: return decodeFlow(b)
        case 1: return b[0] & 0x10 == 0 ? decodeLink(b) : decodeJump(b)
        case 2: return decodeSystem(b)
        case 3: return decodeSet(b)
        case 4, 5, 6: return decodeCombined(b, group: group)
        default: return (nil, .invalid)
        }
    }

    private static func decodeFlow(_ b: [UInt8]) -> (DVDCondition?, DVDInstruction) {
        let cond = format1(b)
        switch b[1] & 0x0F {
        case 0: return (cond, .nop)
        case 1: return (cond, .goto(line: Int(b[7])))
        case 2: return (cond, .breakBlock)
        case 3: return (cond, .setTemporaryParentalLevel(level: Int(b[6] & 0x0F), line: Int(b[7])))
        default: return (nil, .invalid)
        }
    }

    private static func decodeLink(_ b: [UInt8]) -> (DVDCondition?, DVDInstruction) {
        let cond = format1(b)
        let kind = b[1] & 0x0F
        if kind == 0 { return (cond, .nop) }
        guard let l = link(kind: kind, b) else { return (nil, .invalid) }
        return (cond, .link(l))
    }

    private static func decodeJump(_ b: [UInt8]) -> (DVDCondition?, DVDInstruction) {
        let cond = format2(b)
        let target = b[5] >> 6
        let menu = Int(b[5] & 0x0F)
        let pgcn = Int(u16(b, 2) & 0x7FFF)
        let rsm = Int(b[4])
        let jump: DVDJump
        switch b[1] & 0x0F {
        case 0: return (cond, .nop)
        case 1: jump = .exit
        case 2: jump = .title(Int(b[5]))
        case 3: jump = .vtsTitle(Int(b[5]))
        case 5: jump = .vtsPTT(title: Int(b[5]), ptt: Int(u16(b, 2) & 0x03FF))
        case 6:
            switch target {
            case 0: jump = .firstPlay
            case 1: jump = .vmgmMenu(menu)
            case 2: jump = .vtsMenu(vts: Int(b[4]), title: Int(b[3]), menu: menu)
            default: jump = .vmgmPGC(pgcn)
            }
        case 8:
            switch target {
            case 0: jump = .callFirstPlay(resumeCell: rsm)
            case 1: jump = .callVMGMMenu(menu: menu, resumeCell: rsm)
            case 2: jump = .callVTSMenu(menu: menu, resumeCell: rsm)
            default: jump = .callVMGMPGC(pgcn: pgcn, resumeCell: rsm)
            }
        default: return (nil, .invalid)
        }
        return (cond, .jump(jump))
    }

    /// Groups 2-3 carry either a compare (byte 1 bits 6-4) or a trailing link (byte 1 bits 3-0), never both.
    private static func compareOrLink(_ b: [UInt8], format: ([UInt8]) -> DVDCondition?)
        -> (ok: Bool, DVDCondition?, DVDLink?) {
        let kind = b[1] & 0x0F
        let cond = format(b)
        if cond != nil && kind != 0 { return (false, nil, nil) }      // "CMP & LNK conflict": illegal
        if kind == 0 { return (true, cond, nil) }
        guard let l = link(kind: kind, b) else { return (false, nil, nil) }
        return (true, nil, l)
    }

    private static func decodeSystem(_ b: [UInt8]) -> (DVDCondition?, DVDInstruction) {
        let direct = b[0] & 0x10 != 0
        let (ok, cond, then) = compareOrLink(b, format: format2)
        guard ok else { return (nil, .invalid) }
        func gprm(_ byte: UInt8) -> DVDOperand { .register(.gprm(Int(byte & 0x0F))) }
        let op: DVDSystemSet
        switch b[0] & 0x0F {
        case 1:
            func stream(_ byte: UInt8) -> DVDOperand? {
                guard byte & 0x80 != 0 else { return nil }
                return direct ? .immediate(UInt16(byte & 0x7F)) : gprm(byte)
            }
            op = .streams(audio: stream(b[3]), subpicture: stream(b[4]), angle: stream(b[5]))
        case 2:
            op = .navigationTimer(seconds: direct ? .immediate(u16(b, 2)) : gprm(b[3]), pgcn: Int(u16(b, 4) & 0x7FFF))
        case 3:
            op = .gprmMode(gprm: Int(b[5] & 0x0F), source: direct ? .immediate(u16(b, 2)) : gprm(b[3]),
                           counter: b[5] & 0x80 != 0)
        case 4:
            op = .karaokeMix(direct ? .immediate(u16(b, 4)) : gprm(b[5]))
        case 6:
            op = .highlightButton(direct ? .immediate(u16(b, 4)) : gprm(b[5]))
        default:
            return (nil, .invalid)
        }
        return (cond, .system(op, then: then))
    }

    private static func decodeSet(_ b: [UInt8]) -> (DVDCondition?, DVDInstruction) {
        let direct = b[0] & 0x10 != 0
        let (ok, cond, then) = compareOrLink(b, format: format3)
        guard ok else { return (nil, .invalid) }
        let rawOp = b[0] & 0x0F
        if rawOp == 0 { return (cond, .set(nil, then: then)) }
        guard let op = DVDSetOp(rawValue: rawOp) else { return (nil, .invalid) }
        let source: DVDOperand = direct ? .immediate(u16(b, 4)) : .register(DVDRegister(code: b[5]))
        return (cond, .set(DVDSetOperation(op: op, gprm: Int(b[3] & 0x0F), source: source), then: then))
    }

    private static func decodeCombined(_ b: [UInt8], group: UInt8) -> (DVDCondition?, DVDInstruction) {
        let direct = b[0] & 0x10 != 0
        let dest = Int(b[1] & 0x0F)
        guard let link = subsetLink(b) else { return (nil, .invalid) }
        let immCompare = compareImmediate(b)
        let op = compareOp(b)
        let source: DVDOperand
        let lhs: DVDRegister
        let rhs: DVDOperand
        let mode: DVDCombinedMode
        if group == 4 {
            // 8J/9J MR: set GPRM R; compare GPRM R with byte 5 / literal 4-5.
            mode = .setThenConditionalLink
            source = direct ? .immediate(u16(b, 2)) : .register(DVDRegister(code: b[3]))
            lhs = .gprm(dest)
            rhs = immCompare ? .immediate(u16(b, 4)) : .register(DVDRegister(code: b[5]))
        } else {
            // AJ/BJ, CJ/DJ MR: indirect = source byte 2, compare byte 3 vs byte 5 / literal 4-5;
            // direct = literal source 2-3, compare byte 4 vs byte 5 (register to register only).
            mode = group == 5 ? .conditionalSetAndLink : .conditionalSetAlwaysLink
            if direct {
                guard !immCompare else { return (nil, .invalid) }
                source = .immediate(u16(b, 2))
                lhs = DVDRegister(code: b[4])
                rhs = .register(DVDRegister(code: b[5]))
            } else {
                source = .register(DVDRegister(code: b[2]))
                lhs = DVDRegister(code: b[3])
                rhs = immCompare ? .immediate(u16(b, 4)) : .register(DVDRegister(code: b[5]))
            }
        }
        let rawOp = b[0] & 0x0F
        let set: DVDSetOperation?
        if rawOp == 0 {
            set = nil
        } else if let setOp = DVDSetOp(rawValue: rawOp) {
            set = DVDSetOperation(op: setOp, gprm: dest, source: source)
        } else {
            return (nil, .invalid)
        }
        let cond = op.map { DVDCondition(op: $0, lhs: lhs, rhs: rhs) }
        return (cond, .combined(mode, set: set, link: link))
    }
}
