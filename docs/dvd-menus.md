# DVD-Video menus

Status: **phases 1 and 2 landed** (IFO navigation, the VM, NAV packs, the navigation source and menu presenter, the clean-room subpicture decoder with highlight overlay, remote / touch / pointer input, and the engine API with `LoadOptions.dvdStartMode`). With the default `.mainTitle` a DVD ISO plays exactly as described in [formats.md](formats.md#disc-dvd--blu-ray-iso); `.menu` runs it from its menus.

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

`menu-features.iso` (about 700 KB, `menu-features.xml`) adds the phase 2 cases: a 16:9 title menu with two button groups (widescreen and letterbox subpicture streams), a still-frame menu (one frame plus a 3 s cell still), a 6-button chapter menu, an audio / subtitle setup menu driving SetSTN, and a title with two audio streams and a subtitle stream. Highlight images are indexed PNGs (made with Pillow) so spumux writes real selection / action colours into the PCI.

Test suites (Swift Testing, `Tests/AetherEngineTests/DVDMenu/`): `DVDCommandDecodingTests` (every group from the published byte templates), `DVDVirtualMachineTests` (execution semantics per group on synthetic discs, cell / PGC flow, angle blocks, UOPs, resume, timers, loop faults, purity), `DVDNavPackTests` (hand-built PCI / DSI sectors), `DVDMenuFixtureTests` (the authored disc: IFO structure, NAV-pack buttons, and the VM driven first-play -> menu -> button -> title -> title end -> menu, the GPRM-setting button, the chapter menu, menu keys, resume, Skip to Movie).

## Phase 2: playback wiring (done)

| File | What it does |
|---|---|
| `DVDDiscSource.swift` | Maps VOB-set sectors (VIDEO_TS.VOB, VTS_nn_0.VOB, VTS_nn_1..9.VOB concatenated) onto image byte ranges, walks a cell VOBU by VOBU through the NAV packs (`vobu_ea`), builds seekable readers over sector ranges, and computes a PGC's cell ranges (angle aware) for the title hand-off. |
| `DVDSubpicture.swift` | Clean-room SPU decoder from [spu.html](https://dvd.sourceforge.net/dvdinfo/spu.html): header, control sequences (forced / start / stop display, SET_COLOR, SET_CONTR, SET_DAREA, SET_DSPXA; CHG_COLCON skipped), interlaced RLE with the 4 / 8 / 12 / 16-bit run codes. A PS scanner reads subpicture units straight from VOBU sectors (private stream 1, substreams 0x20-0x3F) ahead of their display time. The highlight renderer recolours the selected button's rectangle with the PCI selection or action colour + contrast through the PGC's YCrCb palette (BT.601). FFmpeg's `dvdsub` decoder is not used: it returns pre-coloured RGBA and loses the pixel codes. |
| `DVDCellDecoder.swift` | Software MPEG-2 decode of a cell to BGRA buffers (menus are SD and short). |
| `DVDMenuPlayer.swift` | The navigation source + presenter. Runs the VM; for each `playCell` walks the cell, decodes it, and paces pictures on an injected media clock. Every cell is rebased onto a monotonic presentation clock, so PGC / domain jumps are clean discontinuities; a sequential continuation inside one PGC keeps the displayed subpicture. Stills hold the last picture and stop the media clock (finite stills end on wall time, infinite ones wait for input). PCI highlight info is applied per VOBU (status 1 new, 2 previous, 3 previous geometry with this VOBU's commands), with forced select, forced action at `btn_sl_e_ptm`, button groups per display mode (normal / letterbox / pan-scan, which also picks the subpicture stream through PGC_SPST_CTL) and the VOBU UOP mask. The overlay is burnt into the picture through the engine's `SubtitleFrameCompositor` and also kept as a `SubtitleImage`. In titles the SPRM 2 subtitle stream is shown when its display bit is set. Input: arrows, select (one picture in the action colours, then the command), touch / click hit-testing, hover, auto-action buttons, menu keys, resume, still-off. Titles are either handed to the host (`external`) or decoded here (`decodeHere`, tests and fallback). |
| `DVDMenuPublic.swift`, `AetherEngine+DVDMenu.swift` | The engine API (see [api.md](api.md#dvd-menus)): `LoadOptions.dvdStartMode` (`.mainTitle` default and unchanged, `.menu`), `$dvdMenu`, `dvdNavigate`, `dvdActivate`, `dvdActivate(atNormalizedPoint:)`, `dvdHover`, `dvdMenu(_:)`, `dvdResume`, `dvdPlayMainTitle`. `DVDMenuController` drives the player on its own queue at 60 Hz, presents pictures on an `AVSampleBufferDisplayLayer` attached to the bound view, and hands a title PGC to the normal `load(source:)` pipeline as a custom MPEG-PS reader over exactly that PGC's cells (with SPRM 1's audio stream as `audioSourceStreamIndex` and SPRM 2's subtitle selected), so title playback is the same code path as Skip to Movie. When the pipeline reaches `.ended` the VM runs the rest of the PGC (cell and post commands) and the menu takes the picture back. |

Tests: `DVDSubpictureTests` (RLE / control sequences, renderer, scanner, assembler, sector mapping, cell walk), `DVDMenuPlayerTests` (headless: first-play -> menu -> arrows -> activate -> title -> back, with pixel checks of the selected / activated highlight, the GPRM button, Skip to Movie, external hand-off and resume, the 16:9 two-group menu, the still-frame menu holding its picture with the clock stopped, the 6-button chapter menu, the audio / subtitle setup menu, subtitles on / off in the title) and `DVDEngineMenuTests` (the public API end to end, including a title played by the real engine pipeline and the return to the menu at its end).

Known limits, next:

- **Menu audio is not played** (menus are silent; titles have full audio through the normal pipeline). Next: decode the menu's audio stream in the player and feed an `AVSampleBufferAudioRenderer` on the same clock.
- Resume on the host path lands on the start of the cell the pipeline had reached (the pipeline does not report sectors); RSM inside one long single-cell title therefore restarts the title. Next: map the pipeline time back to a VOBU through the time map (VTS_TMAPTI) and resume there.
- Each cell is a fresh decode, so motion menus that loop through `LinkTopCell` show a sub-frame gap at the loop point, and seamless multi-cell menus re-open per cell.
- Interleaved (multi-angle / seamless-branching) blocks are walked as contiguous sectors; titles using them play through the pipeline like the existing whole-PGC path.
- Cell commands inside a title run when the pipeline reports the title's end, not at each cell boundary; PGC still times inside titles are skipped on the host path.
- Parental management (SetTmpPML, PTL_MAIT) and region enforcement stay off.

## Phase 3: app UX (OpenStream)

Title page with **Play Disc** / **Skip to Movie**; `opticaldisc` corner badge for DVD ISOs in the library; the spinning `opticaldisc` opening animation while the VM runs first-play (FBI warnings and logos are part of "menu first", but the animation covers I/O latency before the first cell); remote and touch mapping per platform; graceful fallback to Skip to Movie on `.fault` with a non-blocking notice.

## Staying in sync with upstream

The fork tracks `github.com/superuser404notfound/AetherEngine` as remote `upstream`. All DVD menu work stays in its own files (`Sources/AetherEngine/Disc/DVDMenu/`, `Tests/AetherEngineTests/DVDMenu/`, `Tests/Fixtures/dvd/`, this doc, `Scripts/sync-upstream.sh`) plus a one-line `.gitignore` exception, so rebases rarely conflict. Phase 2 added small hooks in upstream files, the places a rebase can conflict: `AetherEngine.swift` (the `dvdMenu` / session properties, `boundView` and `loadedOptions` visibility, the `.menu` branch at the top of `load(source:)`, one line in `stop()`), `PlayerState.swift` (`LoadOptions.dvdStartMode`), `AetherEngine+ReloadWithOptions.swift` (the field inventory), `PlaybackErrorInfo.swift` (`.dvdNavigationFailed`) and `docs/api.md`.

`Scripts/sync-upstream.sh [TAG] [--in-place] [--push] [--full-tests]` fetches upstream tags, replays the branch's commits onto `TAG` (default: newest upstream release tag), builds, runs the DVD and disc tests (or the full suite) and optionally pushes with `--force-with-lease`. By default it writes a new branch `dvd-menus-on-<TAG>` so the branch a host pins keeps working until the rebased one is verified; `--in-place` moves `dvd-menus` itself. When OpenStream moves its pin to a new upstream release, run the script for that tag, then tag the result in the fork (for example `7.9.0-dvd.1`) and point OpenStream's package dependency at the fork and that tag.
