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

    @Test("Title plays through the normal engine pipeline and returns to the menu at its end")
    func realPipelineHandOff() async throws {
        let engine = try AetherEngine()
        _ = try await engine.load(url: iso, options: LoadOptions(suppressDisplayCriteria: true, dvdStartMode: .menu))
        #expect(await waitUntil { engine.dvdMenu?.isStill == true })
        engine.dvdActivate()
        #expect(await waitUntil(15) { engine.dvdMenu?.isPlayingTitle == true && engine.state == .playing && engine.duration > 1 },
                "state \(engine.state) duration \(engine.duration) menu \(String(describing: engine.dvdMenu))")
        #expect(engine.dvdMenuController != nil)
        // Title 1 is 2 s; its post command calls the VMGM menu.
        #expect(await waitUntil(20) { engine.dvdMenu?.isInMenu == true && engine.dvdMenu?.isStill == true },
                "state \(engine.state) menu \(String(describing: engine.dvdMenu))")
        #expect(engine.state == .playing)
        engine.stop()
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
        #expect(engine.startDVDMenuSessionIfPossible(source: .url(notADisc), options: LoadOptions(dvdStartMode: .menu)) == false)
        #expect(engine.dvdMenuController == nil)
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
