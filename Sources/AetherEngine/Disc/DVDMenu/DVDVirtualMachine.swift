import Foundation

// The DVD-Video navigation virtual machine (clean-room; docs/dvd-menus.md).
//
// Design: a pure function of (navigation data, state, event) -> (state, action). The VM never reads
// sectors, never sleeps, never touches a clock. The playback side (phase 2) owns all of that and feeds
// the VM events: "the cell finished", "the still elapsed", "the user activated button 2", "one second
// passed". The VM answers with one action: play this cell (from this sector offset), hold a still, keep
// going, refuse a prohibited user operation, or exit. That keeps every navigation decision unit-testable
// without a decoder, and makes the VM trivially replayable for debugging (log the events, replay them).

/// The four navigation domains.
enum DVDDomain: Equatable, Sendable {
    case firstPlay
    case vmgMenu
    case vtsMenu
    case title
}

/// Which VOB set a cell's sectors are relative to.
enum DVDVOBSet: Equatable, Sendable {
    case vmgMenu                 // VIDEO_TS.VOB
    case vtsMenu(vts: Int)       // VTS_nn_0.VOB
    case title(vts: Int)         // VTS_nn_1..9.VOB, concatenated
}

/// Player-side preferences the SPRMs are initialised from.
struct DVDPlayerSettings: Equatable, Sendable {
    var menuLanguage: String = "en"
    var audioLanguage: String? = nil
    var subpictureLanguage: String? = nil
    /// SPRM 20: bit n = region n+1 enabled. Decrypted rips are region-free; default all regions.
    var regionMask: UInt16 = 0x00FF
    var parentalCountry: String = "US"
    /// SPRM 13: 1-8, 15 = no parental restriction.
    var parentalLevel: UInt16 = 15
    /// SPRM 14 bits 11-10: preferred display aspect, 0 = 4:3, 3 = 16:9.
    var prefersWidescreen: Bool = true
    /// SPRM 15: player audio capabilities (bit 14 Dolby, 12 MPEG, 11 DTS).
    var audioCapabilities: UInt16 = 0x5800

    static func packLanguage(_ code: String?) -> UInt16 {
        guard let code, code.count == 2 else { return 0xFFFF }
        let u = Array(code.lowercased().utf8)
        return UInt16(u[0]) << 8 | UInt16(u[1])
    }
}

/// Where RSM returns to: always a point inside a title (only CallSS from the title domain saves one).
struct DVDResumePoint: Equatable, Sendable {
    let vtsn: Int
    let title: Int           // SPRM 4
    let vtsTitle: Int        // SPRM 5
    let pgcn: Int
    /// 1-based cell; cellCount + 1 means "the PGC had finished" (the call came from its post commands).
    let cell: Int
    /// Sectors into the cell (relative to its first VOBU) where playback was suspended.
    let sectorOffset: UInt32
    let ptt: Int             // SPRM 7
}

/// Where the VM is inside the current PGC.
enum DVDVMPhase: Equatable, Sendable {
    case idle
    case playingCell
    case cellStill
    case pgcStill
    case stopped
}

/// The complete VM state. Value type: copy it, diff it, log it.
struct DVDVMState: Equatable, Sendable {
    var gprm = [UInt16](repeating: 0, count: 16)
    var gprmCounter = [Bool](repeating: false, count: 16)
    var sprm = [UInt16](repeating: 0, count: 24)
    var domain: DVDDomain = .firstPlay
    /// Current title set (VTSM / title domains); 0 in the VMG domains.
    var vtsn: Int = 0
    /// 1-based PGC number within the current domain's PGC table.
    var pgcn: Int = 0
    var pgn: Int = 0
    /// 1-based cell number; 0 before the first cell starts.
    var cell: Int = 0
    var phase: DVDVMPhase = .idle
    /// Last known playback position inside the current cell (sectors from its first VOBU), fed by the
    /// player through `.position`; saved into the resume point by CallSS / menu calls.
    var sectorOffset: UInt32 = 0
    var resume: DVDResumePoint?
    /// Deterministic RNG for the `rnd` set operator.
    var random: UInt64 = 0x9E37_79B9_7F4A_7C15

    /// SPRM 8 holds button * 1024.
    var highlightedButton: Int { Int(sprm[8] >> 10) }

    init(settings: DVDPlayerSettings = DVDPlayerSettings()) {
        sprm[0] = DVDPlayerSettings.packLanguage(settings.menuLanguage)
        sprm[1] = 15                  // ASTN: none
        sprm[2] = 62                  // SPSTN: none, display off
        sprm[3] = 1                   // AGLN
        sprm[4] = 1                   // TTN
        sprm[5] = 1                   // VTS_TTN
        sprm[6] = 0                   // TT_PGCN
        sprm[7] = 1                   // PTTN
        sprm[8] = 1 << 10             // HL_BTNN: button 1
        sprm[9] = 0                   // NVTMR
        sprm[10] = 0                  // NV_PGCN
        sprm[11] = 0                  // AMXMD
        sprm[12] = DVDPlayerSettings.packLanguage(settings.parentalCountry)
        sprm[13] = settings.parentalLevel
        sprm[14] = settings.prefersWidescreen ? 3 << 10 : 0
        sprm[15] = settings.audioCapabilities
        sprm[16] = DVDPlayerSettings.packLanguage(settings.audioLanguage)
        sprm[17] = 0
        sprm[18] = DVDPlayerSettings.packLanguage(settings.subpictureLanguage)
        sprm[19] = 0
        sprm[20] = settings.regionMask
    }
}

/// Inputs to the VM.
enum DVDVMEvent: Equatable, Sendable {
    /// Disc inserted: run the first-play PGC.
    case start
    /// The player presented the last VOBU of the cell it was told to play.
    case cellPlaybackEnded
    /// A finite still (cell or PGC still time) elapsed.
    case stillEnded
    /// The user released an infinite still ("still off" / play key).
    case stillOff
    /// Playback position inside the current cell, so a later menu call / CallSS can resume there.
    case position(sectorOffset: UInt32)
    /// The highlight moved (arrow keys, pointer hover). Sets SPRM 8.
    case selectButton(Int)
    /// A button was activated (OK, touch, auto-action). Executes its command.
    case activateButton(DVDButton)
    /// Remote menu keys: `.title` = Top Menu, `.root` = Menu, and the audio / subpicture / angle / chapter menus.
    case menuCall(DVDMenuType)
    /// Remote Resume / Return.
    case resume
    case nextChapter
    case previousChapter
    case goUp
    /// Player-initiated title play (e.g. the app's "Skip to Movie").
    case playTitle(Int)
    /// Player-initiated chapter search within the current title.
    case playChapter(Int)
    /// Wall-clock seconds elapsed: advances counter-mode GPRMs and the navigation timer.
    case tick(seconds: Int)
}

/// What the playback side must do next.
enum DVDVMAction: Equatable, Sendable {
    case playCell(DVDPlaybackTarget)
    /// Hold the last frame. nil = until the user releases it (`.stillOff`) or activates a button.
    case still(seconds: Int?)
    /// Registers / highlight may have changed; playback position is unchanged.
    case continuePlayback
    /// The user operation is prohibited here (UOP mask).
    case prohibited(DVDUserOperations)
    /// Stop playback (Exit command, or nothing left to play).
    case exit
    /// Malformed navigation (missing PGC, runaway command loop). The host should fall back to plain title playback.
    case fault(String)
}

/// One cell to present.
struct DVDPlaybackTarget: Equatable, Sendable {
    let domain: DVDDomain
    let vobs: DVDVOBSet
    let pgcn: Int
    let pgn: Int
    let cellNumber: Int
    let cell: DVDCellPlayback
    let position: DVDCellPosition?
    /// Start this many sectors after `cell.firstVOBUStart` (non-zero only when resuming).
    let startSectorOffset: UInt32
}

/// The DVD navigation VM. Holds only immutable disc data and settings; all mutable state is `DVDVMState`.
struct DVDVirtualMachine: Sendable {
    let navigation: DVDNavigationData
    let settings: DVDPlayerSettings

    /// Upper bound on PGC transfers and commands per event, so a disc whose commands loop forever
    /// (LinkTopPGC in a pre command, Goto back to itself) faults instead of hanging the player.
    static let transferBudget = 256
    static let commandBudget = 100_000

    init(navigation: DVDNavigationData, settings: DVDPlayerSettings = DVDPlayerSettings()) {
        self.navigation = navigation
        self.settings = settings
    }

    func initialState() -> DVDVMState { DVDVMState(settings: settings) }

    /// The VM step: deterministic and side-effect free.
    func step(_ state: DVDVMState, _ event: DVDVMEvent,
              vobuProhibited: DVDUserOperations = []) -> (state: DVDVMState, action: DVDVMAction) {
        var x = Executor(nav: navigation, s: state)
        let action = x.handle(event, vobuProhibited: vobuProhibited)
        return (x.s, action)
    }

    /// Mutating convenience over `step`.
    func handle(_ state: inout DVDVMState, _ event: DVDVMEvent, vobuProhibited: DVDUserOperations = []) -> DVDVMAction {
        let (next, action) = step(state, event, vobuProhibited: vobuProhibited)
        state = next
        return action
    }

    /// The PGC the state currently points at (its palette, stream control and cells), if any.
    func currentPGC(_ state: DVDVMState) -> DVDPGC? {
        Executor(nav: navigation, s: state).pgc
    }

    /// The user operations prohibited right now (title + PGC masks, plus the current VOBU's mask).
    func prohibitedOperations(_ state: DVDVMState, vobu: DVDUserOperations = []) -> DVDUserOperations {
        Executor(nav: navigation, s: state).prohibited(vobu: vobu)
    }
}

// MARK: - Executor

/// A pending navigation step. Commands never recurse into PGC entry; they return one of these and the
/// trampoline in `drive` performs it, so a disc whose commands chain thousands of links cannot overflow
/// the stack, and the transfer budget is enforced in exactly one place.
private enum Next {
    case action(DVDVMAction)
    case enterPGC(Int, program: Int)
    case startCell(Int, offset: UInt32)
    case afterCell
    case endOfPGC
    case runPost
}

private struct Executor {
    let nav: DVDNavigationData
    var s: DVDVMState
    var commands = 0

    init(nav: DVDNavigationData, s: DVDVMState) {
        self.nav = nav
        self.s = s
    }

    // MARK: Tables

    var vtsi: DVDVTSI? { nav.titleSets[s.vtsn] }

    func languageUnit(_ units: [DVDMenuLanguageUnit]) -> DVDMenuLanguageUnit? {
        let lang = s.sprm[0]
        let code = lang == 0xFFFF ? nil :
            String(bytes: [UInt8(lang >> 8), UInt8(lang & 0xFF)], encoding: .ascii)
        return units.first { $0.language != nil && $0.language == code } ?? units.first
    }

    func pgcTable(_ domain: DVDDomain, vtsn: Int? = nil) -> [DVDPGC] {
        let sets = nav.titleSets[vtsn ?? s.vtsn]
        switch domain {
        case .firstPlay: return nav.vmgi.firstPlayPGC.map { [$0] } ?? []
        case .vmgMenu: return languageUnit(nav.vmgi.menus)?.pgcs.map(\.pgc) ?? []
        case .vtsMenu: return sets.flatMap { languageUnit($0.menus) }?.pgcs.map(\.pgc) ?? []
        case .title: return sets?.titlePGCs.map(\.pgc) ?? []
        }
    }

    var pgc: DVDPGC? {
        let table = pgcTable(s.domain)
        return table.indices.contains(s.pgcn - 1) ? table[s.pgcn - 1] : nil
    }

    func hasPGC(_ pgcn: Int, _ domain: DVDDomain, vtsn: Int? = nil) -> Bool {
        pgcTable(domain, vtsn: vtsn).indices.contains(pgcn - 1)
    }

    func prohibited(vobu: DVDUserOperations) -> DVDUserOperations {
        var mask = vobu.union(pgc?.prohibitedOperations ?? [])
        if s.domain == .title {
            let ttn = Int(s.sprm[4])
            if nav.vmgi.titles.indices.contains(ttn - 1) { mask.formUnion(nav.vmgi.titles[ttn - 1].prohibitedOperations) }
        }
        return mask
    }

    // MARK: Events

    mutating func handle(_ event: DVDVMEvent, vobuProhibited: DVDUserOperations) -> DVDVMAction {
        let uops = prohibited(vobu: vobuProhibited)
        func gate(_ op: DVDUserOperations, _ body: () -> DVDVMAction) -> DVDVMAction {
            uops.isDisjoint(with: op) ? body() : .prohibited(op)
        }
        switch event {
        case .start:
            s.resume = nil
            if nav.vmgi.firstPlayPGC != nil {
                s.domain = .firstPlay; s.vtsn = 0
                return drive(.enterPGC(1, program: 1))
            }
            if let n = jump(.vmgmMenu(DVDMenuType.title.rawValue)) { return drive(n) }
            if let n = jump(.title(1)) { return drive(n) }
            return .fault("disc has no first-play PGC, title menu or title 1")

        case .cellPlaybackEnded:
            guard s.phase == .playingCell, let pgc, pgc.cells.indices.contains(s.cell - 1) else { return .continuePlayback }
            let still = pgc.cells[s.cell - 1].stillTime
            if still != 0 {
                s.phase = .cellStill
                return .still(seconds: still == 255 ? nil : Int(still))
            }
            return drive(.afterCell)

        case .stillEnded:
            switch s.phase {
            case .cellStill: return drive(.afterCell)
            case .pgcStill: return drive(.runPost)
            default: return .continuePlayback
            }

        case .stillOff:
            guard s.phase == .cellStill || s.phase == .pgcStill else { return .continuePlayback }
            return gate(.stillOff) { drive(s.phase == .cellStill ? .afterCell : .runPost) }

        case .position(let offset):
            s.sectorOffset = offset
            return .continuePlayback

        case .selectButton(let n):
            return gate(.buttonSelectOrActivate) {
                setButton(n)
                return .continuePlayback
            }

        case .activateButton(let button):
            return gate(.buttonSelectOrActivate) {
                setButton(button.number)
                return run([button.command], allowGoto: false).map { drive($0) } ?? faultOr(.continuePlayback)
            }

        case .menuCall(let menu):
            let op: DVDUserOperations = switch menu {
            case .title: .titleMenuCall
            case .root: .rootMenuCall
            case .subpicture: .subpictureMenuCall
            case .audio: .audioMenuCall
            case .angle: .angleMenuCall
            case .chapter: .pttMenuCall
            }
            return gate(op) {
                let j: DVDJump
                if menu == .title {
                    j = s.domain == .title ? .callVMGMMenu(menu: menu.rawValue, resumeCell: 0) : .vmgmMenu(menu.rawValue)
                } else {
                    switch s.domain {
                    case .title: j = .callVTSMenu(menu: menu.rawValue, resumeCell: 0)
                    case .vtsMenu: j = .vtsMenu(vts: s.vtsn, title: Int(s.sprm[5]), menu: menu.rawValue)
                    default: return .continuePlayback      // no title set selected yet
                    }
                }
                return jump(j).map { drive($0) } ?? .continuePlayback
            }

        case .resume:
            return gate(.resume) { resume(button: 0).map { drive($0) } ?? .continuePlayback }

        case .nextChapter:
            return gate(.nextPGSearch) { link(.subset(.nextPG, button: 0)).map { drive($0) } ?? .continuePlayback }

        case .previousChapter:
            return gate(.topOrPrevPGSearch) { link(.subset(.prevPG, button: 0)).map { drive($0) } ?? .continuePlayback }

        case .goUp:
            return gate(.goUp) { link(.subset(.goUpPGC, button: 0)).map { drive($0) } ?? .continuePlayback }

        case .playTitle(let ttn):
            return gate(.titlePlay) { jump(.title(ttn)).map { drive($0) } ?? .fault("title \(ttn) does not exist") }

        case .playChapter(let ptt):
            return gate(.pttPlayOrSearch) {
                guard s.domain == .title else { return .continuePlayback }
                return jump(.vtsPTT(title: Int(s.sprm[5]), ptt: ptt)).map { drive($0) } ?? .continuePlayback
            }

        case .tick(let seconds):
            guard seconds > 0 else { return .continuePlayback }
            let inc = UInt16(clamping: seconds)
            for i in 0..<16 where s.gprmCounter[i] {
                s.gprm[i] = s.gprm[i] &+ inc
            }
            if s.sprm[9] > 0 {
                s.sprm[9] = s.sprm[9] > inc ? s.sprm[9] - inc : 0
                if s.sprm[9] == 0, s.sprm[10] != 0, s.domain == .title {
                    let target = Int(s.sprm[10])
                    s.sprm[10] = 0
                    if hasPGC(target, .title) { return drive(.enterPGC(target, program: 1)) }
                }
            }
            return .continuePlayback
        }
    }

    /// A fault recorded by the command budget wins over the fallback action.
    private func faultOr(_ action: DVDVMAction) -> DVDVMAction {
        commands > DVDVirtualMachine.commandBudget ? .fault("navigation loop: command budget exhausted") : action
    }

    // MARK: Trampoline

    private mutating func drive(_ first: Next) -> DVDVMAction {
        var next = first
        var transfers = 0
        while true {
            if commands > DVDVirtualMachine.commandBudget {
                return .fault("navigation loop: command budget exhausted")
            }
            switch next {
            case .action(let a):
                return a
            case .enterPGC(let pgcn, let program):
                transfers += 1
                if transfers > DVDVirtualMachine.transferBudget {
                    return .fault("navigation loop: more than \(DVDVirtualMachine.transferBudget) PGC transfers in one step")
                }
                next = enterPGC(pgcn, startProgram: program)
            case .startCell(let n, let offset):
                next = startCell(n, sectorOffset: offset)
            case .afterCell:
                next = afterCell()
            case .endOfPGC:
                next = endOfPGC()
            case .runPost:
                next = runPost()
            }
        }
    }

    // MARK: PGC flow

    /// Starts PGC `pgcn` of the current domain: pre commands, then the first cell of `startProgram`.
    private mutating func enterPGC(_ pgcn: Int, startProgram: Int) -> Next {
        let table = pgcTable(s.domain)
        guard table.indices.contains(pgcn - 1) else { return .action(.fault("PGC \(pgcn) missing in \(s.domain)")) }
        s.pgcn = pgcn
        s.cell = 0
        s.pgn = 0
        s.sectorOffset = 0
        s.phase = .idle
        if s.domain == .title { s.sprm[6] = UInt16(pgcn) }
        let pgc = table[pgcn - 1]
        if let n = run(pgc.preCommands, allowGoto: true) { return n }
        let program = max(1, startProgram)
        let entry = pgc.programMap.indices.contains(program - 1) ? pgc.programMap[program - 1] : 1
        return .startCell(entry, offset: 0)
    }

    /// Plays cell `n` (1-based) of the current PGC, or finishes the PGC when `n` is past its last cell.
    private mutating func startCell(_ requested: Int, sectorOffset: UInt32) -> Next {
        guard let pgc else { return .action(.fault("no current PGC")) }
        guard requested >= 1, requested <= pgc.cells.count else { return .endOfPGC }
        var n = requested
        // Angle block: the block's first cell stands for the whole block; pick the cell for SPRM 3.
        if pgc.cells[n - 1].isAngleBlock, pgc.cells[n - 1].cellType == 1 {
            let angle = max(1, Int(s.sprm[3]))
            n = min(n + angle - 1, blockEnd(from: n, in: pgc))
        }
        s.cell = n
        s.pgn = pgc.program(containing: n)
        s.sectorOffset = sectorOffset
        s.phase = .playingCell
        if s.domain == .title, let ptt = currentPTT() { s.sprm[7] = UInt16(ptt) }
        let vobs: DVDVOBSet = switch s.domain {
        case .firstPlay, .vmgMenu: .vmgMenu
        case .vtsMenu: .vtsMenu(vts: s.vtsn)
        case .title: .title(vts: s.vtsn)
        }
        return .action(.playCell(DVDPlaybackTarget(
            domain: s.domain, vobs: vobs, pgcn: s.pgcn, pgn: s.pgn, cellNumber: n, cell: pgc.cells[n - 1],
            position: pgc.cellPositions.indices.contains(n - 1) ? pgc.cellPositions[n - 1] : nil,
            startSectorOffset: sectorOffset)))
    }

    /// Last cell (1-based) of the angle block that contains cell `n`.
    private func blockEnd(from n: Int, in pgc: DVDPGC) -> Int {
        var i = n
        while i < pgc.cells.count, pgc.cells[i - 1].isAngleBlock, pgc.cells[i - 1].cellType != 3 { i += 1 }
        return i
    }

    /// After a cell (and its still): cell command, then the next cell.
    private mutating func afterCell() -> Next {
        guard let pgc, pgc.cells.indices.contains(s.cell - 1) else { return .endOfPGC }
        let cell = pgc.cells[s.cell - 1]
        if cell.cellCommand > 0, pgc.cellCommands.indices.contains(cell.cellCommand - 1),
           let n = run([pgc.cellCommands[cell.cellCommand - 1]], allowGoto: false) {
            return n
        }
        let next = cell.isAngleBlock ? blockEnd(from: s.cell, in: pgc) + 1 : s.cell + 1
        return .startCell(next, offset: 0)
    }

    /// All cells played: the PGC still, then the post commands.
    private mutating func endOfPGC() -> Next {
        guard let pgc else { return .action(.fault("no current PGC")) }
        s.cell = pgc.cells.count + 1
        if pgc.stillTime != 0 {
            s.phase = .pgcStill
            return .action(.still(seconds: pgc.stillTime == 255 ? nil : Int(pgc.stillTime)))
        }
        return .runPost
    }

    /// Post commands; when they fall through, follow the PGC's next link, else stop.
    private mutating func runPost() -> Next {
        guard let pgc else { return .action(.fault("no current PGC")) }
        s.phase = .idle
        if let n = run(pgc.postCommands, allowGoto: true) { return n }
        if pgc.nextPGCN != 0, hasPGC(pgc.nextPGCN, s.domain) { return .enterPGC(pgc.nextPGCN, program: 1) }
        s.phase = .stopped
        return .action(.exit)
    }

    /// The chapter (PTT, 1-based) of the current title position: the last PTT whose (pgcn, pgn) is at or
    /// before the current program of the current PGC.
    private func currentPTT() -> Int? {
        let vtsTitle = Int(s.sprm[5])
        guard let vtsi, vtsi.ptts.indices.contains(vtsTitle - 1) else { return nil }
        var best: Int?
        for (i, p) in vtsi.ptts[vtsTitle - 1].enumerated() where p.pgcn == s.pgcn && p.pgn <= s.pgn {
            best = i + 1
        }
        return best
    }

    // MARK: Command execution

    /// Runs a command block. Returns the first transfer, or nil when the block falls through.
    /// `allowGoto`: Goto / Break / SetTmpPML are only meaningful in pre / post blocks.
    private mutating func run(_ block: [DVDCommand], allowGoto: Bool) -> Next? {
        var pc = 0
        while pc < block.count {
            commands += 1
            if commands > DVDVirtualMachine.commandBudget {
                return .action(.fault("navigation loop: command budget exhausted"))
            }
            let cmd = block[pc]
            pc += 1
            if let cond = cmd.condition, case .combined = cmd.instruction {
                if let n = runCombined(cmd, cond) { return n }
                continue
            }
            if let cond = cmd.condition, !evaluate(cond) { continue }
            switch cmd.instruction {
            case .nop, .invalid:
                continue
            case .goto(let line):
                guard allowGoto else { continue }
                guard line >= 1, line <= block.count else { return nil }
                pc = line - 1
            case .breakBlock:
                if allowGoto { return nil }
            case .setTemporaryParentalLevel(let level, let line):
                guard allowGoto else { continue }
                // No parental-control UI: the level change always "succeeds".
                if (1...8).contains(level) { s.sprm[13] = UInt16(level) }
                guard line >= 1, line <= block.count else { return nil }
                pc = line - 1
            case .link(let l):
                if let n = link(l) { return n }
            case .jump(let j):
                if let n = jump(j) { return n }
            case .system(let op, let then):
                system(op)
                if let then, let n = link(then) { return n }
            case .set(let op, let then):
                if let op { apply(op) }
                if let then, let n = link(then) { return n }
            case .combined(_, let set, let l):
                // Combined with no compare (M = 0): unconditional set + link.
                if let set { apply(set) }
                if let n = link(l) { return n }
            }
        }
        return nil
    }

    private mutating func runCombined(_ cmd: DVDCommand, _ cond: DVDCondition) -> Next? {
        guard case .combined(let mode, let set, let l) = cmd.instruction else { return nil }
        switch mode {
        case .setThenConditionalLink:
            if let set { apply(set) }
            return evaluate(cond) ? link(l) : nil
        case .conditionalSetAndLink:
            guard evaluate(cond) else { return nil }
            if let set { apply(set) }
            return link(l)
        case .conditionalSetAlwaysLink:
            if evaluate(cond), let set { apply(set) }
            return link(l)
        }
    }

    func read(_ r: DVDRegister) -> UInt16 {
        switch r {
        case .gprm(let n): s.gprm[n]
        case .sprm(let n): s.sprm[n]
        case .invalid: 0
        }
    }

    func value(_ o: DVDOperand) -> UInt16 {
        switch o {
        case .register(let r): read(r)
        case .immediate(let v): v
        }
    }

    func evaluate(_ c: DVDCondition) -> Bool { c.op.evaluate(read(c.lhs), value(c.rhs)) }

    /// GPRM arithmetic. The spec leaves overflow and division by zero open; this VM saturates add / sub /
    /// mul to 0...0xFFFF and leaves the register unchanged on a zero divisor (documented in docs/dvd-menus.md).
    private mutating func apply(_ op: DVDSetOperation) {
        let d = s.gprm[op.gprm]
        let v = value(op.source)
        let result: UInt16
        switch op.op {
        case .mov: result = v
        case .swap:
            if case .register(.gprm(let j)) = op.source { s.gprm[j] = d }
            result = v
        case .add: result = UInt16(min(0xFFFF, UInt32(d) + UInt32(v)))
        case .sub: result = d >= v ? d - v : 0
        case .mul: result = UInt16(min(0xFFFF, UInt32(d) * UInt32(v)))
        case .div: result = v == 0 ? d : d / v
        case .mod: result = v == 0 ? d : d % v
        case .rnd:
            guard v > 0 else { result = d; break }
            // xorshift64*: deterministic, so a replayed event log reproduces the same "random" choices.
            s.random ^= s.random >> 12; s.random ^= s.random << 25; s.random ^= s.random >> 27
            let r = s.random &* 0x2545_F491_4F6C_DD1D
            result = UInt16(1 + (r >> 33) % UInt64(v))
        case .and: result = d & v
        case .or: result = d | v
        case .xor: result = d ^ v
        }
        s.gprm[op.gprm] = result
    }

    private mutating func system(_ op: DVDSystemSet) {
        switch op {
        case .streams(let audio, let subpicture, let angle):
            if let audio { s.sprm[1] = value(audio) }
            if let subpicture { s.sprm[2] = value(subpicture) }
            if let angle { s.sprm[3] = value(angle) }
        case .navigationTimer(let seconds, let pgcn):
            s.sprm[9] = value(seconds)
            s.sprm[10] = UInt16(pgcn)
        case .gprmMode(let n, let source, let counter):
            s.gprm[n] = value(source)
            s.gprmCounter[n] = counter
        case .karaokeMix(let v):
            s.sprm[11] = value(v)
        case .highlightButton(let v):
            s.sprm[8] = value(v)
        }
    }

    // MARK: Links

    private mutating func setButton(_ button: Int) {
        if (1...36).contains(button) { s.sprm[8] = UInt16(button) << 10 }
    }

    /// Resolves a link. nil = nothing to transfer to (LinkNoLink, or a link whose target does not exist),
    /// and the command block continues.
    private mutating func link(_ l: DVDLink) -> Next? {
        switch l {
        case .subset(let sub, let button):
            setButton(button)
            guard let pgc else { return nil }
            func pgcLink(_ n: Int) -> Next? { n != 0 && hasPGC(n, s.domain) ? .enterPGC(n, program: 1) : nil }
            switch sub {
            case .noLink: return nil
            case .topCell: return .startCell(max(1, s.cell), offset: 0)
            case .nextCell: return .startCell(s.cell + 1, offset: 0)
            case .prevCell: return .startCell(max(1, s.cell - 1), offset: 0)
            case .topPG: return program(s.pgn, in: pgc)
            case .nextPG: return s.pgn + 1 <= pgc.programMap.count ? program(s.pgn + 1, in: pgc) : .endOfPGC
            case .prevPG: return program(max(1, s.pgn - 1), in: pgc)
            case .topPGC: return .enterPGC(s.pgcn, program: 1)
            case .nextPGC: return pgcLink(pgc.nextPGCN)
            case .prevPGC: return pgcLink(pgc.prevPGCN)
            case .goUpPGC: return pgcLink(pgc.goUpPGCN)
            case .tailPGC: return .runPost
            case .resume: return resume(button: 0)
            }
        case .pgcn(let n):
            return hasPGC(n, s.domain) ? .enterPGC(n, program: 1) : nil
        case .pttn(let ptt, let button):
            setButton(button)
            guard s.domain == .title else { return nil }
            return jump(.vtsPTT(title: Int(s.sprm[5]), ptt: ptt))
        case .pgn(let n, let button):
            setButton(button)
            guard let pgc, n >= 1, n <= pgc.programMap.count else { return nil }
            return program(n, in: pgc)
        case .cell(let n, let button):
            setButton(button)
            guard let pgc, n >= 1, n <= pgc.cells.count else { return nil }
            return .startCell(n, offset: 0)
        }
    }

    private func program(_ pg: Int, in pgc: DVDPGC) -> Next {
        guard pgc.programMap.indices.contains(pg - 1) else { return .endOfPGC }
        return .startCell(pgc.programMap[pg - 1], offset: 0)
    }

    // MARK: Jumps

    /// Global title number (TT_SRPT, 1-based) for a VTS title, if the disc lists one.
    private func globalTitle(vtsn: Int, vtsTitle: Int) -> Int? {
        nav.vmgi.titles.firstIndex { $0.vtsn == vtsn && $0.vtsTitle == vtsTitle }.map { $0 + 1 }
    }

    private mutating func enterTitle(vtsn: Int, vtsTitle: Int, ptt: Int) -> Next? {
        guard let v = nav.titleSets[vtsn] else { return nil }
        let pgcn: Int
        let program: Int
        if ptt <= 1 {
            guard let entry = v.entryPGCN(forTitle: vtsTitle) else { return nil }
            pgcn = entry
            program = 1
        } else {
            guard v.ptts.indices.contains(vtsTitle - 1), v.ptts[vtsTitle - 1].indices.contains(ptt - 1) else { return nil }
            let p = v.ptts[vtsTitle - 1][ptt - 1]
            pgcn = p.pgcn
            program = p.pgn
        }
        guard hasPGC(pgcn, .title, vtsn: vtsn) else { return nil }
        s.domain = .title
        s.vtsn = vtsn
        if let ttn = globalTitle(vtsn: vtsn, vtsTitle: vtsTitle) { s.sprm[4] = UInt16(ttn) }
        s.sprm[5] = UInt16(vtsTitle)
        s.sprm[7] = UInt16(max(1, ptt))
        return .enterPGC(pgcn, program: program)
    }

    private mutating func saveResume(cell rsmCell: Int) {
        guard s.domain == .title, let pgc else { return }
        let cell: Int
        let offset: UInt32
        if rsmCell > 0 {
            cell = rsmCell; offset = 0
        } else {
            switch s.phase {
            case .playingCell, .cellStill: cell = max(1, s.cell); offset = s.sectorOffset
            case .pgcStill: cell = pgc.cells.count + 1; offset = 0
            case .idle, .stopped: cell = s.cell == 0 ? 1 : s.cell; offset = 0
            }
        }
        s.resume = DVDResumePoint(vtsn: s.vtsn, title: Int(s.sprm[4]), vtsTitle: Int(s.sprm[5]),
                                  pgcn: s.pgcn, cell: cell, sectorOffset: offset, ptt: Int(s.sprm[7]))
    }

    /// RSM: back into the title at the saved cell, without re-running the PGC's pre commands.
    private mutating func resume(button: Int) -> Next? {
        guard let r = s.resume, hasPGC(r.pgcn, .title, vtsn: r.vtsn) else { return nil }
        setButton(button)
        s.domain = .title
        s.vtsn = r.vtsn
        s.sprm[4] = UInt16(r.title)
        s.sprm[5] = UInt16(r.vtsTitle)
        s.sprm[6] = UInt16(r.pgcn)
        s.sprm[7] = UInt16(r.ptt)
        s.pgcn = r.pgcn
        guard let pgc else { return nil }
        if r.cell > pgc.cells.count { return .endOfPGC }
        return .startCell(r.cell, offset: r.sectorOffset)
    }

    /// Resolves a Jump / Call. nil = the target does not exist (the block continues).
    private mutating func jump(_ j: DVDJump) -> Next? {
        switch j {
        case .exit:
            s.phase = .stopped
            return .action(.exit)
        case .title(let ttn):
            guard nav.vmgi.titles.indices.contains(ttn - 1) else { return nil }
            let t = nav.vmgi.titles[ttn - 1]
            return enterTitle(vtsn: t.vtsn, vtsTitle: t.vtsTitle, ptt: 1)
        case .vtsTitle(let t):
            return enterTitle(vtsn: s.vtsn, vtsTitle: t, ptt: 1)
        case .vtsPTT(let t, let ptt):
            return enterTitle(vtsn: s.vtsn, vtsTitle: t, ptt: ptt)
        case .firstPlay:
            guard nav.vmgi.firstPlayPGC != nil else { return nil }
            s.domain = .firstPlay; s.vtsn = 0
            return .enterPGC(1, program: 1)
        case .vmgmMenu(let menu):
            guard let lu = languageUnit(nav.vmgi.menus), let pgcn = lu.entryPGCN(for: menu) else { return nil }
            s.domain = .vmgMenu; s.vtsn = 0
            return .enterPGC(pgcn, program: 1)
        case .vmgmPGC(let pgcn):
            guard hasPGC(pgcn, .vmgMenu) else { return nil }
            s.domain = .vmgMenu; s.vtsn = 0
            return .enterPGC(pgcn, program: 1)
        case .vtsMenu(let vts, let title, let menu):
            guard let v = nav.titleSets[vts], let lu = languageUnit(v.menus), let pgcn = lu.entryPGCN(for: menu)
            else { return nil }
            s.domain = .vtsMenu; s.vtsn = vts
            s.sprm[5] = UInt16(max(1, title))
            if let ttn = globalTitle(vtsn: vts, vtsTitle: max(1, title)) { s.sprm[4] = UInt16(ttn) }
            return .enterPGC(pgcn, program: 1)
        case .callFirstPlay(let rsm):
            saveResume(cell: rsm)
            return jump(.firstPlay)
        case .callVMGMMenu(let menu, let rsm):
            saveResume(cell: rsm)
            return jump(.vmgmMenu(menu))
        case .callVMGMPGC(let pgcn, let rsm):
            saveResume(cell: rsm)
            return jump(.vmgmPGC(pgcn))
        case .callVTSMenu(let menu, let rsm):
            saveResume(cell: rsm)
            return jump(.vtsMenu(vts: s.vtsn, title: Int(s.sprm[5]), menu: menu))
        }
    }
}

// MARK: - Disc-level helpers for the host

extension DVDNavigationData {
    /// The title (1-based TT_SRPT number) with the longest entry PGC: what "Skip to Movie" plays.
    var mainTitle: Int? {
        var best: (ttn: Int, seconds: Double)?
        for (i, t) in vmgi.titles.enumerated() {
            guard let v = titleSets[t.vtsn], let pgcn = v.entryPGCN(forTitle: t.vtsTitle),
                  v.titlePGCs.indices.contains(pgcn - 1) else { continue }
            let secs = v.titlePGCs[pgcn - 1].pgc.playbackTime?.totalSeconds ?? 0
            if best == nil || secs > best!.seconds { best = (i + 1, secs) }
        }
        return best?.ttn
    }

    /// True when the disc has something menu-like to show: a first-play PGC or any menu PGC.
    var hasMenus: Bool {
        !vmgi.menus.isEmpty || titleSets.values.contains { !$0.menus.isEmpty }
    }
}
