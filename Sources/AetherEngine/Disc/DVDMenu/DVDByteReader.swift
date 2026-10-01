import Foundation

// DVD-Video menu support (docs/dvd-menus.md). Clean-room implementation from the public format notes at
// dvd.sourceforge.net/dvdinfo, mpucoder.com/DVD and the "Inside DVD-Video" wikibook; no code from
// libdvdread / libdvdnav / DVD.js (GPL) was read or ported.

/// Bounds-checked big-endian reads over an IFO or NAV-pack byte buffer. Every accessor returns nil
/// (or 0 through the `…OrZero` helpers) instead of trapping, because IFO tables are untrusted input:
/// a truncated or hostile disc must degrade to "no menus", never to a crash.
struct DVDBytes {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var count: Int { bytes.count }

    func has(_ offset: Int, _ length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= bytes.count - length
    }

    func u8(_ o: Int) -> UInt8? { has(o, 1) ? bytes[o] : nil }

    func u16(_ o: Int) -> UInt16? {
        guard has(o, 2) else { return nil }
        return UInt16(bytes[o]) << 8 | UInt16(bytes[o + 1])
    }

    func u32(_ o: Int) -> UInt32? {
        guard has(o, 4) else { return nil }
        return UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])
    }

    func slice(_ o: Int, _ length: Int) -> [UInt8]? {
        guard has(o, length) else { return nil }
        return Array(bytes[o ..< o + length])
    }
}

/// A DVD BCD time (dvd_time: hh:mm:ss:ff, frame byte bits 7-6 = rate code, 11 = 30 fps, 01 = 25 fps).
struct DVDTime: Equatable, Sendable {
    let hours: Int
    let minutes: Int
    let seconds: Int
    let frames: Int
    /// Nominal frame rate from the rate code: 30 (NTSC, really 30000/1001), 25 (PAL) or 0 (illegal code).
    let frameRate: Int

    init(hours: Int, minutes: Int, seconds: Int, frames: Int, frameRate: Int) {
        self.hours = hours; self.minutes = minutes; self.seconds = seconds
        self.frames = frames; self.frameRate = frameRate
    }

    init?(_ b: DVDBytes, _ o: Int) {
        guard let raw = b.slice(o, 4) else { return nil }
        func bcd(_ x: UInt8) -> Int { Int(x >> 4) * 10 + Int(x & 0x0F) }
        hours = bcd(raw[0]); minutes = bcd(raw[1]); seconds = bcd(raw[2])
        frames = bcd(raw[3] & 0x3F)
        switch raw[3] >> 6 {
        case 3: frameRate = 30
        case 1: frameRate = 25
        default: frameRate = 0
        }
    }

    /// Seconds, using 30000/1001 for the NTSC rate code.
    var totalSeconds: Double {
        let fps: Double = frameRate == 30 ? 30000.0 / 1001.0 : Double(frameRate)
        return Double(hours * 3600 + minutes * 60 + seconds) + (fps > 0 ? Double(frames) / fps : 0)
    }
}
