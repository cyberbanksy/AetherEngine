import Foundation
import CoreVideo
import Testing
@testable import AetherEngine

/// Headless end-to-end runs of the navigation source + menu presenter over the authored fixture discs:
/// real NAV-pack walking, real MPEG-2 decode, the clean-room SPU decoder and the highlight overlay burnt
/// in through SubtitleFrameCompositor, driven by an injected clock.
struct DVDMenuPlayerTests {
    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/dvd/\(name)")
    }

    /// Collects the player's output and runs its clock.
    final class Harness {
        let player: DVDMenuPlayer
        var frames: [DVDMenuFrame] = []
        var titleRequests: [DVDTitleRequest] = []
        var exited = false
        var fault: String?

        init(_ disc: String, displayMode: DVDDisplayMode = .normal, titleMode: DVDMenuPlayer.TitleMode = .decodeHere) throws {
            player = DVDMenuPlayer(disc: try DVDDiscSource(url: DVDMenuPlayerTests.fixture(disc)),
                                   displayMode: displayMode, titleMode: titleMode)
            player.onFrame = { [unowned self] in frames.append($0) }
            player.onTitleRequest = { [unowned self] in titleRequests.append($0) }
            player.onExit = { [unowned self] in exited = true }
            player.onFault = { [unowned self] in fault = $0 }
        }

        /// Steps the clock at 30 Hz until `until` holds or `seconds` elapse. Returns whether it held.
        @discardableResult
        func run(seconds: Double, until: (() -> Bool)? = nil) -> Bool {
            var t = 0.0
            while t < seconds {
                if let until, until() { return true }
                player.advance(by: 1.0 / 30)
                t += 1.0 / 30
            }
            return until?() ?? true
        }

        var snapshot: DVDMenuSnapshot { player.snapshot }
        var last: DVDMenuFrame? { frames.last }
    }

    /// BGRA pixel of a frame.
    static func pixel(_ f: DVDMenuFrame, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let pb = f.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let o = y * CVPixelBufferGetBytesPerRow(pb) + x * 4
        return (Int(base[o + 2]), Int(base[o + 1]), Int(base[o]))
    }

    static func isYellow(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 170 && p.g > 170 && p.b < 110 }
    static func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 160 && p.g < 100 && p.b < 100 }
    static func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 190 && p.g > 190 && p.b > 190 }
    static func isNavy(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.b > 80 && p.r < 60 && p.g < 60 }

    // MARK: The full loop on menu-test.iso

    @Test func firstPlayMenuNavigateActivateTitleAndBack() throws {
        let h = try Harness("menu-test.iso")
        h.player.start()
        // First-play -> VMGM title menu: frames out, then the infinite still.
        #expect(h.run(seconds: 3) { h.snapshot.isStill })
        #expect(h.snapshot.domain == .vmgMenu)
        #expect(h.snapshot.buttons.count == 3)
        #expect(h.snapshot.highlightedButton == 1)
        let menu = try #require(h.last)
        #expect(menu.domain == .vmgMenu)
        #expect(CVPixelBufferGetWidth(menu.pixelBuffer) == 720 && CVPixelBufferGetHeight(menu.pixelBuffer) == 480)
        #expect(Self.isNavy(Self.pixel(menu, 500, 400)), "background \(Self.pixel(menu, 500, 400))")
        // Button 1 outline in the selection colour, button 2 in the subpicture's normal colour.
        #expect(Self.isYellow(Self.pixel(menu, 200, 101)), "selected \(Self.pixel(menu, 200, 101))")
        #expect(Self.isWhite(Self.pixel(menu, 200, 201)), "normal \(Self.pixel(menu, 200, 201))")
        #expect(h.player.overlay != nil)

        // Arrow down: the highlight moves to button 2 and a new picture goes out even though the menu is a still.
        let before = h.frames.count
        h.player.navigate(.down)
        #expect(h.snapshot.highlightedButton == 2)
        #expect(h.frames.count > before)
        let moved = try #require(h.last)
        #expect(Self.isYellow(Self.pixel(moved, 200, 201)))
        #expect(Self.isWhite(Self.pixel(moved, 200, 101)))
        h.player.navigate(.up)
        #expect(h.snapshot.highlightedButton == 1)

        // Activate: one picture in the action colour, then the command runs (JumpTT 1).
        let mark = h.frames.count
        h.player.activate()
        let activated = h.frames[mark]
        #expect(Self.isRed(Self.pixel(activated, 200, 101)), "activated \(Self.pixel(activated, 200, 101))")
        #expect(h.snapshot.domain == .title)

        // Title 1 plays (gray frames, no buttons) through both cells, then its post command calls the menu.
        #expect(h.run(seconds: 1) { h.last?.domain == .title })
        let title = try #require(h.last)
        let gray = Self.pixel(title, 360, 240)
        #expect(abs(gray.r - gray.g) < 20 && gray.r > 90 && gray.r < 170, "title \(gray)")
        #expect(h.snapshot.buttons.isEmpty)
        #expect(h.run(seconds: 4) { h.snapshot.domain == .vmgMenu && h.snapshot.isStill })
        #expect(h.player.state.resume?.pgcn == 1)

        // Presentation time is monotonic across menu -> title -> menu (each cell rebased).
        let times = h.frames.map(\.presentationTime)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(h.fault == nil)
    }

    @Test func gprmButtonTitleTwoEndsInTheChapterMenu() throws {
        let h = try Harness("menu-test.iso")
        h.player.start()
        h.run(seconds: 3) { h.snapshot.isStill }
        h.player.navigate(.up)                                // 1 -> 3 (wraps)
        #expect(h.snapshot.highlightedButton == 3)
        h.player.activate()
        #expect(h.player.state.gprm[2] == 7)
        #expect(h.snapshot.domain == .title && h.snapshot.titleNumber == 2)
        #expect(h.run(seconds: 4) { h.snapshot.domain == .vtsMenu && h.snapshot.isStill })
        #expect(h.snapshot.buttons.count == 3)
        // Touch on chapter 2's button: title 1 from its second cell.
        h.player.activate(atX: 150, y: 230)
        #expect(h.snapshot.domain == .title && h.snapshot.chapter == 2 && h.snapshot.cell == 2)
    }

    @Test func skipToMovieStartsTheMainTitle() throws {
        let h = try Harness("menu-test.iso")
        h.player.start(skipToMainTitle: true)
        #expect(h.snapshot.domain == .title && h.snapshot.titleNumber == 1)
        #expect(h.run(seconds: 1) { h.last?.domain == .title })
    }

    // MARK: Title hand-off to the host pipeline

    @Test func externalTitleRequestAndReturn() throws {
        let h = try Harness("menu-test.iso", titleMode: .external)
        h.player.start()
        h.run(seconds: 3) { h.snapshot.isStill }
        h.player.activate()
        let req = try #require(h.titleRequests.last)
        #expect(req.vts == 1 && req.title == 1 && req.pgcn == 1 && req.startCell == 1)
        #expect(req.sectorRanges == [0 ..< 35])                     // both cells, contiguous
        #expect(req.cellStartSeconds.count == 2 && abs(req.cellStartSeconds[1] - 1.2) < 0.01)
        #expect(h.snapshot.isWaitingForTitle)
        // The request's sectors demux as MPEG-PS with video.
        let reader = try #require(h.player.disc.makeReader(.title(vts: 1), sectorRanges: req.sectorRanges))
        let decoder = try DVDCellDecoder(reader: reader)
        #expect(decoder.hasVideo)
        var frames = 0
        while let e = decoder.next() { if case .video = e { frames += 1 } }
        #expect(frames >= 50)
        // While waiting, the clock does not drive the menu.
        let n = h.frames.count
        h.run(seconds: 1)
        #expect(h.frames.count == n)
        // Host reports the end: post command CallSS -> back on the menu.
        h.player.titleDidEnd()
        #expect(h.snapshot.domain == .vmgMenu && !h.snapshot.isWaitingForTitle)
        #expect(h.run(seconds: 3) { h.snapshot.isStill })
    }

    @Test func externalTitleMenuKeyResumesAtTheReachedCell() throws {
        let h = try Harness("menu-test.iso", titleMode: .external)
        h.player.start()
        h.run(seconds: 3) { h.snapshot.isStill }
        h.player.activate()
        h.player.titlePosition(seconds: 1.5)                   // inside cell 2
        h.player.menu(.title)
        #expect(h.snapshot.domain == .vmgMenu)
        #expect(h.player.state.resume?.cell == 2)
        h.player.resume()
        let req = try #require(h.titleRequests.last)
        #expect(req.startCell == 2 && h.titleRequests.count == 2)
        #expect(req.sectorRanges == h.titleRequests[0].sectorRanges)
        #expect(req.cellStartSeconds == h.titleRequests[0].cellStartSeconds)
        #expect(abs(try #require(req.startSeconds) - 1.2002) < 0.0001)
        h.player.titlePosition(seconds: 1.5)
        h.player.menu(.title)
        #expect(h.player.state.resume?.cell == 2)
    }

    @Test func externalChapterEntrySelectsAngleTwo() throws {
        let source = try #require(FileIOReader(url: Self.fixture("menu-features.iso")))
        defer { source.close() }
        let iso = try ISO9660Reader(reader: source)
        let file = try #require(try iso.list(directory: "VIDEO_TS").first { $0.name == "VTS_01_0.IFO" })
        var bytes = [UInt8](try Data(contentsOf: Self.fixture("menu-features.iso")))
        let ifo = file.startSector * iso.sectorSize
        let b = DVDBytes(bytes)
        let table = ifo + Int(try #require(b.u32(ifo + 0xCC))) * 2048
        let pgc = table + Int(try #require(b.u32(table + 12)))
        let cells = pgc + Int(try #require(b.u16(pgc + 0xE8)))
        bytes[cells + 24] = (bytes[cells + 24] & 0x0F) | 0x50
        bytes[cells + 48] = (bytes[cells + 48] & 0x0F) | 0xD0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iso")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(bytes).write(to: url)
        let disc = try DVDDiscSource(url: url)
        defer { disc.reader.close() }
        let player = DVDMenuPlayer(disc: disc, titleMode: .external)
        var requests: [DVDTitleRequest] = []
        var fault: String?
        player.onTitleRequest = { requests.append($0) }
        player.onFault = { fault = $0 }
        player.state.sprm[3] = 2
        player.playTitle(1)
        player.nextChapter()
        #expect(fault == nil)
        #expect(requests.count == 2)
        let request = try #require(requests.last)
        #expect(request.angle == 2)
        #expect(request.startCell == 3)
        #expect(request.selectedCells == [0, 2, 3, 4, 5])
        #expect(request.startSeconds == request.cellStartSeconds[2])
        #expect(try #require(request.startSeconds) > 0)
    }

    @Test func malformedTitleStartCellDoesNotIndexPastThePGC() {
        let request = DVDTitleRequest(vts: 1, title: 1, vtsTitle: 1, pgcn: 1, startCell: 2,
            sectorRanges: [0 ..< 16], cellStartSeconds: [0], selectedCells: [0], durationSeconds: 1,
            angle: 1, audioStreamNumber: nil, subpictureStreamNumber: nil, isResume: false)
        #expect(request.startSeconds == nil)
    }

    // MARK: menu-features.iso

    @Test func widescreenMenuUsesTheButtonGroupForTheDisplayMode() throws {
        let wide = try Harness("menu-features.iso", displayMode: .normal)
        wide.player.start()
        #expect(wide.run(seconds: 3) { wide.snapshot.isStill })
        #expect(wide.snapshot.buttons.map(\.y0) == [100, 200, 300])
        let lb = try Harness("menu-features.iso", displayMode: .letterbox)
        lb.player.start()
        #expect(lb.run(seconds: 3) { lb.snapshot.isStill })
        #expect(lb.snapshot.buttons.map(\.y0) == [120, 195, 270])
        // Letterbox layout is drawn from subpicture stream 1: button 1's outline at its letterbox position.
        let f = try #require(lb.last)
        #expect(Self.isYellow(Self.pixel(f, 200, 121)), "letterbox highlight \(Self.pixel(f, 200, 121))")
        // 16:9 menu frames carry a widescreen pixel aspect.
        let par = CVBufferCopyAttachment(f.pixelBuffer, kCVImageBufferPixelAspectRatioKey, nil) as? [CFString: Int]
        #expect(par?[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] ?? 0 > 1100)
    }

    @Test func stillFrameMenuHoldsThePictureAndStopsTheClock() throws {
        let h = try Harness("menu-features.iso")
        h.player.start()
        h.run(seconds: 3) { h.snapshot.isStill }
        h.player.select(button: 3)
        h.player.activate()                                   // -> VMGM menu 2: one frame + 3 s cell still
        #expect(h.run(seconds: 1) { h.snapshot.isStill && h.snapshot.pgcn == 2 })
        let framesAtStill = h.frames.count
        let picture = try #require(h.last)
        #expect(Self.pixel(picture, 600, 400).g > Self.pixel(picture, 600, 400).r)   // teal
        h.run(seconds: 2)
        #expect(h.snapshot.pgcn == 2 && h.snapshot.isStill)
        #expect(h.frames.count == framesAtStill)              // held: no new pictures while still
        // The finite still ends after 3 s and the post command returns to menu 1.
        #expect(h.run(seconds: 2) { h.snapshot.pgcn == 1 })
    }

    @Test func sixButtonChapterMenu() throws {
        let h = try Harness("menu-features.iso")
        h.player.start()
        h.run(seconds: 3) { h.snapshot.isStill }
        h.player.activate()                                   // Chapters -> VTSM chapter menu
        #expect(h.run(seconds: 3) { h.snapshot.domain == .vtsMenu && h.snapshot.isStill })
        #expect(h.snapshot.buttons.count == 6)
        h.player.navigate(.right)                             // 1 -> 4
        #expect(h.snapshot.highlightedButton == 4)
        h.player.navigate(.down)                              // 4 -> 5
        #expect(h.snapshot.highlightedButton == 5)
        h.player.activate()
        #expect(h.snapshot.domain == .title && h.snapshot.chapter == 5 && h.snapshot.cell == 5)
        #expect(h.run(seconds: 1) { h.last?.domain == .title })
    }

    @Test func setupMenuSelectsAudioAndSubtitlesForTheTitle() throws {
        let h = try Harness("menu-features.iso", titleMode: .external)
        h.player.start()
        h.run(seconds: 3) { h.snapshot.isStill }
        h.player.select(button: 2)
        h.player.activate()                                   // Setup -> VTSM audio/subtitle menu
        #expect(h.run(seconds: 3) { h.snapshot.domain == .vtsMenu && h.snapshot.isStill })
        #expect(h.snapshot.buttons.count == 5)
        h.player.select(button: 2); h.player.activate()       // audio = 1
        #expect(h.player.state.sprm[1] == 1)
        h.run(seconds: 3) { h.snapshot.isStill }
        h.player.select(button: 3); h.player.activate()       // subtitle = 64 (stream 0, display on)
        #expect(h.player.state.sprm[2] == 64)
        h.run(seconds: 3) { h.snapshot.isStill }
        h.player.playTitle(1)
        let req = try #require(h.titleRequests.last)
        #expect(req.audioStreamNumber == 1)
        #expect(req.subpictureStreamNumber == 0)
    }

    @Test func titleSubtitleOverlayFollowsSPRM2() throws {
        let h = try Harness("menu-features.iso")
        h.player.start()
        h.run(seconds: 3) { h.snapshot.isStill }
        h.player.select(button: 2); h.player.activate()
        h.run(seconds: 3) { h.snapshot.isStill }
        h.player.select(button: 3); h.player.activate()       // subtitles on
        h.run(seconds: 3) { h.snapshot.isStill }
        h.player.playTitle(1)
        // The subtitle (a white bar at 200-520 x 400-440) shows from 0.5 s to 2.5 s into the title.
        #expect(h.run(seconds: 2) { h.last?.domain == .title && (h.last?.sourcePTS ?? 0) > 1.2 })
        let f = try #require(h.last)
        #expect(Self.isWhite(Self.pixel(f, 360, 420)), "subtitle \(Self.pixel(f, 360, 420))")
        // Subtitles off (SPRM 2 display bit clear): the same moment shows no overlay.
        let off = try Harness("menu-features.iso")
        off.player.start()
        off.run(seconds: 3) { off.snapshot.isStill }
        off.player.playTitle(1)
        #expect(off.run(seconds: 2) { (off.last?.sourcePTS ?? 0) > 1.2 })
        #expect(!Self.isWhite(Self.pixel(try #require(off.last), 360, 420)))
        #expect(off.player.overlay == nil)
    }
}
