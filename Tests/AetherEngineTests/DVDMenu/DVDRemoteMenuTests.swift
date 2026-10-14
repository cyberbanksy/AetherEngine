import Foundation
import Testing
@testable import AetherEngine

/// Owns a locked request log and a deterministic gate; immutable fixture bytes are shared safely.
/// The protocol only intercepts this suite's fixture host, leaving other URLSession tests alone.
private final class DVDMenuFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let control = Control()
    final class Control: @unchecked Sendable {
        private let condition = NSCondition()
        private var blocked = false
        private var log: [URLRequest] = []
        var requests: [URLRequest] {
            condition.lock(); defer { condition.unlock() }
            return log
        }
        func reset(blocked: Bool = false) {
            condition.lock(); self.blocked = blocked; log = []; condition.unlock()
        }
        func release() {
            condition.lock(); blocked = false; condition.broadcast(); condition.unlock()
        }
        func receive(_ request: URLRequest) {
            condition.lock(); defer { condition.unlock() }
            log.append(request)
            while blocked { condition.wait() }
        }
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "dvd-menu.fixture.example"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.control.receive(request)
        guard let url = request.url,
              request.value(forHTTPHeaderField: "X-DVD-Fixture") == "fixture",
              let data = try? Data(contentsOf: DVDMenuPlayerTests.fixture(url.lastPathComponent)) else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let range = request.value(forHTTPHeaderField: "Range")?.dropFirst(6)
            .split(separator: "-", omittingEmptySubsequences: false) ?? []
        let lower = range.first.flatMap { Int($0) } ?? 0
        let upper = min(range.count > 1 ? Int(range[1]) ?? data.count - 1 : data.count - 1, data.count - 1)
        guard lower >= 0, lower <= upper else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = data.subdata(in: lower..<(upper + 1))
        let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(body.count),
                           "Content-Range": "bytes \(lower)-\(upper)/\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("DVD menus over HTTP", .serialized)
@MainActor
struct DVDRemoteMenuTests {
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DVDMenuFixtureProtocol.self]
        return configuration
    }
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("HTTP range menus preserve headers, present stills and accept input",
          arguments: ["menu-test.iso", "menu-features.iso"])
    func remoteMenu(discName: String) async throws {
        DVDMenuFixtureProtocol.control.reset()
        let engine = try AetherEngine()
        defer { engine.stop() }
        let host = DVDEngineMenuTests.RecordingTitleHost()
        engine.dvdTitleHostOverride = host
        let url = try #require(URL(string: "https://dvd-menu.fixture.example/\(discName)"))
        #expect(try await engine.startDVDMenuSessionIfPossible(source: .url(url),
            options: LoadOptions(httpHeaders: ["X-DVD-Fixture": "fixture"], dvdStartMode: .menu),
            httpSessionConfiguration: configuration()))
        #expect(await waitUntil { engine.dvdMenu?.isStill == true && engine.playbackPhase == .playing })
        let menu = try #require(engine.dvdMenu)
        #expect(menu.isInMenu)
        #expect(engine.hasFirstFrameReadyForDisplay)
        engine.dvdNavigate(.down)
        #expect(await waitUntil { engine.dvdMenu?.highlightedButton == 2 })
        let first = try #require(menu.buttons.first)
        engine.dvdHover(atNormalizedPoint: CGPoint(x: first.frame.midX, y: first.frame.midY))
        #expect(await waitUntil { engine.dvdMenu?.highlightedButton == first.id })
        engine.dvdPlayMainTitle()
        #expect(await waitUntil { host.requests.first?.title == 1 })
        let requests = DVDMenuFixtureProtocol.control.requests
        #expect(requests.isEmpty == false)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-DVD-Fixture") == "fixture" })
    }

    @Test("A remote menu title plays through the normal pipeline and returns to its menu")
    func remoteTitlePipeline() async throws {
        DVDMenuFixtureProtocol.control.reset()
        let engine = try AetherEngine()
        defer { engine.stop() }
        #expect(try await engine.startDVDMenuSessionIfPossible(
            source: .url(URL(string: "https://dvd-menu.fixture.example/menu-test.iso")!),
            options: LoadOptions(suppressDisplayCriteria: true,
                                 httpHeaders: ["X-DVD-Fixture": "fixture"], dvdStartMode: .menu),
            httpSessionConfiguration: configuration()))
        #expect(await waitUntil { engine.dvdMenu?.isStill == true })
        engine.dvdActivate()
        #expect(await waitUntil {
            engine.dvdMenu?.isPlayingTitle == true && engine.state == .playing && engine.duration > 1
        })
        #expect(await waitUntil {
            engine.dvdMenu?.isInMenu == true && engine.dvdMenu?.isStill == true
                && engine.playbackPhase == .playing
        })
        #expect(DVDMenuFixtureProtocol.control.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-DVD-Fixture") == "fixture"
        })
    }

    @Test("Preparing a remote menu cannot revive a stopped, cancelled or superseded load",
          arguments: ["stop", "cancel", "supersede"])
    func invalidatedPreparation(action: String) async throws {
        DVDMenuFixtureProtocol.control.reset(blocked: true)
        defer {
            DVDMenuFixtureProtocol.control.release()
        }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let task = Task {
            try await engine.startDVDMenuSessionIfPossible(
                source: .url(URL(string: "https://dvd-menu.fixture.example/menu-test.iso")!),
                options: LoadOptions(httpHeaders: ["X-DVD-Fixture": "fixture"], dvdStartMode: .menu),
                httpSessionConfiguration: configuration())
        }
        #expect(await waitUntil { DVDMenuFixtureProtocol.control.requests.isEmpty == false })
        if action == "cancel" {
            task.cancel()
        } else if action == "supersede" {
            _ = try await engine.load(url: DVDMenuPlayerTests.fixture("menu-features.iso"),
                                      options: LoadOptions(dvdStartMode: .menu))
        } else {
            engine.stop()
        }
        DVDMenuFixtureProtocol.control.release()
        do {
            _ = try await task.value
            Issue.record("The invalidated remote menu load completed")
        } catch {
            #expect(error is CancellationError)
        }
        if action == "supersede" {
            #expect(await waitUntil { engine.dvdMenu?.isInMenu == true && engine.playbackPhase == .playing })
            #expect(engine.softwareDisplaySize.map { abs($0.width / $0.height - 16.0 / 9.0) < 0.002 } == true)
        } else {
            #expect(engine.dvdMenu == nil)
            #expect(engine.playbackPhase == .idle)
        }
    }
}
