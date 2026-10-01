# DVD-Video menus

Status: **phase 1 landed** (IFO navigation parsing, NAV packs, the navigation VM, fixtures, tests). Nothing is wired into playback yet: `DiscReader` still plays a DVD ISO as plain whole-VTS titles, exactly as described in [formats.md](formats.md#disc-dvd--blu-ray-iso).

This branch (`dvd-menus`) lives in the fork at `github.com/cyberbanksy/AetherEngine`, branched from upstream tag `6.66.0`. It is kept as a set of commits on top of an upstream release tag so it can be rebased forward (see [Staying in sync](#staying-in-sync-with-upstream)).

## Product decisions (host side, OpenStream, 2026-10-01)

- A DVD ISO plays **menu first**: the disc's own menus are part of the experience.
- Its title page offers **Play Disc** (run the disc from first-play, which normally lands on the disc's menu) and **Skip to Movie** (play the main title directly, `DVDNavigationData.mainTitle`).
- Library marker: the `opticaldisc` SF Symbol in the poster corner. Opening animation: that symbol spinning.

## Licensing and clean-room statement

AetherEngine is LGPL-3.0 with an App Store / DRM exception (see `LICENSE`); everything here is published under the same terms, and this fork is public.

The DVD menu code in `Sources/AetherEngine/Disc/DVDMenu/` was written **clean-room from public format descriptions only**. No source code of libdvdnav, libdvdread, DVD.js or any other GPL DVD implementation was read, copied or ported. The references used:

- dvd.sourceforge.net "DVD-Video Information": [ifo](https://dvd.sourceforge.net/dvdinfo/ifo.html), [ifo_vmg](https://dvd.sourceforge.net/dvdinfo/ifo_vmg.html), [ifo_vts](https://dvd.sourceforge.net/dvdinfo/ifo_vts.html), [pgc](https://dvd.sourceforge.net/dvdinfo/pgc.html), [pci_pkt](https://dvd.sourceforge.net/dvdinfo/pci_pkt.html), [dsi_pkt](https://dvd.sourceforge.net/dvdinfo/dsi_pkt.html), [spu](https://dvd.sourceforge.net/dvdinfo/spu.html), [vmi](https://dvd.sourceforge.net/dvdinfo/vmi.html), [vmi-sum](https://dvd.sourceforge.net/dvdinfo/vmi-sum.html), [vmi-jmp](https://dvd.sourceforge.net/dvdinfo/vmi-jmp.html), [sprm](https://dvd.sourceforge.net/dvdinfo/sprm.html), [uops](https://dvd.sourceforge.net/dvdinfo/uops.html).
- mpucoder: the per-instruction pages indexed at [mpucoder.com/DVD/vmindx.html](http://www.mpucoder.com/DVD/vmindx.html) (exact byte templates for every command, including the conditional and link forms), [pci_pkt](http://www.mpucoder.com/DVD/pci_pkt.html), [dsi_pkt](http://www.mpucoder.com/DVD/dsi_pkt.html).
- The "Inside DVD-Video" wikibook: [Interaction Machine](https://en.wikibooks.org/wiki/Inside_DVD-Video/Interaction_Machine) (conditional formats 1-3, set-operation source rules, Link / Jump / Call model), [Instruction Set Details](https://en.wikibooks.org/wiki/Inside_DVD-Video/Instruction_Set_Details), [NAV PACKs](https://en.wikibooks.org/wiki/Inside_DVD-Video/NAV_PACKs), [IFO Files](https://en.wikibooks.org/wiki/Inside_DVD-Video/IFO_Files).

Where the sources disagree, mpucoder's explicit byte templates won (for example SetSTN's audio / subpicture / angle bytes are 3 / 4 / 5). Where the sources are silent, the choice is listed under [Implementation choices](#implementation-choices-where-the-references-are-silent). The pre-existing upstream `DVDIFOParser` (title / chapter enumeration) is unchanged and independent of this code.

Test fixtures are authored with dvdauthor, spumux and xorriso (GPL tools) as **external programs that generate data files**; none of their code is linked into or derived for the engine.

## Phase 1: parsing and the VM (done)

All of it is pure Swift, `internal`, and has no FFmpeg or AVFoundation dependency.

| File | What it does |
|---|---|
| `DVDByteReader.swift` | Bounds-checked big-endian reads (`DVDBytes`) and BCD `DVDTime`. Every IFO / NAV byte is untrusted: truncated or hostile tables degrade to "absent", never trap. |
| `DVDNavigationIFO.swift` | `DVDVMGI` (first-play PGC, TT_SRPT, VMGM_PGCI_UT, VMGM C_ADT / VOBU_ADMAP, menu VOBS sector, menu stream attributes, region mask), `DVDVTSI` (VTS_PTT_SRPT, VTS_PGCIT, VTSM_PGCI_UT, menu + title C_ADT / VOBU_ADMAP, menu + title video / audio / subpicture attributes), `DVDPGC` (pre / post / cell commands, program map, cell playback incl. still time + cell command + sectors + angle-block flags, cell positions, palette, audio / subpicture stream control, next / prev / go-up, PGC still, UOP mask), `DVDUserOperations` (UOP0-24). `DVDNavigationData.load(iso:)` reads everything from an ISO through `ISO9660Reader`, falling back to the `.BUP` copies. |
| `DVDCommand.swift` | Decodes the 8-byte navigation commands of all groups: flow (NOP / Goto / Break / SetTmpPML), Link (subset, PGCN, PTTN, PGN, CN), Jump / Call (Exit, JumpTT, JumpVTS_TT, JumpVTS_PTT, JumpSS FP / VMGM menu / VTSM / VMGM PGC, CallSS with resume cell), SetSystem (SetSTN, SetNVTMR, SetGPRMMD incl. counter mode, SetAMXMD, SetHL_BTNN), Set (mov, swp, add, sub, mul, div, mod, rnd, and, or, xor) and the combined groups 4-6 (SetCLnk, CSetCLnk, CSetLnk), with compare formats 1-3 and the set-or-link exclusivity of groups 2-3. Illegal encodings decode to `.invalid` and execute as no-ops. |
| `DVDNavPack.swift` | NAV pack parsing: PCI (LBN, VOBU UOP mask, VOBU PTMs, cell elapsed time, non-seamless angle offsets, highlight info: status, highlight / button-select-end PTMs, button groups and their display types, start button, button count, forced select / action, the three selection / action colour + contrast schemes, all 36 BTN_IT entries with geometry, auto-action, up / down / left / right neighbours and the button command) and DSI (SCR, LBN, VOBU end, reference-frame ends, VOB / cell ids, cell elapsed time, ILVU flags and pointers, seamless angle offsets / sizes, the full VOBU search table incl. next / previous VOBU, audio and subpicture sync). `DVDHighlightNavigator` moves the highlight by direction and hit-tests a point (touch / pointer). |
| `DVDVirtualMachine.swift` | The VM. |

### The VM contract

```swift
let vm = DVDVirtualMachine(navigation: nav, settings: DVDPlayerSettings(menuLanguage: "en"))
var state = vm.initialState()                     // GPRM x16 (+ counter mode), SPRM x24 with defaults
let action = vm.handle(&state, .start)            // or: let (next, action) = vm.step(state, .start)
```

`step(state, event, vobuProhibited:) -> (state, action)` is deterministic and side-effect free: no I/O, no clock, no randomness outside the state (the `rnd` operator uses an xorshift seed stored in `DVDVMState`). A session is therefore a replayable event log.

Events (`DVDVMEvent`): `start`, `cellPlaybackEnded`, `stillEnded`, `stillOff`, `position(sectorOffset:)`, `selectButton(n)`, `activateButton(DVDButton)`, `menuCall(.title / .root / .subpicture / .audio / .angle / .chapter)`, `resume`, `nextChapter`, `previousChapter`, `goUp`, `playTitle(n)`, `playChapter(n)`, `tick(seconds:)`.

Actions (`DVDVMAction`): `playCell(DVDPlaybackTarget)` (domain, which VOB set, PGC, program, cell, the cell's sector range relative to that VOB set, and a start offset for resume), `still(seconds:)` (nil = infinite, released by `stillOff` or a button), `continuePlayback`, `prohibited(op)`, `exit`, `fault(reason)` (malformed navigation: the host falls back to Skip to Movie).

What the VM implements:

- Domains FP, VMGM, VTSM, TT, with the menu language unit chosen from SPRM 0 (first unit as fallback).
- PGC execution: pre commands, then cells (cell still, then the cell command), then the PGC still, then post commands; post fall-through follows the PGC's next link, else exit. Angle blocks play the cell for SPRM 3 and skip the rest of the block.
- SPRM bookkeeping: TTN / VTS_TTN / TT_PGCN / PTTN follow title, PGC and program changes; HL_BTNN follows link highlight fields, SetHL_BTNN and button selection.
- Jump / Call with a one-deep resume point (`DVDResumePoint`: title, PGC, cell, sector offset, PTT; CallSS's explicit resume cell honoured), RSM from a command or the Resume key, menu keys from titles (CallSS) and menus (JumpSS).
- Navigation timer (SPRM 9 / 10) and counter-mode GPRMs driven by `tick`.
- UOPs: title (TT_SRPT) | PGC | VOBU (`vobuProhibited:` from the current PCI) are OR-ed, and user events are refused with `.prohibited`.
- Robustness: at most 256 PGC transfers and 100 000 commands per event, then `.fault`. PGC transfers run through a trampoline, so link chains never recurse.

### Implementation choices where the references are silent

- GPRM arithmetic saturates (`add` / `mul` clamp at 0xFFFF, `sub` floors at 0); `div` / `mod` by zero leave the register unchanged; `rnd` with source 0 leaves it unchanged; `swp` with a non-GPRM source acts as `mov`.
- Goto line numbers are 1-based within the block (confirmed by dvdauthor's output in the fixture).
- SetTmpPML always succeeds (no parental-control UI) and stores the level in SPRM 13.
- A link whose target does not exist (missing PGC, next / prev / go-up of 0) is skipped and the block continues; a Jump to a missing title likewise.
- A CallSS issued from post commands saves "after the last cell" as its resume point, so RSM re-enters the post commands.
- Button groups: the 36 BTN_IT slots are split evenly between the declared groups (36, 18 + 18, 12 + 12 + 12); `group(forDisplayMode:)` picks the group whose type bit matches. To verify against a widescreen multi-group disc in phase 2.
- Region (VMG category) and parental (PTL_MAIT) data is parsed but not enforced: decrypted rips are played region-free.

## Fixtures and tests

`Tests/Fixtures/dvd/make-menu-fixture.sh` regenerates `menu-test.iso` (about 600 KB) with ffmpeg, spumux, dvdauthor and xorriso (`brew install ffmpeg dvdauthor xorriso`); `menu-test.xml` beside it is the dvdauthor project. The disc: an FP PGC that sets GPRM 1 and jumps to the VMGM title menu; a VMGM title menu with three buttons on an infinite still (Play = title 1, Chapters = VTSM root, Extra = `g2 = 7; jump title 2`, which dvdauthor compiles to "g15 = 3; LinkTailPGC" plus a post-command dispatcher); a VTSM chapter menu with three buttons; title 1 with two chapters ending in CallSS VMGM; title 2 whose post commands branch on GPRM 2 into the VTSM chapter menu.

Test suites (Swift Testing, `Tests/AetherEngineTests/DVDMenu/`): `DVDCommandDecodingTests` (every group from the published byte templates), `DVDVirtualMachineTests` (execution semantics per group on synthetic discs, cell / PGC flow, angle blocks, UOPs, resume, timers, loop faults, purity), `DVDNavPackTests` (hand-built PCI / DSI sectors), `DVDMenuFixtureTests` (the authored disc: IFO structure, NAV-pack buttons, and the VM driven first-play -> menu -> button -> title -> title end -> menu, the GPRM-setting button, the chapter menu, menu keys, resume, Skip to Movie).

## Phase 2: playback wiring (next)

Goal: `DiscReader` hands a DVD with menus to a **navigation source** instead of a whole-VTS concatenation, and the engine presents menus with highlights and accepts input.

1. **`DVDNavigationSource` (IOReader).** Owns a `DVDVirtualMachine` + state. For each `playCell` it maps the cell's VOB-set-relative sectors onto files (`VIDEO_TS.VOB`, `VTS_nn_0.VOB`, `VTS_nn_1..9.VOB` concatenated) and streams those sectors as MPEG-PS to the demuxer, reading each VOBU's NAV pack on the way (PCI to the highlight layer, DSI `nextVOBU` / `vobuEndAddress` to walk the cell). At cell end it sends `cellPlaybackEnded`; a still becomes "hold the last frame, stop the clock" for the given seconds (or until input).
2. **Discontinuities.** Every PGC / cell transfer that is not a seamless continuation is a timestamp discontinuity: the source signals a flush + rebase (the engine already handles discontinuous live timelines). Cells flagged `stcDiscontinuity` rebase too. Menus loop short VOBUs, so the rebase path must be cheap.
3. **Highlight overlay.** The menu's subpicture stream (forced, SPRM 2 = 63 semantics) is decoded into its 2-bit pixel codes, and for the selected button's rectangle the PCI colour scheme (selection or action colour + contrast per code) is applied through the PGC's YCrCb palette. A small clean-room SPU decoder from [spu.html](https://dvd.sourceforge.net/dvdinfo/spu.html) (RLE + control sequence) is preferred over FFmpeg's `dvdsub`, which returns pre-coloured RGBA and loses the codes. The result rides the existing subtitle overlay compositor.
4. **Input.** Siri Remote / keyboard arrows -> `DVDHighlightNavigator.move` -> `selectButton`; select / click -> `activateButton` (briefly showing the action colours); auto-action buttons fire on selection; touch and pointer hit-test in the menu's 720x480 (or 720x576) space, scaled from the view; Menu / Top Menu keys -> `menuCall(.root / .title)`; Back -> `resume` when in a menu with a resume point. `btn_sl_e_ptm` + `foac_btnn` (forced action at selection end), `fosl_btnn` (forced select) and the VOBU UOP mask come from the current PCI.
5. **Engine API.** `engine.dvdMenuState` (`@Published`: domain, buttons, highlighted button, still), `engine.dvdNavigate(_ direction:)`, `engine.dvdActivate()`, `engine.dvdActivate(at point:)`, `engine.dvdMenu(_ type:)`, `engine.dvdResume()`, with docs in docs/api.md (the public-API documentation test requires it). `LoadOptions.dvdStartMode: .menu / .mainTitle` maps to Play Disc / Skip to Movie.
6. **Tests.** The navigation source against the fixture ISO (sector walk, cell transitions, still handling) and a decode smoke test over the menu VOB.

Estimate: about 4-6 focused working days for 1-5 with tests (the navigation source and discontinuity handling are the bulk; the SPU decoder and overlay about a day; input and API about a day), plus device testing on Apple TV with two or three commercial-style discs.

## Phase 3: app UX (OpenStream)

Title page with **Play Disc** / **Skip to Movie**; `opticaldisc` corner badge for DVD ISOs in the library; the spinning `opticaldisc` opening animation while the VM runs first-play (FBI warnings and logos are part of "menu first", but the animation covers I/O latency before the first cell); remote and touch mapping per platform; graceful fallback to Skip to Movie on `.fault` with a non-blocking notice.

## Staying in sync with upstream

The fork tracks `github.com/superuser404notfound/AetherEngine` as remote `upstream`. All DVD menu work stays in its own files (`Sources/AetherEngine/Disc/DVDMenu/`, `Tests/AetherEngineTests/DVDMenu/`, `Tests/Fixtures/dvd/`, this doc, `Scripts/sync-upstream.sh`) plus a one-line `.gitignore` exception, so rebases rarely conflict. Phase 2 will touch `DiscReader` and the engine API; keep those hooks small.

`Scripts/sync-upstream.sh [TAG] [--in-place] [--push] [--full-tests]` fetches upstream tags, replays the branch's commits onto `TAG` (default: newest upstream release tag), builds, runs the DVD and disc tests (or the full suite) and optionally pushes with `--force-with-lease`. By default it writes a new branch `dvd-menus-on-<TAG>` so the branch a host pins keeps working until the rebased one is verified; `--in-place` moves `dvd-menus` itself. When OpenStream moves its pin to a new upstream release, run the script for that tag, then tag the result in the fork (for example `7.9.0-dvd.1`) and point OpenStream's package dependency at the fork and that tag.
