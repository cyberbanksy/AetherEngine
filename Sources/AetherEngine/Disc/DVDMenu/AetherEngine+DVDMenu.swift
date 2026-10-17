import Foundation
import AVFoundation
import Combine
import CoreMedia
import AetherLibavformat

// Engine wiring for DVD menus (docs/dvd-menus.md, phase 2). With `LoadOptions.dvdStartMode == .menu` a
// local DVD-Video image runs through `DVDMenuController`: menus are presented by the DVD menu player on
// the engine's view, and titles are handed to the normal `load(source:)` pipeline as a custom MPEG-PS
// source over exactly the title PGC's cells, so title playback is the same code path as Skip to Movie.

/// Plays a title PGC for the menu controller. The engine's implementation loads it through the normal
/// pipeline; tests inject their own.
@MainActor
protocol DVDTitleHost: AnyObject {
    func playTitle(_ request: DVDTitleRequest, reader: IOReader, controller: DVDMenuController) async
    /// Stop the title (the menu is taking the picture back). Must not tear down the menu session.
    func stopTitle(controller: DVDMenuController)
    /// Seconds into the current title request.
    func titlePosition(controller: DVDMenuController) -> Double
}

@MainActor
final class DVDMenuController {
    weak var engine: AetherEngine?
    let player: DVDMenuPlayer
    private let queue = DispatchQueue(label: "aether.dvd-menu", qos: .userInteractive)
    let displayLayer = AVSampleBufferDisplayLayer()
    private var timer: DispatchSourceTimer?
    var titleHost: DVDTitleHost
    private(set) var titleActive = false
    private var stateWatch: AnyCancellable?
    /// A saved position applies only to the first Skip to Movie title load.
    var initialTitlePosition: Double?
    /// Pictures that reached the display layer (diagnostics / tests).
    private(set) var framesPresented = 0
    /// Test hook: called on the main actor with each presented picture.
    var onPresent: ((DVDMenuFrame) -> Void)?

    init(engine: AetherEngine, disc: DVDDiscSource, titleHost: DVDTitleHost? = nil) {
        self.engine = engine
        self.player = DVDMenuPlayer(disc: disc, titleMode: .external)
        self.titleHost = titleHost ?? EngineDVDTitleHost()
        displayLayer.videoGravity = .resizeAspect
        let box = UncheckedBox(self)
        player.onFrame = { @Sendable frame in
            let f = UncheckedBox(frame)
            DispatchQueue.main.async { box.value.present(f.value) }
        }
        player.onSnapshot = { @Sendable snap in
            let s = UncheckedBox(snap)
            DispatchQueue.main.async { box.value.publish(s.value) }
        }
        player.onTitleRequest = { @Sendable req in
            let r = UncheckedBox(req)
            DispatchQueue.main.async { box.value.startTitle(r.value) }
        }
        player.onExit = { @Sendable in DispatchQueue.main.async { box.value.engine?.dvdMenuSessionEnded(error: nil) } }
        player.onFault = { @Sendable reason in DispatchQueue.main.async { box.value.engine?.dvdMenuSessionEnded(error: reason) } }
    }

    func start(skipToMainTitle: Bool) {
        let p = UncheckedBox(player)
        queue.async { p.value.start(skipToMainTitle: skipToMainTitle) }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16))
        let last = UncheckedBox(DispatchTime.now())
        t.setEventHandler { @Sendable in
            // The clock: wall time since the last tick, capped so a stalled queue cannot fast-forward a cell.
            let now = DispatchTime.now()
            let dt = Double(now.uptimeNanoseconds &- last.value.uptimeNanoseconds) / 1e9
            last.value = now
            p.value.advance(by: min(max(dt, 0), 0.1))
        }
        timer = t
        t.resume()
        attachLayer()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        stateWatch = nil
        let p = UncheckedBox(player)
        player.disc.reader.cancel()
        queue.sync { p.value.stop() }
        player.disc.reader.close()
        if titleActive { titleHost.stopTitle(controller: self); titleActive = false }
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, visionOS 1.0, *) {
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    // MARK: Input (main actor -> player queue)

    func perform(_ body: @escaping (DVDMenuPlayer) -> Void) {
        let p = UncheckedBox(player)
        let b = UncheckedBox(body)
        queue.async { b.value(p.value) }
    }

    /// Runs `body` on the player queue and waits (tests / synchronous host calls).
    func performSync<T>(_ body: (DVDMenuPlayer) -> T) -> T {
        let p = UncheckedBox(player)
        return withoutActuallyEscaping(body) { b in
            let box = UncheckedBox(b)
            return queue.sync { box.value(p.value) }
        }
    }

    func menuKey(_ key: DVDMenuKey) {
        if titleActive {
            let seconds = titleHost.titlePosition(controller: self)
            titleHost.stopTitle(controller: self)
            titleActive = false
            menuTookOver()
            perform { $0.titlePosition(seconds: seconds); $0.menu(key.menuType) }
        } else {
            perform { $0.menu(key.menuType) }
        }
    }

    // MARK: Output

    private func attachLayer() {
        engine?.attachDVDMenuLayer(displayLayer)
    }

    private func present(_ frame: DVDMenuFrame) {
        guard engine?.dvdMenuController === self, titleActive == false else { return }
        guard let sb = Self.sampleBuffer(frame.pixelBuffer) else { return }
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, visionOS 1.0, *) {
            displayLayer.sampleBufferRenderer.enqueue(sb)
        }
        // Menus serve the same sample-buffer surface contract as software playback. Hosts may
        // bind their view only after the first frame; publish the actual anamorphic display size.
        if let format = CMSampleBufferGetFormatDescription(sb) {
            engine?.softwareDisplaySize = CMVideoFormatDescriptionGetPresentationDimensions(
                format, usePixelAspectRatio: true, useCleanAperture: true)
        }
        engine?.hasFirstFrameReadyForDisplay = true
        // Menu stills have no transport-status publisher; their presented frame is ready playback.
        engine?.hasTransportRolled = true
        framesPresented += 1
        onPresent?(frame)
    }

    private func publish(_ snap: DVDMenuSnapshot) {
        guard engine?.dvdMenuController === self else { return }
        engine?.dvdMenu = DVDMenuState(snap)
    }

    private func startTitle(_ req: DVDTitleRequest) {
        guard let engine else { return }
        let generation = engine.loadGeneration
        let disc = player.disc
        titleActive = true
        let host = titleHost
        Task { @MainActor in
            // Forking an HTTP disc reader performs a range probe. Keep it off the UI actor.
            let reader = await BlockingWork.detached(priority: .userInitiated) {
                disc.makeReader(.title(vts: req.vts), sectorRanges: req.sectorRanges)
            }.value
            guard let engine = self.engine, engine.dvdMenuController === self,
                  self.titleActive, engine.loadGeneration == generation else {
                reader?.close()
                return
            }
            guard let reader else {
                engine.dvdMenuSessionEnded(error: "title \(req.title) sectors unreadable")
                return
            }
            await host.playTitle(req, reader: reader, controller: self)
        }
    }

    /// The host pipeline finished the title.
    func titleEnded() {
        guard titleActive else { return }
        titleActive = false
        titleHost.stopTitle(controller: self)
        menuTookOver()
        perform { $0.titleDidEnd() }
    }

    /// The pipeline's title session is gone and the menu owns the picture again.
    private func menuTookOver() {
        engine?.playbackBackend = .software
        attachLayer()
        engine?.state = .playing
    }

    static func sampleBuffer(_ pb: CVPixelBuffer) -> CMSampleBuffer? {
        var desc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &desc) == noErr,
              let desc else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: desc,
                                                       sampleTiming: &timing, sampleBufferOut: &sb) == noErr,
              let sb else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}

/// Moves a non-Sendable value across the controller's queue boundary; every value boxed here is
/// confined to one queue at a time by construction.
final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Default title host: the engine's own `load(source:)` with a custom MPEG-PS reader over the PGC's cells.
@MainActor
final class EngineDVDTitleHost: DVDTitleHost {
    private var watch: AnyCancellable?
    private var startedAt: Double = 0

    func playTitle(_ request: DVDTitleRequest, reader: IOReader, controller: DVDMenuController) async {
        guard let engine = controller.engine else { return }
        var options = engine.loadedOptions
        options.dvdStartMode = .mainTitle
        let audioIndex = request.audioStreamNumber.flatMap { Self.streamIndex(in: reader, audio: $0) }
        engine.dvdTitleHandoffInProgress = true
        defer { engine.dvdTitleHandoffInProgress = false }
        do {
            let startPosition = controller.initialTitlePosition
            controller.initialTitlePosition = nil
            _ = try await engine.load(source: .custom(reader, formatHint: "mpeg"), startPosition: startPosition, options: options,
                                      audioSourceStreamIndex: audioIndex.map(Int32.init))
        } catch {
            engine.dvdMenuSessionEnded(error: "title load failed: \(error)")
            return
        }
        if let sp = request.subpictureStreamNumber,
           let track = engine.subtitleTracks.first(where: { Self.isSubpicture(stream: $0.id, number: sp, in: engine) }) {
            engine.selectSubtitleTrack(index: track.id)
        }
        let box = UncheckedBox(controller)
        watch = engine.$state.sink { @Sendable state in
            if state == .ended { DispatchQueue.main.async { box.value.titleEnded() } }
        }
    }

    func stopTitle(controller: DVDMenuController) {
        watch = nil
        guard let engine = controller.engine else { return }
        engine.dvdTitleHandoffInProgress = true
        engine.stop(resetDisplayCriteria: false, finalTeardown: false)
        engine.dvdTitleHandoffInProgress = false
    }

    func titlePosition(controller: DVDMenuController) -> Double {
        controller.engine?.currentTime ?? 0
    }

    /// Container stream index of the PGC audio stream number `n` (AC-3 0x80+n, DTS 0x88+n, LPCM 0xA0+n,
    /// MPEG 0x1C0+n in FFmpeg's MPEG-PS stream ids).
    nonisolated static func streamIndex(in reader: IOReader, audio n: Int) -> Int? {
        guard let probeReader = reader.makeIndependentReader() else { return nil }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        guard (try? demuxer.open(reader: probeReader, formatHint: "mpeg", profile: .stillExtraction)) != nil else { return nil }
        var i: Int32 = 0
        while let st = demuxer.stream(at: i) {
            if let par = st.pointee.codecpar, par.pointee.codec_type == AVMEDIA_TYPE_AUDIO, Int(st.pointee.id) & 0x7 == n {
                return Int(i)
            }
            i += 1
        }
        return nil
    }

    private static func isSubpicture(stream: Int, number: Int, in engine: AetherEngine) -> Bool {
        // FFmpeg numbers MPEG-PS subpicture streams by id 0x20+n; the engine's track ids are stream indices,
        // and the names carry no id, so match by order among the DVD subtitle tracks.
        let subs = engine.subtitleTracks.filter { $0.codec == "dvd_subtitle" }
        guard subs.indices.contains(number) else { return false }
        return subs[number].id == stream
    }
}

// MARK: - Engine API

extension AetherEngine {
    /// Starts a DVD menu session for `source` when it is a DVD-Video image with navigation data.
    /// Returns false (and leaves the load to the normal path) otherwise.
    func startDVDMenuSessionIfPossible(source: MediaSource, options: LoadOptions,
                                      httpSessionConfiguration: URLSessionConfiguration? = nil,
                                      startPosition: Double? = nil) async throws -> Bool {
        if case .url(let url) = source {
            guard url.isFileURL || ((url.scheme == "http" || url.scheme == "https")
                                   && Demuxer.isDiscImageURL(url)) else { return false }
        }
        let generation = loadGeneration
        let headers = options.httpHeaders
        let configuration = httpSessionConfiguration?.copy() as? URLSessionConfiguration
        let preparation = BlockingWork.detached(priority: .userInitiated) { () throws -> DVDDiscSource? in
            try Task.checkCancellation()
            let reader: IOReader?
            switch source {
            case .url(let url):
                reader = url.isFileURL ? FileIOReader(url: url)
                    : HTTPDiscIOReader(url: url, extraHeaders: headers, sessionConfiguration: configuration)
            case .custom(let original, _):
                reader = original.makeIndependentReader()
            }
            guard let reader else { return nil }
            var accepted = false
            defer { if accepted == false { reader.close() } }
            guard DiscReader.looksLikeISO9660(reader), let disc = try? DVDDiscSource(reader: reader),
                  disc.navigation.hasMenus || disc.navigation.vmgi.firstPlayPGC != nil else { return nil }
            try Task.checkCancellation()
            accepted = true
            return disc
        }
        var disc: DVDDiscSource?
        do {
            disc = try await withTaskCancellationHandler {
                try await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            try Task.checkCancellation()
            try checkLoadCurrent(generation)
        } catch {
            disc?.reader.close()
            throw error
        }
        guard let disc else { return false }
        // An unsupported disc or a cancelled probe must leave current playback untouched.
        stop(resetDisplayCriteria: false, finalTeardown: false)
        state = .loading
        loadedOptions = options
        let controller = DVDMenuController(engine: self, disc: disc, titleHost: dvdTitleHostOverride)
        controller.initialTitlePosition = options.dvdStartMode == .mainTitle ? startPosition : nil
        dvdMenuController = controller
        playbackBackend = .software
        state = .playing
        controller.start(skipToMainTitle: options.dvdStartMode == .mainTitle)
        return true
    }

    func tearDownDVDMenuSession() {
        dvdMenuController?.stop()
        dvdMenuController = nil
        dvdMenu = nil
    }

    func dvdMenuSessionEnded(error: String?) {
        tearDownDVDMenuSession()
        if let error {
            EngineLog.emit("[DVD] menu session ended: \(error)", category: .engine)
            publishError(.dvdNavigationFailed, "DVD navigation failed: \(error)")
        } else {
            state = .ended
        }
    }

    func attachDVDMenuLayer(_ layer: CALayer) {
        boundView?.attach(layer)
    }

    /// Moves the highlight in the DVD menu on screen (remote arrows, keyboard).
    public func dvdNavigate(_ direction: DVDMenuDirection) {
        dvdMenuController?.perform { $0.navigate(direction.direction) }
    }

    /// Activates the highlighted DVD menu button (remote select / OK / Enter).
    public func dvdActivate() {
        dvdMenuController?.perform { $0.activate() }
    }

    /// Touch / click: activates the DVD menu button under `point`, given in the menu picture's
    /// normalized space (0...1, top-left origin; map from the on-screen video rect).
    public func dvdActivate(atNormalizedPoint point: CGPoint) {
        dvdMenuController?.perform { p in
            let size = p.snapshot.menuSize
            p.activate(atX: Int(point.x * Double(size.width)), y: Int(point.y * Double(size.height)))
        }
    }

    /// Pointer hover: highlights the DVD menu button under `point` (normalized like `dvdActivate(atNormalizedPoint:)`).
    public func dvdHover(atNormalizedPoint point: CGPoint) {
        dvdMenuController?.perform { p in
            let size = p.snapshot.menuSize
            p.hover(atX: Int(point.x * Double(size.width)), y: Int(point.y * Double(size.height)))
        }
    }

    /// Remote menu keys. From a playing title this suspends it (Resume returns there) and shows the menu.
    public func dvdMenu(_ key: DVDMenuKey) {
        dvdMenuController?.menuKey(key)
    }

    /// Resume key: back into the title a menu call interrupted.
    public func dvdResume() {
        dvdMenuController?.perform { $0.resume() }
    }

    /// Skip to Movie from inside a running disc session: plays the main title.
    public func dvdPlayMainTitle() {
        dvdMenuController?.perform { p in
            if let main = p.disc.navigation.mainTitle { p.playTitle(main) }
        }
    }
}
