import Foundation
@testable import AetherEngine

/// Builds synthetic navigation data for VM unit tests, so each command group can be exercised without a disc.
///
/// Default layout:
///   FP          pre commands from the test, no cells
///   VMGM        PGC 1 = title menu (entry, type 2), 1 cell, infinite still; PGC 2 = plain PGC
///   VTS 1       title 1 = PGC 1 (3 cells, programs at cells 1 and 3 -> 2 chapters)
///               title 2 = PGC 2 (1 cell)
///               VTSM PGC 1 = root menu (type 3), PGC 2 = chapter menu (type 7)
///   TT_SRPT     title 1 -> VTS 1 / 1, title 2 -> VTS 1 / 2
enum DVDTestDisc {
    static func cmds(_ hex: [String]) -> [DVDCommand] { hex.map { DVDCommand(hex: $0)! } }

    static func cell(still: UInt8 = 0, command: Int = 0, start: UInt32 = 0, cellType: Int = 0, blockType: Int = 0) -> DVDCellPlayback {
        DVDCellPlayback(cellType: cellType, blockType: blockType, stillTime: still, cellCommand: command,
                        firstVOBUStart: start, lastVOBUStart: start + 8, lastVOBUEnd: start + 15)
    }

    static func pgc(pre: [String] = [], post: [String] = [], cellCommands: [String] = [],
                    cells: [DVDCellPlayback] = [cell()], programMap: [Int]? = nil,
                    next: Int = 0, prev: Int = 0, goUp: Int = 0, still: UInt8 = 0,
                    prohibited: DVDUserOperations = []) -> DVDPGC {
        let map = programMap ?? (cells.isEmpty ? [] : [1])
        return DVDPGC(programCount: map.count, cellCount: cells.count, playbackTime: nil,
                      prohibitedOperations: prohibited, audioControl: Array(repeating: 0, count: 8),
                      subpictureControl: Array(repeating: 0, count: 32), nextPGCN: next, prevPGCN: prev,
                      goUpPGCN: goUp, stillTime: still, playbackMode: 0, palette: Array(repeating: 0, count: 16),
                      preCommands: cmds(pre), postCommands: cmds(post), cellCommands: cmds(cellCommands),
                      programMap: map, cells: cells,
                      cellPositions: cells.indices.map { DVDCellPosition(vobID: 1, cellID: $0 + 1) })
    }

    static func menuEntry(_ pgc: DVDPGC, menu: Int?) -> DVDPGCEntry {
        DVDPGCEntry(category: menu.map { 0x8000_0000 | UInt32($0) << 24 } ?? 0, pgc: pgc)
    }

    static func titleEntry(_ pgc: DVDPGC, vtsTitle: Int) -> DVDPGCEntry {
        DVDPGCEntry(category: 0x8000_0000 | UInt32(vtsTitle) << 24, pgc: pgc)
    }

    static func make(fp: DVDPGC? = pgc(cells: []),
                     vmgm: [DVDPGCEntry]? = nil,
                     titlePGCs: [DVDPGCEntry]? = nil,
                     vtsm: [DVDPGCEntry]? = nil,
                     ptts: [[DVDPTT]]? = nil,
                     titleType: UInt8 = 0) -> DVDNavigationData {
        let vmgmPGCs = vmgm ?? [
            menuEntry(pgc(cells: [cell(still: 255)]), menu: 2),
            menuEntry(pgc(cells: [cell()]), menu: nil),
        ]
        let titles = titlePGCs ?? [
            titleEntry(pgc(post: ["30 08 00 00 00 42 00 00"],                    // CallSS VMGM title menu
                           cells: [cell(start: 0), cell(start: 16), cell(start: 32)], programMap: [1, 3]), vtsTitle: 1),
            titleEntry(pgc(post: ["30 01 00 00 00 00 00 00"], cells: [cell(start: 48)]), vtsTitle: 2),
        ]
        let menus = vtsm ?? [
            menuEntry(pgc(cells: [cell(still: 255)]), menu: 3),
            menuEntry(pgc(cells: [cell(still: 255)]), menu: 7),
        ]
        let vmgi = DVDVMGI(
            titleSetCount: 1, prohibitedRegionMask: 0, firstPlayPGC: fp, menuVOBSSector: 6,
            titles: [
                DVDTitleEntry(titleType: titleType, angleCount: 1, pttCount: 2, parentalMask: 0, vtsn: 1, vtsTitle: 1, vtsStartSector: 32),
                DVDTitleEntry(titleType: titleType, angleCount: 1, pttCount: 1, parentalMask: 0, vtsn: 1, vtsTitle: 2, vtsStartSector: 32),
            ],
            menus: [DVDMenuLanguageUnit(language: "en", existenceFlags: 0x80, pgcs: vmgmPGCs)],
            menuCellAddresses: [], menuVOBUAddresses: [], menuAttributes: nil)
        let vts = DVDVTSI(
            menuVOBSSector: 9, titleVOBSSector: 28,
            ptts: ptts ?? [[DVDPTT(pgcn: 1, pgn: 1), DVDPTT(pgcn: 1, pgn: 2)], [DVDPTT(pgcn: 2, pgn: 1)]],
            titlePGCs: titles,
            menus: [DVDMenuLanguageUnit(language: "en", existenceFlags: 0x88, pgcs: menus)],
            menuCellAddresses: [], menuVOBUAddresses: [], titleCellAddresses: [], titleVOBUAddresses: [],
            menuAttributes: nil, titleAttributes: nil)
        return DVDNavigationData(vmgi: vmgi, titleSets: [1: vts])
    }

    /// Runs `pre` as the first-play PGC's pre commands from a fresh state and returns the result.
    static func runFirstPlay(_ pre: [String], gprm: [Int: UInt16] = [:]) -> (vm: DVDVirtualMachine, state: DVDVMState, action: DVDVMAction) {
        let vm = DVDVirtualMachine(navigation: make(fp: pgc(pre: pre, cells: [])))
        var state = vm.initialState()
        for (k, v) in gprm { state.gprm[k] = v }
        let action = vm.handle(&state, .start)
        return (vm, state, action)
    }
}

extension DVDVMAction {
    var target: DVDPlaybackTarget? {
        if case .playCell(let t) = self { return t }
        return nil
    }
}
