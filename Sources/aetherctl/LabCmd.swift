import Foundation
import Combine
import CoreMedia
import CoreVideo
import AVFoundation
import QuartzCore
import AetherEngine

// MARK: - lab: one scoreboard measurement per source (engine lab)
//
// `aetherctl lab <url> --out result.json` runs the measurement the engine lab's
// scoreboard is built from (docs/engine-lab.md): open, probe, route, time to first
// frame, a steady play window, three seeks with seek-to-frame latency and the
// continuity of the picture after each landing, A/V and clock drift, dropped frames
// and the memory peak. One process per source on purpose: a crash or a wedge costs
// that row, not the run, and the memory peak is the session's own.
//
// Nothing here binds a render surface. On the native routes (loopback / remote
// bypass) an AVPlayerItemVideoOutput is attached to the engine's item and polled
// at 250 Hz, which is what makes AVPlayer decode and present headless and gives
// every presented frame (item PTS, wall time, mean luma). On the software route the
// engine's observer records enqueue times separately. Timebase polling estimates
// when queued frames become due and detects starvation; it does not observe pixels.
//
// URLs are never echoed into the result or the log: a debrid or tokenised origin
// must not leak into a scoreboard someone pastes into an issue.

struct LabConfig {
    var url: URL
    var playSeconds: Double = 6
    var openTimeout: Double = 45
    var firstFrameTimeout: Double = 20
    var seekTimeout: Double = 12
    var postSeekWindow: Double = 3
    var forceSoftware = false
    var nativeRemoteHLS = false
    var isLive = false
    var noSeeks = false
    var outPath: String?
    var verbose = false
}

/// One native output, software enqueue, or software due-presentation estimate.
struct LabFrame {
    let wall: Double        // CACurrentMediaTime()
    let pts: Double         // item time (native) or source PTS (software)
    let generation: UInt64  // software decode generation; 0 on native
    let luma: Double?       // mean luma 0..1 on native 8-bit output, nil otherwise
}

final class LabFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [LabFrame] = []

    func append(_ frame: LabFrame) {
        lock.lock(); frames.append(frame); lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    var last: LabFrame? { lock.lock(); defer { lock.unlock() }; return frames.last }
    var first: LabFrame? { lock.lock(); defer { lock.unlock() }; return frames.first }

    func slice(from index: Int) -> [LabFrame] {
        lock.lock(); defer { lock.unlock() }
        guard index < frames.count else { return [] }
        return Array(frames[max(0, index)...])
    }

    func between(_ start: Double, _ end: Double) -> [LabFrame] {
        lock.lock(); defer { lock.unlock() }
        return frames.filter { $0.wall >= start && $0.wall <= end }
    }
}

/// Polls an AVPlayerItemVideoOutput on its own queue. Re-attached whenever the engine
/// swaps its AVPlayerItem (a reload or a reroute builds a new one).
final class LabNativeFramePoller: @unchecked Sendable {
    private let lock = NSLock()
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private let queue = DispatchQueue(label: "aetherctl.lab.poll", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    let recorder: LabFrameRecorder

    init(recorder: LabFrameRecorder) { self.recorder = recorder }

    @MainActor
    func attach(to newItem: AVPlayerItem?) {
        lock.lock()
        let old = output
        let oldItem = item
        lock.unlock()
        if let old, let oldItem { oldItem.remove(old) }
        guard let newItem else {
            lock.lock(); output = nil; item = nil; lock.unlock()
            return
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        newItem.add(out)
        lock.lock(); output = out; item = newItem; lock.unlock()
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    func stop() { timer?.cancel(); timer = nil }

    private func poll() {
        lock.lock(); let out = output; lock.unlock()
        guard let out else { return }
        let now = CACurrentMediaTime()
        let itemTime = out.itemTime(forHostTime: now)
        guard itemTime.isValid, out.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        var display = CMTime.invalid
        guard let pb = out.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &display) else { return }
        let pts = display.isValid ? display.seconds : itemTime.seconds
        recorder.append(LabFrame(wall: now, pts: pts, generation: 0, luma: labMeanLuma(pb)))
    }
}

/// Mean luma of an 8-bit video-range bi-planar buffer, sampled on a 16x9 grid, 0 (black) ... 1.
func labMeanLuma(_ pb: CVPixelBuffer) -> Double? {
    guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
          CVPixelBufferGetPlaneCount(pb) >= 1 else { return nil }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
    let w = CVPixelBufferGetWidthOfPlane(pb, 0)
    let h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    guard w > 32, h > 18 else { return nil }
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    var sum = 0.0
    var n = 0.0
    for gy in 0..<9 {
        let y = (h * (2 * gy + 1)) / 18
        for gx in 0..<16 {
            let x = (w * (2 * gx + 1)) / 32
            sum += Double(bytes[y * stride + x])
            n += 1
        }
    }
    return max(0, min(1, (sum / n - 16) / 219))
}

/// Software frames are often enqueued seconds ahead in batches. An enqueue gap is not
/// a presentation freeze. Consume them only once their PTS is due on a running timebase.
/// This is a headless estimate, not evidence that a pixel reached a display layer.
struct LabPresentationQueue {
    private var pending: [LabFrame] = []
    private var generation: UInt64?

    mutating func consume(_ enqueued: [LabFrame], at time: Double, rate: Double, wall: Double) -> [LabFrame] {
        for frame in enqueued where frame.pts.isFinite {
            if let generation, frame.generation < generation { continue }
            if generation != frame.generation {
                generation = frame.generation
                pending.removeAll(keepingCapacity: true)
            }
            pending.append(frame)
        }
        guard time.isFinite, rate > 0 else { return [] }
        pending.sort { $0.pts < $1.pts }
        let due = pending.prefix { $0.pts <= time }
        let output = due.map { LabFrame(wall: wall, pts: $0.pts, generation: $0.generation, luma: nil) }
        pending.removeFirst(output.count)
        return output
    }
}

/// Software route only: derives due presentation from the clock while separately
/// watching the newest enqueue PTS for starvation. Neither proves pixel-layer output.
final class LabTimebaseWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var timebase: CMTimebase?
    private let queue = DispatchQueue(label: "aetherctl.lab.tb", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let enqueued: LabFrameRecorder
    private let presented: LabFrameRecorder
    private var enqueueIndex = 0
    private var presentationQueue = LabPresentationQueue()
    private var starvedMs: Double = 0
    private var starveStart: Double?
    private var starveEvents = 0
    private var maxStarveMs: Double = 0
    private var frameInterval: Double = 1.0 / 24
    var interval: Double {
        get { lock.lock(); defer { lock.unlock() }; return frameInterval }
        set { lock.lock(); frameInterval = newValue; lock.unlock() }
    }

    init(enqueued: LabFrameRecorder, presented: LabFrameRecorder) {
        self.enqueued = enqueued
        self.presented = presented
    }

    func set(_ tb: CMTimebase?) { lock.lock(); timebase = tb; lock.unlock() }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() { timer?.cancel(); timer = nil }

    func snapshot() -> (events: Int, totalMs: Double, maxMs: Double) {
        lock.lock(); defer { lock.unlock() }
        let ongoing = starveStart.map { (CACurrentMediaTime() - $0) * 1000 } ?? 0
        return (starveEvents, starvedMs + ongoing, max(maxStarveMs, ongoing))
    }

    func reset() {
        lock.lock(); starvedMs = 0; starveEvents = 0; maxStarveMs = 0; starveStart = nil; lock.unlock()
    }

    private func tick() {
        lock.lock(); defer { lock.unlock() }
        guard let tb = timebase else { return }
        let rate = CMTimebaseGetRate(tb)
        let now = CACurrentMediaTime()
        let tbTime = CMTimebaseGetTime(tb).seconds
        let fresh = enqueued.slice(from: enqueueIndex)
        enqueueIndex += fresh.count
        for frame in presentationQueue.consume(fresh, at: tbTime, rate: rate, wall: now) {
            presented.append(frame)
        }
        guard rate > 0, let last = enqueued.last else {
            finishStarvation(at: now)
            return
        }
        if tbTime > last.pts + 2 * frameInterval {
            if starveStart == nil { starveStart = now; starveEvents += 1 }
        } else {
            finishStarvation(at: now)
        }
    }

    // Called with lock held.
    private func finishStarvation(at now: Double) {
        guard let start = starveStart else { return }
        let ms = (now - start) * 1000
        starvedMs += ms
        maxStarveMs = max(maxStarveMs, ms)
        starveStart = nil
    }
}

final class LabLogRing: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private(set) var errorLines = 0
    let verbose: Bool
    init(verbose: Bool) { self.verbose = verbose }

    func add(_ raw: String) {
        let line = labRedact(raw)
        lock.lock()
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        let l = line.lowercased()
        if l.contains("error") || l.contains("failed") { errorLines += 1 }
        lock.unlock()
        if verbose { print(line) }
    }

    func tail(_ n: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(lines.suffix(n))
    }
}

/// Strips anything URL-shaped (and query strings that could carry tokens) from engine text.
func labRedact(_ text: String) -> String {
    guard let re = try? NSRegularExpression(pattern: #"(https?|file|smb)://[^\s"'<>)\]]+"#) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return re.stringByReplacingMatches(in: text, range: range, withTemplate: "<url>")
}

func labMemoryMB() -> Double { Double(physFootprintBytes()) / 1_048_576 }

func labNow() -> Double { CACurrentMediaTime() }

func labMedian(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s[s.count / 2]
}

/// Frame-sequence analysis shared by the play window and every post-seek window.
struct LabContinuity {
    var frames = 0
    var presentedFps: Double?
    var ptsGaps = 0             // a PTS jump > 2.5x the frame interval (content skipped)
    var missingFrames = 0       // frames implied missing by those jumps (dropped / never shown)
    var freezes = 0             // wall-clock hole > max(250 ms, 4x interval) between frames
    var maxFrameGapMs = 0.0
    var backwardsPts = 0        // a presented PTS earlier than its predecessor (same generation)
    var blackFrames = 0         // luma < 0.06 while the window's median is > 0.15

    static func analyze(_ frames: [LabFrame], interval: Double) -> LabContinuity {
        var c = LabContinuity()
        c.frames = frames.count
        guard frames.count >= 2 else { return c }
        let span = frames.last!.wall - frames.first!.wall
        if span > 0 { c.presentedFps = Double(frames.count - 1) / span }
        let freezeThreshold = max(0.25, 4 * interval)
        let lumas = frames.compactMap(\.luma)
        let medianLuma = labMedian(lumas) ?? 0
        for i in 1..<frames.count {
            let a = frames[i - 1], b = frames[i]
            let wallGap = b.wall - a.wall
            c.maxFrameGapMs = max(c.maxFrameGapMs, wallGap * 1000)
            if wallGap > freezeThreshold { c.freezes += 1 }
            guard a.generation == b.generation else { continue }
            let dp = b.pts - a.pts
            if dp < -0.001 { c.backwardsPts += 1; continue }
            if dp > 2.5 * interval && dp < 5 {   // >5 s is a seek, not a gap
                c.ptsGaps += 1
                c.missingFrames += max(0, Int((dp / interval).rounded()) - 1)
            }
        }
        if medianLuma > 0.15 {
            c.blackFrames = lumas.filter { $0 < 0.06 }.count
        }
        return c
    }

    var json: [String: Any] {
        var d: [String: Any] = [
            "frames": frames, "ptsGaps": ptsGaps, "missingFrames": missingFrames, "freezes": freezes,
            "maxFrameGapMs": labRound(maxFrameGapMs), "backwardsPts": backwardsPts, "blackFrames": blackFrames,
        ]
        if let presentedFps { d["presentedFps"] = labRound(presentedFps) }
        return d
    }
}

func labRound(_ v: Double, _ places: Double = 1000) -> Double {
    guard v.isFinite else { return -1 }
    return (v * places).rounded() / places
}

/// Seek landing driver: issues the seek with a timeout and returns whether it completed.
@MainActor
func labSeek(_ engine: AetherEngine, to target: Double, timeout: Double) async -> Bool {
    let done = UncheckedBox<Bool>(false)
    let task = Task { @MainActor in
        await engine.seek(to: target)
        done.value = true
    }
    let deadline = labNow() + timeout
    while !done.value && labNow() < deadline {
        if labTerminalState(engine) != nil { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    if !done.value { task.cancel() }
    return done.value
}

@MainActor
private func labTerminalState(_ engine: AetherEngine) -> String? {
    if engine.state == .ended { return "ended" }
    if case .error = engine.state { return "error" }
    return nil
}

/// Deterministic CLI regression checks, independent of decoders and wall-clock sleeps.
/// Invoke `aetherctl lab --self-test` in the same executable used for measurements.
private func labSelfTest() -> Int32 {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }
    var queue = LabPresentationQueue()
    let batch = (0..<49).map { LabFrame(wall: 100, pts: Double($0) / 24, generation: 1, luma: nil) }
    var presented = queue.consume(batch, at: 0, rate: 1, wall: 100)
    for tick in 1...200 {
        presented += queue.consume([], at: Double(tick) / 100, rate: 1, wall: 100 + Double(tick) / 100)
    }
    let continuity = LabContinuity.analyze(presented, interval: 1.0 / 24)
    check(presented.count == 49 && continuity.freezes == 0 && continuity.maxFrameGapMs < 51,
          "batched enqueue must present progressively without a false freeze")
    let future = LabFrame(wall: 102, pts: 10, generation: 1, luma: nil)
    check(queue.consume([future], at: 10, rate: 0, wall: 102).isEmpty,
          "stopped timebase must not count queued frames as presented")
    let nextGeneration = LabFrame(wall: 103, pts: 3, generation: 2, luma: nil)
    let landing = queue.consume([nextGeneration], at: 3, rate: 1, wall: 103)
    check(landing.count == 1 && landing.first?.generation == 2,
          "new seek generation must discard old queued presentation")
    check(queue.consume([], at: 11, rate: 1, wall: 104).isEmpty,
          "discarded generation must never reappear after seek")
    var stalled = LabPresentationQueue()
    let start = stalled.consume([LabFrame(wall: 0, pts: 0, generation: 1, luma: nil)], at: 0, rate: 1, wall: 0)
    let end = stalled.consume([LabFrame(wall: 1, pts: 1, generation: 1, luma: nil)], at: 1, rate: 1, wall: 1)
    check(LabContinuity.analyze(start + end, interval: 1.0 / 24).freezes == 1,
          "real absence of due frames must preserve the freeze threshold")
    if failures.isEmpty {
        print("LAB self-test: 5 checks passed")
        return 0
    }
    failures.forEach { print("LAB self-test FAILED: \($0)") }
    return 1
}

func runLab(arguments: [String]) -> Int32 {
    var rest = arguments
    if takeFlag("--self-test", from: &rest) { return labSelfTest() }
    var cfg = LabConfig(url: URL(fileURLWithPath: "/"))
    cfg.playSeconds = takeDoubleFlag("--seconds", from: &rest) ?? cfg.playSeconds
    cfg.openTimeout = takeDoubleFlag("--open-timeout", from: &rest) ?? cfg.openTimeout
    cfg.firstFrameTimeout = takeDoubleFlag("--first-frame-timeout", from: &rest) ?? cfg.firstFrameTimeout
    cfg.seekTimeout = takeDoubleFlag("--seek-timeout", from: &rest) ?? cfg.seekTimeout
    cfg.forceSoftware = takeFlag("--sw", from: &rest)
    cfg.nativeRemoteHLS = takeFlag("--native-hls", from: &rest)
    cfg.isLive = takeFlag("--live", from: &rest)
    cfg.noSeeks = takeFlag("--no-seeks", from: &rest)
    cfg.verbose = takeFlag("--verbose", from: &rest)
    cfg.outPath = takeStringFlag("--out", from: &rest)
    rejectStrayFlags(rest, subcommand: "lab")
    guard let raw = rest.first else {
        print("ERROR: lab requires a <url> argument")
        return 64
    }
    if let parsed = URL(string: raw), parsed.scheme != nil {
        cfg.url = parsed
    } else {
        cfg.url = URL(fileURLWithPath: raw)
    }
    let config = cfg
    let box = UncheckedBox<[String: Any]>([:])
    Task { @MainActor in
        box.value = await labMeasure(config)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    let result = box.value
    guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else {
        print("ERROR: result not serialisable")
        return 1
    }
    if let out = config.outPath {
        do {
            try data.write(to: URL(fileURLWithPath: out))
        } catch {
            print("ERROR: cannot write \(out): \(error.localizedDescription)")
            return 1
        }
        print("LAB result written: \(out)")
    } else {
        print(String(decoding: data, as: UTF8.self))
    }
    return 0
}

@MainActor
private func labMeasure(_ cfg: LabConfig) async -> [String: Any] {
    var result: [String: Any] = ["schema": 1, "harness": "aetherctl-lab"]
    let log = LabLogRing(verbose: cfg.verbose)
    EngineLog.handler = { @Sendable line in log.add(line) }

    // Memory peak over the whole session, sampled at 20 Hz off the main actor.
    let memPeak = UncheckedBox<Double>(labMemoryMB())
    let memLock = NSLock()
    let memTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "aetherctl.lab.mem"))
    memTimer.schedule(deadline: .now(), repeating: .milliseconds(50))
    memTimer.setEventHandler { @Sendable in
        let mb = labMemoryMB()
        memLock.lock(); if mb > memPeak.value { memPeak.value = mb }; memLock.unlock()
    }
    memTimer.resume()
    let memBaseline = labMemoryMB()
    defer { memTimer.cancel() }

    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        result["open"] = ["ok": false, "errorKind": "engineInit", "message": labRedact(error.localizedDescription)]
        return result
    }
    engine.volume = 0   // headless runs must never make a sound on the Mac

    let recorder = LabFrameRecorder()
    let poller = LabNativeFramePoller(recorder: recorder)
    let enqueued = LabFrameRecorder()
    let tbWatcher = LabTimebaseWatcher(enqueued: enqueued, presented: recorder)
    engine.setSoftwareVideoFrameTimeObserver { @Sendable frame in
        enqueued.append(LabFrame(wall: labNow(), pts: frame.presentation.seconds,
                                 generation: frame.generation, luma: nil))
    }

    var cancellables = Set<AnyCancellable>()
    let t0 = labNow()
    var engineFirstFrameAt: Double?
    var stateErrors: [String] = []
    var stateTrail: [String] = []
    engine.$hasFirstFrameReadyForDisplay.sink { ready in
        if ready, engineFirstFrameAt == nil { engineFirstFrameAt = labNow() }
    }.store(in: &cancellables)
    engine.$state.removeDuplicates().sink { state in
        let label: String
        if case .error(let msg) = state {
            label = "error"
            stateErrors.append(labRedact(msg))
        } else {
            label = String(describing: state)
        }
        if stateTrail.last != label { stateTrail.append(label) }
    }.store(in: &cancellables)
    engine.$currentAVPlayerItem.sink { item in
        poller.attach(to: item)
    }.store(in: &cancellables)
    var seekEventLog: [(wall: Double, event: SeekEvent)] = []
    engine.seekEvents.sink { event in seekEventLog.append((labNow(), event)) }.store(in: &cancellables)
    poller.start()

    // MARK: open
    var options = LoadOptions(suppressDisplayCriteria: true)
    options.preferredDecodePath = cfg.forceSoftware ? .software : .automatic
    options.nativeRemoteHLS = cfg.nativeRemoteHLS
    options.isLive = cfg.isLive
    let loadDone = UncheckedBox<Bool>(false)
    let loadError = UncheckedBox<Error?>(nil)
    let loadTask = Task { @MainActor in
        do {
            _ = try await engine.load(url: cfg.url, options: options)
        } catch {
            loadError.value = error
        }
        loadDone.value = true
    }
    let openDeadline = t0 + cfg.openTimeout
    while !loadDone.value && labNow() < openDeadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    let openSeconds = labNow() - t0
    var open: [String: Any] = ["seconds": labRound(openSeconds)]
    if !loadDone.value {
        loadTask.cancel()
        open["ok"] = false
        open["errorKind"] = "timeout"
        open["message"] = "load did not return within \(Int(cfg.openTimeout)) s"
    } else if let error = loadError.value {
        open["ok"] = false
        open["errorKind"] = engine.errorInfo?.kind.rawValue ?? "\(type(of: error))"
        open["message"] = labRedact(engine.errorInfo?.message ?? error.localizedDescription)
    } else if case .error(let msg) = engine.state {
        open["ok"] = false
        open["errorKind"] = engine.errorInfo?.kind.rawValue ?? "stateError"
        open["message"] = labRedact(msg)
    } else {
        open["ok"] = true
    }
    result["open"] = open
    let opened = (open["ok"] as? Bool) == true

    // MARK: probe + route
    var probe: [String: Any] = [
        "container": (engine.sourceContainerFormat as Any?) ?? NSNull(),
        "videoCodec": (engine.sourceVideoCodecName as Any?) ?? NSNull(),
        "width": Int(engine.sourceVideoWidth), "height": Int(engine.sourceVideoHeight),
        "fps": (engine.sourceVideoFrameRate.map { labRound($0) } as Any?) ?? NSNull(),
        "dvProfile": (engine.sourceDVProfile as Any?) ?? NSNull(),
        "videoFormat": String(describing: engine.sourceVideoFormat),
        "outputVideoFormat": String(describing: engine.videoFormat),
        "duration": labRound(engine.duration),
        "isLive": engine.isLive,
    ]
    probe["audio"] = engine.audioTracks.map { t -> [String: Any] in
        ["codec": t.codec, "channels": t.channels, "language": (t.language as Any?) ?? NSNull(), "default": t.isDefault]
    }
    probe["subtitles"] = engine.subtitleTracks.map { t -> [String: Any] in
        ["codec": t.codec, "language": (t.language as Any?) ?? NSNull(), "forced": t.isForced, "external": t.isExternal]
    }
    result["probe"] = probe
    result["route"] = [
        "videoRoute": engine.videoRoute.rawValue,
        "backend": engine.playbackBackend.rawValue,
        "videoDecoder": (engine.activeVideoDecoder as Any?) ?? NSNull(),
        "audioDecoder": (engine.activeAudioDecoder as Any?) ?? NSNull(),
        "audioDelivery": engine.audioDelivery.rawValue,
    ]

    guard opened else {
        result["memory"] = ["peakMB": labRound(memPeak.value, 10), "baselineMB": labRound(memBaseline, 10)]
        result["stateTrail"] = stateTrail
        result["logTail"] = log.tail(25)
        engine.stop()
        poller.stop()
        return result
    }

    let isVideo = engine.videoRoute != .audio && engine.videoRoute != .none
    if engine.videoRoute == .software { result["softwarePresentation"] = "timebaseDueEstimate" }
    result["frameEvidence"] = engine.videoRoute == .software
        ? "software-timebase-due-estimate (headless; no pixel-layer evidence)"
        : "AVPlayerItemVideoOutput"
    if engine.videoRoute == .software {
        tbWatcher.interval = engine.sourceVideoFrameRate.flatMap { $0 > 1 ? 1 / $0 : nil } ?? (1.0 / 24)
        tbWatcher.set(engine.softwarePresentationTimebase)
        tbWatcher.start()
    }

    // MARK: first frame
    var firstFrame: [String: Any] = [:]
    if isVideo {
        let deadline = labNow() + cfg.firstFrameTimeout
        while recorder.count == 0 && labNow() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if let f = recorder.first {
            firstFrame["ok"] = true
            firstFrame["seconds"] = labRound(f.wall - t0)
        } else {
            firstFrame["ok"] = false
        }
        if let e = engineFirstFrameAt { firstFrame["engineReadySeconds"] = labRound(e - t0) }
    } else {
        firstFrame["ok"] = NSNull()
        firstFrame["note"] = "no video route"
    }
    result["firstFrame"] = firstFrame

    // MARK: play window
    let windowStart = labNow()
    let clockStart = engine.currentTime
    var samples: [(wall: Double, clock: Double)] = []
    var maxAVGap = 0.0
    var avGapSeen = false
    var stallSamples = 0
    let ticks = max(1, Int(cfg.playSeconds * 10))
    for _ in 0..<ticks {
        try? await Task.sleep(nanoseconds: 100_000_000)
        samples.append((labNow(), engine.currentTime))
        if engine.isBuffering { stallSamples += 1 }
        if let g = engine.liveTelemetry?.avSyncGapMs { avGapSeen = true; maxAVGap = max(maxAVGap, abs(g)) }
        if engine.videoRoute == .software { tbWatcher.set(engine.softwarePresentationTimebase) }
        if case .error = engine.state { break }
        if engine.state == .ended { break }
    }
    let windowEnd = labNow()
    let clockEnd = engine.currentTime
    let windowFrames = recorder.between(windowStart, windowEnd)
    var deltas: [Double] = []
    for i in stride(from: 1, to: windowFrames.count, by: 1) where windowFrames[i].generation == windowFrames[i - 1].generation {
        let d = windowFrames[i].pts - windowFrames[i - 1].pts
        if d > 0.001 && d < 0.5 { deltas.append(d) }
    }
    let containerInterval = engine.sourceVideoFrameRate.flatMap { $0 > 1 ? 1 / $0 : nil }
    let interval = labMedian(deltas) ?? containerInterval ?? (1.0 / 24)
    tbWatcher.interval = interval
    let playCont = LabContinuity.analyze(windowFrames, interval: interval)

    // Drift: the clock against wall time over the steady part of the window (first second
    // excluded), and the presented picture against the clock over the same span.
    var drift: [String: Any] = [:]
    let steady = samples.filter { $0.wall >= windowStart + 1 }
    if let a = steady.first, let b = steady.last, b.wall - a.wall > 1 {
        let rate = (b.clock - a.clock) / (b.wall - a.wall)
        drift["clockRate"] = labRound(rate)
        let fa = recorder.between(a.wall - 0.1, a.wall).last
        let fb = recorder.between(b.wall - 0.1, b.wall).last
        if let fa, let fb, fa.generation == fb.generation {
            let videoAdvance = fb.pts - fa.pts
            let clockAdvance = b.clock - a.clock
            drift["videoVsClockMs"] = labRound((videoAdvance - clockAdvance) * 1000, 10)
        }
    }
    if avGapSeen { drift["engineAVGapMaxMs"] = labRound(maxAVGap, 10) }
    let telemetry = engine.liveTelemetry
    var play: [String: Any] = [
        "seconds": labRound(windowEnd - windowStart),
        "clockAdvance": labRound(clockEnd - clockStart),
        "bufferingSamples": stallSamples,
        "frameInterval": labRound(interval, 100000),
        "continuity": playCont.json,
        "drift": drift,
    ]
    if engine.state == .ended { play["endedAtClock"] = labRound(engine.currentTime) }
    if let dropped = telemetry?.droppedFrameCount { play["engineDroppedFrames"] = dropped }
    if let fps = telemetry?.observedFps { play["engineObservedFps"] = labRound(fps) }
    if engine.videoRoute == .software {
        play["enqueueContinuity"] = LabContinuity.analyze(enqueued.between(windowStart, windowEnd), interval: interval).json
        let s = tbWatcher.snapshot()
        play["displayStarvation"] = ["events": s.events, "totalMs": labRound(s.totalMs, 10), "maxMs": labRound(s.maxMs, 10)]
    }
    result["play"] = play

    // MARK: seeks (50 %, 90 %, 10 %: each lands far from the previous playhead, so the
    // landing frame is unambiguous even on short sources)
    var seeks: [[String: Any]] = []
    let duration = engine.duration
    let canSeek = !cfg.noSeeks && !engine.isLive && duration > 10 && engine.state != .ended
        && { if case .error = engine.state { return false } else { return true } }()
    if canSeek {
        for fraction in [0.5, 0.9, 0.1] {
            // Never land closer to the end than the post-seek window plus margin: reaching end of
            // media ends the session (by design seek is a no-op on .ended) and the next seek is rejected.
            let target = min(duration * fraction, max(0, duration - cfg.postSeekWindow - 2.5))
            var s: [String: Any] = ["fraction": fraction, "target": labRound(target)]
            if engine.state == .ended || engine.state == .paused { engine.play() }
            let preIndex = recorder.count
            let preLast = recorder.last
            let issued = labNow()
            let completed = await labSeek(engine, to: target, timeout: cfg.seekTimeout)
            let returned = labNow()
            s["returnedMs"] = labRound((returned - issued) * 1000, 10)
            s["completed"] = completed
            // Landing frame: the first frame after the seek that is far from the pre-seek playhead
            // (or, on software, of a newer decode generation), or failing that the first frame that
            // arrived after the seek call returned.
            var landing: LabFrame?
            let landDeadline = returned + cfg.seekTimeout
            while landing == nil && labNow() < landDeadline {
                if engine.videoRoute == .software { tbWatcher.set(engine.softwarePresentationTimebase) }
                for f in recorder.slice(from: preIndex) where f.wall >= issued {
                    let far: Bool
                    if let preLast {
                        far = engine.videoRoute == .software
                            ? f.generation != preLast.generation
                            : abs(f.pts - preLast.pts) > 0.5
                    } else {
                        far = true
                    }
                    if far || f.wall >= returned + 0.05 { landing = f; break }
                }
                if landing == nil {
                    if let terminal = labTerminalState(engine) {
                        s["terminalNoFrame"] = terminal
                        s["terminalNoFrameMs"] = labRound((labNow() - issued) * 1000, 10)
                        break
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            s["landingWaitMs"] = labRound((labNow() - returned) * 1000, 10)
            if let landing {
                s["landed"] = true
                // Starvation is judged from the landing on: the hold while the seek itself is in
                // flight is the seek latency, already measured above.
                if engine.videoRoute == .software { tbWatcher.reset() }
                s["frameLatencyMs"] = labRound((landing.wall - issued) * 1000, 10)
                let clockAtLanding = engine.currentTime
                try? await Task.sleep(nanoseconds: UInt64(cfg.postSeekWindow * 1_000_000_000))
                let after = recorder.between(landing.wall, landing.wall + cfg.postSeekWindow)
                let cont = LabContinuity.analyze(after, interval: interval)
                var cj = cont.json
                // Stutter right at the landing: the hole between the landing frame and the next one.
                if after.count >= 2 { cj["firstFrameHoldMs"] = labRound((after[1].wall - after[0].wall) * 1000, 10) }
                // Black flash: a dark frame in the first 500 ms when the picture settles bright.
                let early = after.filter { $0.wall <= landing.wall + 0.5 }.compactMap(\.luma)
                let late = after.filter { $0.wall > landing.wall + 1.0 }.compactMap(\.luma)
                if let lateMedian = labMedian(late), lateMedian > 0.15 {
                    cj["blackFlash"] = early.contains { $0 < 0.06 }
                }
                if !early.isEmpty {
                    cj["earlyLuma"] = early.prefix(12).map { labRound($0, 100) }
                    cj["lateLumaMedian"] = labMedian(late).map { labRound($0, 100) } ?? -1
                }
                s["continuity"] = cj
                s["clockAdvanceAfter"] = labRound(engine.currentTime - clockAtLanding)
                s["landedClock"] = labRound(clockAtLanding)
                s["landingErrorS"] = labRound(clockAtLanding - target)
                if engine.videoRoute == .software {
                    s["enqueueContinuity"] = LabContinuity.analyze(enqueued.between(landing.wall, landing.wall + cfg.postSeekWindow), interval: interval).json
                    let st = tbWatcher.snapshot()
                    s["displayStarvation"] = ["events": st.events, "totalMs": labRound(st.totalMs, 10), "maxMs": labRound(st.maxMs, 10)]
                }
            } else {
                s["landed"] = false
            }
            if let ev = seekEventLog.last(where: { $0.wall >= issued && $0.event.isTerminal }) {
                s["engineOutcome"] = ev.event.description.components(separatedBy: " ").dropFirst(2).first ?? "?"
                s["engineTerminalMs"] = labRound((ev.wall - issued) * 1000, 10)
            }
            if case .error(let msg) = engine.state {
                s["error"] = labRedact(msg)
                seeks.append(s)
                break
            }
            seeks.append(s)
            if engine.state == .ended { break }
        }
    }
    result["seeks"] = seeks
    if !canSeek { result["seeksSkipped"] = engine.isLive ? "live" : (cfg.noSeeks ? "disabled" : "duration<=10s or ended/error") }

    // Duration (and on some routes the source identity) publishes after load returns: refresh.
    probe["duration"] = labRound(engine.duration)
    if (probe["fps"] as? NSNull) != nil, let fps = engine.sourceVideoFrameRate { probe["fps"] = labRound(fps) }
    result["probe"] = probe
    result["memory"] = ["peakMB": labRound(memPeak.value, 10), "baselineMB": labRound(memBaseline, 10)]
    result["stateTrail"] = stateTrail
    result["stateErrors"] = stateErrors
    result["engineErrorLogLines"] = log.errorLines
    result["logTail"] = log.tail(15)
    result["totalSeconds"] = labRound(labNow() - t0)

    poller.stop()
    tbWatcher.stop()
    engine.stop()
    try? await Task.sleep(nanoseconds: 200_000_000)
    return result
}
