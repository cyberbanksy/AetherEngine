import Foundation
import CoreVideo
import Testing
@testable import AetherEngine

/// Engine-level DVD menu sessions: `LoadOptions.dvdStartMode`, the published `dvdMenu` state, input,
/// frames reaching the display layer with the highlight burnt in, and the title hand-off to the normal
/// pipeline and back.
@Suite("DVD menus through the engine API")
@MainActor
struct DVDEngineMenuTests {
    /// Records title requests instead of playing them.
    final class RecordingTitleHost: DVDTitleHost {
        var requests: [DVDTitleRequest] = []
        var stops = 0
        var position = 0.0
        func playTitle(_ request: DVDTitleRequest, reader: IOReader, controller: DVDMenuController) async {
            requests.append(request)
        }
        func stopTitle(controller: DVDMenuController) { stops += 1 }
        func titlePosition(controller: DVDMenuController) -> Double { position }
    }

    private func waitUntil(_ seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private let iso = DVDMenuPlayerTests.fixture("menu-test.iso")

    @Test("Play Disc: first-play -> menu -> arrows -> activate -> title -> back to the menu")
    func menuSessionEndToEnd() async throws {
        let engine = try AetherEngine()
        let host = RecordingTitleHost()
        engine.dvdTitleHostOverride = host
        let probe = try await engine.load(url: iso, options: LoadOptions(dvdStartMode: .menu))
        #expect(probe == nil)
        #expect(engine.state == .playing)
        let controller = try #require(engine.dvdMenuController)
        var presented: [DVDMenuFrame] = []
        controller.onPresent = { presented.append($0) }

        #expect(await waitUntil { engine.dvdMenu?.isStill == true && engine.dvdMenu?.buttons.count == 3 })
        let menu = try #require(engine.dvdMenu)
        #expect(menu.isInMenu && !menu.isPlayingTitle)
        #expect(menu.highlightedButton == 1)
        // Normalized button frames: button 1 is 100...300 x 100...160 on the 720x480 menu.
        let b1 = try #require(menu.buttons.first)
        #expect(abs(b1.frame.minX - 100.0 / 720) < 0.001 && abs(b1.frame.minY - 100.0 / 480) < 0.001)
        #expect(controller.framesPresented > 0)
        let first = try #require(presented.last)
        #expect(DVDMenuPlayerTests.isYellow(DVDMenuPlayerTests.pixel(first, 200, 101)))

        // Arrow down: highlight moves, a fresh picture with the moved highlight reaches the layer.
        engine.dvdNavigate(.down)
        #expect(await waitUntil { engine.dvdMenu?.highlightedButton == 2 })
        #expect(await waitUntil { presented.last.map { DVDMenuPlayerTests.isYellow(DVDMenuPlayerTests.pixel($0, 200, 201)) } ?? false })
        engine.dvdNavigate(.up)
        #expect(await waitUntil { engine.dvdMenu?.highlightedButton == 1 })

        // Activate: the action-colour picture goes out, then the title is handed to the pipeline.
        let before = presented.count
        engine.dvdActivate()
        #expect(await waitUntil { !host.requests.isEmpty })
        #expect(presented.dropFirst(before).contains { DVDMenuPlayerTests.isRed(DVDMenuPlayerTests.pixel($0, 200, 101)) })
        let req = try #require(host.requests.first)
        #expect(req.title == 1 && req.vts == 1 && req.startCell == 1)
        #expect(await waitUntil { engine.dvdMenu?.isPlayingTitle == true })
        #expect(engine.dvdMenu?.isInMenu == false)

        // The pipeline reports the title's end: its post command calls the VMGM menu.
        controller.titleEnded()
        #expect(await waitUntil { engine.dvdMenu?.isInMenu == true && engine.dvdMenu?.isStill == true })
        #expect(host.stops == 1)

        // Touch on button 3 (normalized point inside 100...300 x 300...360): g2 = 7, jump title 2.
        engine.dvdActivate(atNormalizedPoint: CGPoint(x: 200.0 / 720, y: 330.0 / 480))
        #expect(await waitUntil { host.requests.count == 2 })
        #expect(host.requests.last?.title == 2)

        engine.stop()
        #expect(engine.dvdMenu == nil && engine.dvdMenuController == nil)
    }

    @Test("Menu presentation publishes a surface route and supports binding after its first frame",
          arguments: [("menu-test.iso", 4.0 / 3.0), ("menu-features.iso", 16.0 / 9.0)])
    func lateBoundMenuSurface(discName: String, aspect: Double) async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: DVDMenuPlayerTests.fixture(discName), options: LoadOptions(dvdStartMode: .menu))
        let controller = try #require(engine.dvdMenuController)
        #expect(await waitUntil { controller.framesPresented > 0 && engine.dvdMenu?.isStill == true })
        #expect(engine.videoRoute == .software)
        #expect(engine.hasFirstFrameReadyForDisplay)
        #expect(engine.playbackPhase == .playing)
        #expect(engine.softwareDisplaySize.map { abs($0.width / $0.height - aspect) < 0.002 } == true)
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        engine.bind(view: view)
        #expect(controller.displayLayer.superlayer != nil)
        let replacement = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        engine.bind(view: replacement)
        #expect(controller.displayLayer.superlayer != nil)
        engine.unbind(view: replacement)
        #expect(controller.displayLayer.superlayer == nil)
        // Queue callbacks while this actor still owns the session, then tear it down before
        // the main queue delivers them. They must not revive menu state or frame readiness.
        controller.performSync { player in
            player.onSnapshot?(player.snapshot)
            if let frame = player.lastFrame { player.onFrame?(frame) }
        }
        engine.stop()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(engine.dvdMenu == nil)
        #expect(engine.hasFirstFrameReadyForDisplay == false)
        #expect(engine.hasTransportRolled == false)
        #expect(engine.softwareDisplaySize == nil)
        #expect(engine.playbackPhase == .idle)
    }

    @Test("Title plays through the normal engine pipeline and returns to the menu at its end")
    func realPipelineHandOff() async throws {
        let engine = try AetherEngine()
        _ = try await engine.load(url: iso, options: LoadOptions(suppressDisplayCriteria: true, dvdStartMode: .menu))
        #expect(await waitUntil { engine.dvdMenu?.isStill == true })
        engine.dvdActivate()
        #expect(await waitUntil(15) { engine.dvdMenu?.isPlayingTitle == true && engine.state == .playing && engine.selectedDiscTitle != nil && !engine.discChapters.isEmpty },
                "state \(engine.state) duration \(engine.duration) menu \(String(describing: engine.dvdMenu))")
        #expect(engine.dvdMenuController != nil)
        let title = try #require(engine.selectedDiscTitle)
        #expect(abs(title.durationSeconds - 2.001) < 0.0001)
        #expect(abs(engine.duration - title.durationSeconds) < 0.01)
        let chapters = engine.discChapters
        try #require(chapters.count == 2)
        #expect(chapters[0].startSeconds == 0)
        #expect(abs(chapters[1].startSeconds - 1.2002) < 0.0001)
        #expect(abs(chapters[1].durationSeconds - 0.8008) < 0.0001)
        engine.pause()
        #expect(engine.sourceStartSeconds == 0)
        engine.selectChapter(id: 1)
        #expect(await waitUntil { abs(engine.currentTime - chapters[1].startSeconds) < 0.1 })
        engine.play()
        // Title 1 is 2 s; its post command calls the VMGM menu.
        #expect(await waitUntil(20) { engine.dvdMenu?.isInMenu == true && engine.dvdMenu?.isStill == true },
                "state \(engine.state) menu \(String(describing: engine.dvdMenu))")
        #expect(engine.state == .playing)
        #expect(engine.videoRoute == .software)
        #expect(await waitUntil { engine.softwareDisplaySize != nil && engine.playbackPhase == .playing })
        engine.stop()
    }

    @Test("Chapter entry at cell two keeps the full title clock and resume cell")
    func chapterEntryKeepsTitleClock() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: iso, options: LoadOptions(suppressDisplayCriteria: true, dvdStartMode: .menu))
        let controller = try #require(engine.dvdMenuController)
        #expect(await waitUntil { engine.dvdMenu?.isStill == true })
        controller.perform { $0.playTitle(2) }
        #expect(await waitUntil(15) { engine.selectedDiscTitle != nil })
        #expect(engine.selectedDiscTitle?.id == 0)
        engine.dvdMenu(.chapter)
        #expect(await waitUntil { engine.dvdMenu?.isInMenu == true && engine.dvdMenu?.isStill == true })
        engine.dvdActivate(atNormalizedPoint: CGPoint(x: 150.0 / 720, y: 230.0 / 480))
        #expect(await waitUntil(15) {
            engine.dvdMenu?.isPlayingTitle == true && engine.selectedDiscTitle?.chapterCount == 2
                && engine.currentTime >= 1.1
        })
        engine.pause()
        #expect(abs(engine.currentTime - 1.2002) < 0.4)
        await engine.seek(to: 0.5)
        #expect(abs(engine.currentTime - 0.5) < 0.3)
        engine.dvdMenu(.title)
        #expect(await waitUntil { engine.dvdMenu?.isInMenu == true && engine.dvdMenu?.isStill == true })
        #expect(controller.performSync { $0.state.resume?.cell } == 1)
    }

    @Test("Menu key from a playing title suspends it; Resume returns to the reached cell")
    func menuKeyAndResume() async throws {
        let engine = try AetherEngine()
        let host = RecordingTitleHost()
        engine.dvdTitleHostOverride = host
        _ = try await engine.load(url: iso, options: LoadOptions(dvdStartMode: .menu))
        #expect(await waitUntil { engine.dvdMenu?.isStill == true })
        engine.dvdActivate()
        #expect(await waitUntil { engine.dvdMenu?.isPlayingTitle == true })
        host.position = 1.5                                   // the pipeline is in cell 2
        engine.dvdMenu(.title)
        #expect(await waitUntil { engine.dvdMenu?.isInMenu == true && engine.dvdMenu?.isStill == true })
        #expect(host.stops == 1)
        engine.dvdResume()
        #expect(await waitUntil { host.requests.count == 2 })
        #expect(host.requests.last?.startCell == 2)
        engine.stop()
    }

    @Test("Skip to Movie from a running session plays the main title")
    func playMainTitle() async throws {
        let engine = try AetherEngine()
        let host = RecordingTitleHost()
        engine.dvdTitleHostOverride = host
        _ = try await engine.load(url: iso, options: LoadOptions(dvdStartMode: .menu))
        #expect(await waitUntil { engine.dvdMenu?.isStill == true })
        engine.dvdPlayMainTitle()
        #expect(await waitUntil { host.requests.first?.title == 1 })
        engine.stop()
    }

    @Test("The default start mode keeps the main-title path")
    func mainTitleModeUnchanged() {
        #expect(LoadOptions().dvdStartMode == .mainTitle)
        let engine = try? AetherEngine()
        #expect(engine?.dvdMenu == nil)
    }

    @Test("A non-DVD source with .menu falls through to the normal path")
    func nonDiscFallsThrough() async throws {
        let engine = try AetherEngine()
        let notADisc = URL(fileURLWithPath: #filePath)
        engine.state = .paused
        let generation = engine.loadGeneration
        #expect(try await engine.startDVDMenuSessionIfPossible(source: .url(notADisc), options: LoadOptions(dvdStartMode: .menu)) == false)
        #expect(engine.dvdMenuController == nil)
        #expect(engine.state == .paused)
        #expect(engine.loadGeneration == generation)
    }

    @Test("Skip to Movie keeps a DVD navigator and resumes its interrupted title")
    func skipKeepsNavigator() async throws {
        let engine = try AetherEngine()
        let host = RecordingTitleHost()
        engine.dvdTitleHostOverride = host
        _ = try await engine.load(source: .url(DVDMenuPlayerTests.fixture("menu-test.iso")), options: LoadOptions(dvdStartMode: .mainTitle))
        #expect(await waitUntil { engine.dvdMenu?.isPlayingTitle == true })
        host.position = 1.5
        engine.dvdMenu(.title)
        #expect(await waitUntil { engine.dvdMenu?.isInMenu == true && engine.dvdMenu?.isStill == true })
        #expect(host.stops == 1)
        engine.dvdResume()
        #expect(await waitUntil { host.requests.count == 2 })
        #expect(host.requests.last?.startCell == 2)
        engine.stop()
    }

    @Test("Skip to Movie carries the saved position into its first title load")
    func skipKeepsSavedPosition() async throws {
        let engine = try AetherEngine()
        engine.dvdTitleHostOverride = RecordingTitleHost()
        _ = try await engine.load(source: .url(iso), startPosition: 1.5, options: LoadOptions(dvdStartMode: .mainTitle))
        #expect(await waitUntil { engine.dvdMenu?.isPlayingTitle == true })
        #expect(engine.dvdMenuController?.initialTitlePosition == 1.5)
        engine.stop()
    }

    @Test("Audio reload preserves a menu title and its chapter timeline")
    func audioReloadPreservesMenuTitle() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: DVDMenuPlayerTests.fixture("menu-features.iso"),
                                  options: LoadOptions(suppressDisplayCriteria: true, dvdStartMode: .mainTitle))
        try #require(await waitUntil(15) { engine.selectedDiscTitle != nil && engine.state == .playing })
        engine.pause()
        let title = try #require(engine.selectedDiscTitle)
        let chapters = engine.discChapters
        try #require(chapters.isEmpty == false)
        let audio = try #require(engine.audioTracks.first { $0.id != engine.activeAudioTrackIndex })
        let generation = engine.loadGeneration
        engine.selectAudioTrack(index: audio.id)
        try #require(await waitUntil(15) {
            engine.loadGeneration > generation && engine.activeAudioTrackIndex == audio.id && engine.state != .loading
        }, "state \(engine.state), generation \(generation) -> \(engine.loadGeneration), audio \(String(describing: engine.activeAudioTrackIndex)) expected \(audio.id), seekable \(engine.customSourceIsSeekable)")
        #expect(engine.selectedDiscTitle == title)
        #expect(engine.discChapters == chapters)
        #expect(engine.sourceStartSeconds == 0)
        #expect(engine.dvdMenuController != nil)
    }

    @Test("Title stream selection: audio substream n maps to its container stream")
    func audioStreamIndexMapping() throws {
        let disc = try DVDDiscSource(url: DVDMenuPlayerTests.fixture("menu-features.iso"))
        let pgc = try #require(disc.navigation.titleSets[1]?.titlePGCs.first?.pgc)
        let reader = try #require(disc.makeReader(.title(vts: 1), sectorRanges: DVDDiscSource.cellRanges(of: pgc)))
        let a0 = EngineDVDTitleHost.streamIndex(in: reader, audio: 0)
        let a1 = EngineDVDTitleHost.streamIndex(in: reader, audio: 1)
        #expect(a0 != nil && a1 != nil && a0 != a1)
        #expect(EngineDVDTitleHost.streamIndex(in: reader, audio: 5) == nil)
    }
}
