import Foundation
import CoreGraphics
import CoreVideo

// The DVD navigation source + menu presenter (docs/dvd-menus.md, phase 2).
//
// DVDMenuPlayer runs the navigation VM against a disc and turns its actions into pictures:
//  - playCell: walks the cell VOBU by VOBU (NAV packs: highlight info, UOP masks), decodes its MPEG-2
//    video and subpictures in software, and paces frames on a media clock that only advances while a
//    cell plays. Every cell transfer that is not a straight continuation is a timestamp discontinuity:
//    the next cell's first frame is rebased onto the session's monotonic presentation clock;
//  - still: holds the last picture and stops the media clock (finite stills end on wall time, infinite
//    ones wait for input);
//  - highlights: the menu subpicture is decoded by the clean-room SPU decoder and the selected button's
//    rectangle recoloured with the PCI selection / action scheme, then burnt into the frame through the
//    engine's SubtitleFrameCompositor (and also published as a SubtitleImage for hosts that overlay);
//  - titles: either handed to the host (`externalTitles`, the engine's normal playback pipeline, which
//    keeps hardware decode, audio and subtitles) or decoded here like a menu (`internal`, used by tests
//    and as a fallback).
// Time is injected (`advance(by:)`), so the whole thing runs deterministically in a headless test.
// Not thread-safe: the owner serializes every call (the engine uses one serial queue).

/// Which button-group layout / subpicture stream a menu uses on this display.
enum DVDDisplayMode: Int, Sendable {
    case normal = 0        // 4:3 menus as authored, or 16:9 menus on a 16:9 display
    case letterbox = 1
    case panScan = 2
}

/// A presented picture.
struct DVDMenuFrame {
    /// BGRA, highlight burnt in when a menu shows buttons. Pixel aspect attached.
    let pixelBuffer: CVPixelBuffer
    /// Monotonic across cells, stills and discontinuities (seconds since `start`).
    let presentationTime: Double
    /// The source PTS of the picture (seconds), for diagnostics.
    let sourcePTS: Double
    let domain: DVDDomain
}

/// What the host shows / needs to know right now.
struct DVDMenuSnapshot: Equatable {
    var domain: DVDDomain = .firstPlay
    var isStill = false
    var isWaitingForTitle = false
    /// Buttons of the active group (empty outside menus / when the VOBU carries no highlight info).
    var buttons: [DVDButton] = []
    var highlightedButton: Int = 0
    var titleNumber: Int = 0
    var chapter: Int = 0
    var pgcn: Int = 0
    var cell: Int = 0
    var menuSize = (width: 720, height: 480)

    static func == (a: DVDMenuSnapshot, b: DVDMenuSnapshot) -> Bool {
        a.domain == b.domain && a.isStill == b.isStill && a.isWaitingForTitle == b.isWaitingForTitle &&
            a.buttons == b.buttons && a.highlightedButton == b.highlightedButton && a.titleNumber == b.titleNumber &&
            a.chapter == b.chapter && a.pgcn == b.pgcn && a.cell == b.cell &&
            a.menuSize.width == b.menuSize.width && a.menuSize.height == b.menuSize.height
    }
}

/// A title PGC for the host's normal playback pipeline.
struct DVDTitleRequest: Equatable {
    let vts: Int
    let title: Int
    let vtsTitle: Int
    let pgcn: Int
    let startCell: Int
    /// Sector ranges of the title VOB set to play, start cell (and resume offset) onward.
    let sectorRanges: [Range<UInt32>]
    /// Start time of each cell from `startCell` on, relative to the start of the request (seconds).
    let cellStartSeconds: [Double]
    /// MPEG-PS stream ids selected by SPRM 1 / SPRM 2 through the PGC stream control: audio substream
    /// (0x80+n AC-3, 0xA0+n LPCM, 0x88+n DTS, or 0xC0+n MPEG) and subpicture stream (0x20+n), nil = default / off.
    let audioStreamNumber: Int?
    let subpictureStreamNumber: Int?
    let isResume: Bool
}

final class DVDMenuPlayer {
    enum TitleMode: Sendable { case decodeHere, external }

    let disc: DVDDiscSource
    let vm: DVDVirtualMachine
    var displayMode: DVDDisplayMode
    let titleMode: TitleMode
    var state: DVDVMState

    // Outputs.
    var onFrame: ((DVDMenuFrame) -> Void)?
    var onSnapshot: ((DVDMenuSnapshot) -> Void)?
    var onTitleRequest: ((DVDTitleRequest) -> Void)?
    var onExit: (() -> Void)?
    var onFault: ((String) -> Void)?

    private(set) var snapshot = DVDMenuSnapshot()
    /// The current highlight / subtitle overlay as a bitmap cue (nil = nothing drawn).
    private(set) var overlay: SubtitleImage?
    private(set) var lastFrame: DVDMenuFrame?
    private(set) var running = false

    // Cell playback.
    private var target: DVDPlaybackTarget?
    private var pgc: DVDPGC?
    private var decoder: DVDCellDecoder?
    private var vobus: [DVDVOBU] = []
    private var queued: [(CVPixelBuffer, Double)] = []
    private var decoderDone = false
    private var cellBasePTS: Double?
    private var cellElapsed = 0.0
    private var lastFramePTS: Double?
    private var frameDuration = 1001.0 / 30000.0
    private var subpictures: [Int: (unit: DVDSubpictureUnit, bitmap: DVDSubpictureBitmap?, pts: Double)] = [:]
    private var highlight: DVDHighlightInfo?
    private var currentPCI: DVDPCI?
    private var forcedActionDone = false
    private var activatedButton: Int?

    // Clock.
    private var presentationTime = 0.0
    private var stillRemaining: Double?          // nil = not in a still; .infinity = infinite
    private var tickAccumulator = 0.0
    private var overlayGeneration = 0
    private let compositor = SubtitleFrameCompositor()

    // External title.
    private var externalTitle: DVDTitleRequest?
    static let lookaheadFrames = 12
    /// How far ahead of the picture subpicture units are read (seconds).
    static let subpictureLookahead = 1.0
    private var spuScanner = DVDSubpictureScanner()
    private var spuScanIndex = 0

    init(disc: DVDDiscSource, settings: DVDPlayerSettings = DVDPlayerSettings(),
         displayMode: DVDDisplayMode = .normal, titleMode: TitleMode = .decodeHere) {
        self.disc = disc
        self.vm = DVDVirtualMachine(navigation: disc.navigation, settings: settings)
        self.state = vm.initialState()
        self.displayMode = displayMode
        self.titleMode = titleMode
    }

    deinit { decoder?.close() }

    // MARK: Lifecycle

    /// Play Disc (first-play, normally landing on the disc's menu) or Skip to Movie (the main title).
    func start(skipToMainTitle: Bool = false) {
        running = true
        if skipToMainTitle, let main = disc.navigation.mainTitle {
            apply(vm.handle(&state, .playTitle(main)))
        } else {
            apply(vm.handle(&state, .start))
        }
    }

    func stop() {
        running = false
        closeCell()
    }

    /// Advances wall / media time by `seconds`: plays frames that fell due, ends cells, runs stills
    /// and the VM's 1 Hz timers.
    func advance(by seconds: Double) {
        guard running, seconds > 0 else { return }
        tickAccumulator += seconds
        while tickAccumulator >= 1 {
            tickAccumulator -= 1
            let a = vm.handle(&state, .tick(seconds: 1), vobuProhibited: currentPCI?.prohibitedOperations ?? [])
            if a != .continuePlayback { apply(a); return }
        }
        if externalTitle != nil { return }
        if let remaining = stillRemaining {
            presentationTime += seconds
            guard remaining.isFinite else { return }
            stillRemaining = remaining - seconds
            if stillRemaining! <= 0 {
                stillRemaining = nil
                apply(vm.handle(&state, .stillEnded))
            }
            return
        }
        guard target != nil else { return }
        presentationTime += seconds
        cellElapsed += seconds
        pump()
    }

    // MARK: Input

    var buttons: [DVDButton] { snapshot.buttons }

    /// Remote / keyboard arrows.
    func navigate(_ direction: DVDDirection) {
        guard !buttons.isEmpty else { return }
        let next = DVDHighlightNavigator.move(direction, from: state.highlightedButton, in: buttons)
        select(button: next)
    }

    /// Pointer hover / programmatic selection. Auto-action buttons fire on selection.
    func select(button n: Int) {
        guard let b = buttons.first(where: { $0.number == n }) else { return }
        let a = vm.handle(&state, .selectButton(n), vobuProhibited: currentPCI?.prohibitedOperations ?? [])
        guard a == .continuePlayback else { apply(a); return }
        refreshOverlay(emit: true)
        if b.autoAction { activate() }
    }

    /// OK / select / click: shows the button in its action colours, then runs its command.
    func activate() {
        guard let b = buttons.first(where: { $0.number == state.highlightedButton }) else { return }
        activatedButton = b.number
        refreshOverlay(emit: true)
        activatedButton = nil
        apply(vm.handle(&state, .activateButton(b), vobuProhibited: currentPCI?.prohibitedOperations ?? []))
    }

    /// Touch / click at a point in menu coordinates (e.g. 720x480).
    func activate(atX x: Int, y: Int) {
        guard let b = DVDHighlightNavigator.button(atX: x, y: y, in: buttons) else { return }
        if b.number != state.highlightedButton { select(button: b.number) }
        if b.autoAction { return }        // selection already fired it
        activate()
    }

    /// Hover: selects the button under the pointer.
    func hover(atX x: Int, y: Int) {
        guard let b = DVDHighlightNavigator.button(atX: x, y: y, in: buttons), b.number != state.highlightedButton else { return }
        select(button: b.number)
    }

    func menu(_ type: DVDMenuType) { userEvent(.menuCall(type)) }
    func resume() { userEvent(.resume) }
    func stillOff() { userEvent(.stillOff) }
    func playTitle(_ ttn: Int) { userEvent(.playTitle(ttn)) }
    func nextChapter() { userEvent(.nextChapter) }
    func previousChapter() { userEvent(.previousChapter) }

    private func userEvent(_ e: DVDVMEvent) {
        if externalTitle != nil, case .menuCall = e {
            // The host is playing the title; the menu key suspends it at its last reported position
            // (`titlePosition(seconds:)`), and the menu takes over the picture.
            externalTitle = nil
        }
        let a = vm.handle(&state, e, vobuProhibited: currentPCI?.prohibitedOperations ?? [])
        if case .prohibited = a { return }
        apply(a)
    }

    // MARK: External titles

    /// The host played the requested title PGC to its end.
    func titleDidEnd() {
        guard let req = externalTitle else { return }
        externalTitle = nil
        // The host played every cell of the PGC; walk the VM through them (cell commands and stills
        // included, stills skipped since the picture is gone).
        var a = vm.handle(&state, .cellPlaybackEnded)
        var guardCount = 0
        while guardCount < 512 {
            guardCount += 1
            if case .playCell(let t) = a, t.domain == .title, t.vobs == .title(vts: req.vts), t.pgcn == req.pgcn,
               t.cellNumber > state.cell - 1 {
                a = vm.handle(&state, .cellPlaybackEnded)
                continue
            }
            if case .still(let s) = a, state.domain == .title, s != nil {
                a = vm.handle(&state, .stillEnded)
                continue
            }
            break
        }
        apply(a)
    }

    /// The host is suspending the title at `seconds` into the request (menu key / CallSS): records the
    /// cell for RSM. The sector offset inside the cell is not known on the host path, so resume lands
    /// on the cell's start.
    func titlePosition(seconds: Double) {
        guard let req = externalTitle else { return }
        var cell = req.startCell
        for (i, start) in req.cellStartSeconds.enumerated() where start <= seconds { cell = req.startCell + i }
        // Re-point the VM at the cell the host reached so a CallSS / menu key saves the right resume cell.
        if cell != state.cell, let pgc = vm.currentPGC(state), pgc.cells.indices.contains(cell - 1) {
            state.cell = cell
            state.pgn = pgc.program(containing: cell)
        }
        _ = vm.handle(&state, .position(sectorOffset: 0))
    }

    // MARK: Actions

    private func apply(_ action: DVDVMAction) {
        switch action {
        case .playCell(let t):
            stillRemaining = nil
            if t.domain == .title, titleMode == .external {
                requestExternalTitle(t)
            } else {
                openCell(t)
            }
        case .still(let seconds):
            stillRemaining = seconds.map(Double.init) ?? .infinity
            publish()
        case .continuePlayback:
            refreshOverlay(emit: true)
            publish()
        case .prohibited:
            break
        case .exit:
            running = false
            closeCell()
            publish()
            onExit?()
        case .fault(let reason):
            running = false
            closeCell()
            onFault?(reason)
        }
    }

    private func requestExternalTitle(_ t: DVDPlaybackTarget) {
        closeCell()
        target = t
        guard let pgc = vm.currentPGC(state) else { onFault?("title PGC missing"); return }
        self.pgc = pgc
        let ranges = DVDDiscSource.cellRanges(of: pgc, fromCell: t.cellNumber, angle: Int(state.sprm[3]),
                                             startSectorOffset: t.startSectorOffset)
        var starts: [Double] = []
        var acc = 0.0
        for c in pgc.cells.dropFirst(t.cellNumber - 1) { starts.append(acc); acc += c.playbackTime.totalSeconds }
        let audioTrack = Int(state.sprm[1])
        let sp = state.sprm[2]
        let req = DVDTitleRequest(
            vts: state.vtsn, title: Int(state.sprm[4]), vtsTitle: Int(state.sprm[5]), pgcn: t.pgcn,
            startCell: t.cellNumber, sectorRanges: ranges, cellStartSeconds: starts,
            audioStreamNumber: audioTrack == 15 ? nil : pgc.audioStream(track: audioTrack),
            subpictureStreamNumber: sp & 0x40 != 0 ? pgc.subpictureStream(track: Int(sp & 0x1F), mode: displayMode == .normal ? 0 : displayMode.rawValue + 1) : nil,
            isResume: t.startSectorOffset > 0)
        externalTitle = req
        publish()
        onTitleRequest?(req)
    }

    // MARK: Cell playback

    private func closeCell() {
        decoder?.close()
        decoder = nil
        queued.removeAll()
        vobus.removeAll()
        target = nil
    }

    private func openCell(_ t: DVDPlaybackTarget) {
        // A subpicture unit is muxed ahead of the time it shows, often in the previous cell's bytes, so a
        // sequential continuation inside one PGC keeps what is displayed; any other transfer starts clean.
        let continuing = target.map { $0.domain == t.domain && $0.vobs == t.vobs && $0.pgcn == t.pgcn && t.cellNumber == $0.cellNumber + 1 } ?? false
        closeCell()
        target = t
        pgc = vm.currentPGC(state)
        cellBasePTS = nil
        cellElapsed = 0
        lastFramePTS = nil
        decoderDone = false
        if !continuing { subpictures.removeAll(); spuScanner = DVDSubpictureScanner() }
        spuScanIndex = 0
        highlight = nil
        currentPCI = nil
        forcedActionDone = false
        let first = t.cell.firstVOBUStart &+ t.startSectorOffset
        vobus = disc.walkCell(t.cell, in: t.vobs, startSectorOffset: t.startSectorOffset)
        if let reader = disc.makeReader(t.vobs, sectorRanges: [first ..< t.cell.lastVOBUEnd + 1]) {
            decoder = try? DVDCellDecoder(reader: reader)
        }
        if decoder == nil { decoderDone = true }
        // Highlight info and the menu's subpicture are known from the first VOBU before any frame decodes.
        if let nav = vobus.first?.nav { applyPCI(nav.pci) }
        scanSubpictures(through: Double(vobus.first?.nav?.pci.vobuStartPTM ?? 0) / 90000 + Self.subpictureLookahead)
        publish()
        pump()
    }

    /// Decodes until the frame due at `cellElapsed` is known, emits it, and ends the cell after its last frame.
    private func pump() {
        guard let t = target else { return }
        var emitted: (CVPixelBuffer, Double)?
        while true {
            // Keep ~0.4 s decoded ahead: subpicture units (and their highlight / subtitle pictures) are
            // muxed by byte position, not display time, and must be known when their time comes.
            while queued.count < Self.lookaheadFrames, !decoderDone { decodeOne() }
            guard let (pb, pts) = queued.first else { break }
            let base = cellBasePTS ?? pts
            if cellBasePTS == nil { cellBasePTS = pts }
            guard pts - base <= cellElapsed + 1e-6 else { break }
            queued.removeFirst()
            if let last = lastFramePTS, pts > last { frameDuration = min(max(pts - last, 1.0 / 60), 0.1) }
            lastFramePTS = pts
            emitted = (pb, pts)
        }
        if let (pb, pts) = emitted {
            scanSubpictures(through: pts + Self.subpictureLookahead)
            updateHighlight(atPTS: pts)
            emit(pb, sourcePTS: pts, domain: t.domain)
        }
        // End of cell: decoder drained, nothing queued, last frame shown for its duration.
        if decoderDone, queued.isEmpty {
            let base = cellBasePTS ?? 0
            let end = (lastFramePTS.map { $0 - base + frameDuration }) ?? t.cell.playbackTime.totalSeconds
            if cellElapsed + 1e-6 >= end {
                let a = vm.handle(&state, .cellPlaybackEnded)
                apply(a)
            }
        }
    }

    /// Reads the subpicture units of every VOBU starting before `seconds` that has not been scanned yet.
    private func scanSubpictures(through seconds: Double) {
        guard let t = target else { return }
        let limit = UInt32(truncatingIfNeeded: Int64((seconds * 90000).rounded()))
        while spuScanIndex < vobus.count {
            let v = vobus[spuScanIndex]
            if let nav = v.nav, nav.pci.vobuStartPTM > limit, spuScanIndex > 0 { break }
            spuScanIndex += 1
            for found in spuScanner.scan(disc.readSectors(t.vobs, from: v.sector, count: v.sectorCount)) {
                subpictures[found.stream] = (found.unit, found.unit.decodePixels(), found.pts ?? seconds)
            }
        }
    }

    private func decodeOne() {
        guard let d = decoder, let ev = d.next() else { decoderDone = true; return }
        switch ev {
        case .video(let pb, let pts):
            queued.append((pb, pts))
        }
    }

    // MARK: Highlight / subpicture overlay

    private func applyPCI(_ pci: DVDPCI) {
        currentPCI = pci
        switch pci.highlight.status {
        case 1: highlight = pci.highlight; forcedActionDone = false
        case 2: break                                            // keep the previous VOBU's
        case 3:
            if let prev = highlight {                            // previous geometry, this VOBU's commands
                let cmds = pci.highlight.slots
                highlight = DVDHighlightInfo(
                    status: prev.status, startPTM: prev.startPTM, endPTM: prev.endPTM,
                    buttonSelectEndPTM: prev.buttonSelectEndPTM, groupCount: prev.groupCount, groupTypes: prev.groupTypes,
                    startButton: prev.startButton, buttonCount: prev.buttonCount, numericSelectCount: prev.numericSelectCount,
                    forcedSelectButton: prev.forcedSelectButton, forcedActionButton: prev.forcedActionButton,
                    colors: prev.colors, slots: zip(prev.slots, cmds).map { DVDButton(copying: $0, command: $1.command) })
            } else { highlight = pci.highlight }
        default: highlight = nil
        }
        if let h = highlight, h.forcedSelectButton > 0, h.status == 1 {
            _ = vm.handle(&state, .selectButton(h.forcedSelectButton))
        }
        let group = highlight.map { $0.group(forDisplayMode: displayMode.rawValue) } ?? 1
        snapshot.buttons = highlight?.buttons(group: group) ?? []
        if !snapshot.buttons.isEmpty, !snapshot.buttons.contains(where: { $0.number == state.highlightedButton }) {
            _ = vm.handle(&state, .selectButton(snapshot.buttons[0].number))
        }
    }

    private func updateHighlight(atPTS seconds: Double) {
        let ptm = UInt32(truncatingIfNeeded: Int64((seconds * 90000).rounded()))
        if let v = vobus.last(where: { $0.nav.map { $0.pci.vobuStartPTM <= ptm } ?? false }), let nav = v.nav,
           nav.pci.navPackLBN != currentPCI?.navPackLBN || nav.pci.vobuStartPTM != currentPCI?.vobuStartPTM {
            applyPCI(nav.pci)
        }
        // Forced action at the end of button selection.
        if let h = highlight, !forcedActionDone, h.forcedActionButton > 0, h.buttonSelectEndPTM != 0xFFFF_FFFF,
           ptm >= h.buttonSelectEndPTM, let b = snapshot.buttons.first(where: { $0.number == h.forcedActionButton }) {
            forcedActionDone = true
            _ = vm.handle(&state, .selectButton(b.number))
            activate()
            return
        }
        refreshOverlay(emit: false)
    }

    /// The subpicture stream to show: in menus the PGC's stream for logical track 0 in this display
    /// mode (menus' subpictures are forced); in titles the SPRM 2 track when its display bit is set.
    private func activeSubpicture() -> (unit: DVDSubpictureUnit, bitmap: DVDSubpictureBitmap?, pts: Double)? {
        guard let pgc else { return subpictures.values.first }
        let modeByte: Int
        if let attrs = menuVideoIsWide, attrs { modeByte = displayMode == .normal ? 1 : displayMode.rawValue + 1 } else { modeByte = 0 }
        if state.domain == .title {
            func showing(_ s: (unit: DVDSubpictureUnit, bitmap: DVDSubpictureBitmap?, pts: Double)?) -> (unit: DVDSubpictureUnit, bitmap: DVDSubpictureBitmap?, pts: Double)? {
                guard let s, let now = lastFramePTS, now >= s.pts else { return nil }
                if let stop = s.unit.stopDelay90k, now >= s.pts + Double(stop) / 90000 { return nil }
                return s
            }
            let sp = state.sprm[2]
            if sp & 0x40 != 0, let n = pgc.subpictureStream(track: Int(sp & 0x1F), mode: modeByte) { return showing(subpictures[n]) }
            return showing(subpictures.values.first { $0.unit.isForced })
        }
        if let n = pgc.subpictureStream(track: 0, mode: modeByte), let s = subpictures[n] { return s }
        return subpictures[0] ?? subpictures.values.first
    }

    private var menuVideoIsWide: Bool? {
        switch state.domain {
        case .vmgMenu, .firstPlay: return disc.navigation.vmgi.menuAttributes?.video.isWidescreen
        case .vtsMenu: return disc.navigation.titleSets[state.vtsn]?.menuAttributes?.video.isWidescreen
        case .title: return disc.navigation.titleSets[state.vtsn]?.titleAttributes?.video.isWidescreen
        }
    }

    private var overlayKey: String?

    /// Rebuilds the overlay for the current highlight; optionally re-presents the last picture with it
    /// (highlight moves during a still must show without new video). Rendering is skipped when nothing
    /// that feeds it changed.
    private func refreshOverlay(emit: Bool) {
        let size = snapshot.menuSize
        let spu = activeSubpicture()
        let inMenu = state.domain != .title
        let button = inMenu ? snapshot.buttons.first { $0.number == state.highlightedButton } : nil
        let activated = activatedButton != nil && activatedButton == button?.number
        let key = "\(spu.map { "\($0.pts)/\($0.unit.data.count)" } ?? "-")|\(button.map { "\($0.number):\($0.x0),\($0.y0),\($0.x1),\($0.y1),\($0.colorScheme)" } ?? "-")|\(activated)|\(highlight?.colors.first?.selectionColor ?? [])|\(state.pgcn)|\(size.width)x\(size.height)"
        if key != overlayKey {
            overlayKey = key
            var image: SubtitleImage?
            if let spu, let bitmap = spu.bitmap, let pgc {
                let scheme = button.flatMap { b -> DVDButtonColors? in
                    guard let h = highlight, b.colorScheme >= 1, h.colors.indices.contains(b.colorScheme - 1) else { return nil }
                    return h.colors[b.colorScheme - 1]
                }
                let r = DVDHighlightRenderer.renderRGBA(
                    bitmap: bitmap, spuColors: spu.unit.colors, spuContrast: spu.unit.contrast, palette: pgc.palette,
                    button: button, scheme: scheme, state: activated ? .activated : .selected)
                if r.visible, let cg = DVDHighlightRenderer.image(rgba: r.pixels, width: bitmap.width, height: bitmap.height) {
                    let w = Double(size.width), h = Double(size.height)
                    image = SubtitleImage(cgImage: cg,
                                          position: CGRect(x: Double(bitmap.x) / w, y: Double(bitmap.y) / h,
                                                           width: Double(bitmap.width) / w, height: Double(bitmap.height) / h),
                                          canvasSize: CGSize(width: w, height: h), isForced: true)
                }
            }
            overlay = image
            overlayGeneration += 1
            compositor.update(cues: image.map { [SubtitleCue(id: overlayGeneration, startTime: -.infinity, endTime: .infinity, body: .image($0))] } ?? [],
                              enabled: image != nil, delaySeconds: 0)   // menu highlights ignore the subtitle delay
        }
        if emit, let last = lastFrame, let raw = lastRawFrame {
            self.emit(raw, sourcePTS: last.sourcePTS, domain: last.domain)
        }
    }

    // MARK: Output

    private var lastRawFrame: CVPixelBuffer?

    private func emit(_ raw: CVPixelBuffer, sourcePTS: Double, domain: DVDDomain) {
        lastRawFrame = raw
        let width = CVPixelBufferGetWidth(raw), height = CVPixelBufferGetHeight(raw)
        snapshot.menuSize = (width, height)
        let composited = overlay == nil ? raw : compositor.composite(raw, ptsSeconds: 0)
        attachPixelAspect(composited, width: width, height: height)
        let frame = DVDMenuFrame(pixelBuffer: composited, presentationTime: presentationTime, sourcePTS: sourcePTS, domain: domain)
        lastFrame = frame
        publish()
        onFrame?(frame)
    }

    private func attachPixelAspect(_ pb: CVPixelBuffer, width: Int, height: Int) {
        let wide = menuVideoIsWide ?? false
        let dar = wide ? 16.0 / 9.0 : 4.0 / 3.0
        let par = dar * Double(height) / Double(width)
        let scale = 1000.0
        let dict: [CFString: Any] = [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(par * scale),
                                     kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(scale)]
        CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, dict as CFDictionary, .shouldPropagate)
    }

    private func publish() {
        snapshot.domain = state.domain
        snapshot.isStill = stillRemaining != nil
        snapshot.isWaitingForTitle = externalTitle != nil
        snapshot.highlightedButton = state.highlightedButton
        snapshot.titleNumber = Int(state.sprm[4])
        snapshot.chapter = Int(state.sprm[7])
        snapshot.pgcn = state.pgcn
        snapshot.cell = state.cell
        onSnapshot?(snapshot)
    }
}

extension DVDButton {
    /// The same geometry with another command (HLI status 3: previous VOBU's buttons, this VOBU's commands).
    init(copying b: DVDButton, command: DVDCommand) {
        self = b
        self.command = command
    }
}
