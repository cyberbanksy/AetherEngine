import Testing
@testable import AetherEngine

@Suite("Truncated source seeks")
struct TruncatedSourceSeekTests {
    @Test("EOF and failures during reposition remain terminal")
    func terminalStatesSurviveSeek() {
        #expect(AetherEngine.seekMustPreserveTerminalState(.ended))
        #expect(AetherEngine.seekMustPreserveTerminalState(.error("Source exhausted")))
        #expect(AetherEngine.seekMustPreserveTerminalState(.seeking) == false)
        #expect(AetherEngine.seekMustPreserveTerminalState(.playing) == false)
        #expect(AetherEngine.seekMustPreserveTerminalState(.paused) == false)
    }

    @MainActor
    @Test("Source completion clears a pending native scrub without claiming its target rendered")
    func completionRetiresPendingSeek() throws {
        let engine = try AetherEngine()
        engine.state = .playing
        engine.setNativeScrubSeek(inFlight: true, target: 3500)
        #expect(engine.isSeeking)
        let rendered = engine.sourceTime
        engine.state = .ended
        engine.finishSeekAfterTerminalSourceEvent()
        #expect(engine.state == .ended)
        #expect(engine.isSeeking == false)
        #expect(engine.seekTarget == nil)
        #expect(engine.sourceTime == rendered)
    }

    @Test("Raw EOF bounds are limited to verified Matroska sources without timeline folding")
    func discontinuousSourceDoesNotAcquireRawEOFBound() {
        #expect(HLSVideoEngine.supportsRawEOFBound(containerFormatName: "matroska,webm", foldsTimeline: false))
        #expect(!HLSVideoEngine.supportsRawEOFBound(containerFormatName: "mpegts", foldsTimeline: false))
        #expect(!HLSVideoEngine.supportsRawEOFBound(containerFormatName: "mpegts", foldsTimeline: true))
        #expect(!HLSVideoEngine.supportsRawEOFBound(containerFormatName: "matroska,webm", foldsTimeline: true))
        #expect(!HLSVideoEngine.supportsRawEOFBound(containerFormatName: "mov,mp4,m4a,3gp,3g2,mj2", foldsTimeline: false))
        #expect(!HLSVideoEngine.supportsRawEOFBound(containerFormatName: nil, foldsTimeline: false))
    }

    @Test("Only confirmed EOF bounds reject a native seek; header duration is irrelevant")
    func confirmedSourceExtentBoundsSeek() {
        #expect(HLSVideoEngine.seekExceedsConfirmedEOF(itemSeconds: 4850, shiftSeconds: 0, sourceEndSeconds: 47))
        #expect(HLSVideoEngine.seekExceedsConfirmedEOF(itemSeconds: 20, shiftSeconds: 0, sourceEndSeconds: 9))
        #expect(!HLSVideoEngine.seekExceedsConfirmedEOF(itemSeconds: 4850, shiftSeconds: 0, sourceEndSeconds: nil))
        #expect(!HLSVideoEngine.seekExceedsConfirmedEOF(itemSeconds: 4, shiftSeconds: 0, sourceEndSeconds: 9))
        #expect(!HLSVideoEngine.seekExceedsConfirmedEOF(itemSeconds: 4, shiftSeconds: 23000, sourceEndSeconds: 23009))
        #expect(HLSVideoEngine.seekExceedsConfirmedEOF(itemSeconds: 20, shiftSeconds: 23000, sourceEndSeconds: 23009))
    }

    @Test("EOF without any usable seek keyframe is terminal")
    func missingKeyframeIsTerminal() {
        #expect(HLSVideoEngine.seekGateExhausted(isLive: false, videoGateOpened: false, hadRestartTarget: true))
        #expect(HLSVideoEngine.seekGateExhausted(isLive: true, videoGateOpened: false, hadRestartTarget: true) == false)
        #expect(HLSVideoEngine.seekGateExhausted(isLive: false, videoGateOpened: true, hadRestartTarget: true) == false)
        #expect(HLSVideoEngine.seekGateExhausted(isLive: false, videoGateOpened: false, hadRestartTarget: false) == false)
    }

    @Test("Exhausted gate recovery fails even if startup segments remain cached")
    func exhaustedRecoveryIsTerminal() {
        #expect(HLSVideoEngine.gateStarvationIsTerminal(recoveryAdmitted: false, recoveryIndex: 0))
        #expect(HLSVideoEngine.gateStarvationIsTerminal(recoveryAdmitted: true, recoveryIndex: nil))
        #expect(HLSVideoEngine.gateStarvationIsTerminal(recoveryAdmitted: true, recoveryIndex: 0) == false)
    }
}
