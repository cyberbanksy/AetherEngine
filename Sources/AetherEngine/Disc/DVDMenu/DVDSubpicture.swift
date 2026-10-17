import Foundation
import CoreGraphics

// Clean-room DVD subpicture (SPU) decoder and menu highlight renderer, written from
// dvd.sourceforge.net/dvdinfo/spu.html and pci_pkt.html (docs/dvd-menus.md). FFmpeg's dvdsub decoder is
// not used for menus because it returns pre-coloured RGBA: the highlight needs the raw 2-bit pixel codes
// to recolour the selected button with the PCI selection / action colours.

/// A subpicture unit: header + RLE fields + display control sequences.
struct DVDSubpictureUnit: Equatable, Sendable {
    /// One display control sequence (SP_DCSQ).
    struct Control: Equatable, Sendable {
        /// Delay from the unit's PTS, in 90 kHz ticks (SP_DCSQ_STM * 1024).
        var delay90k: UInt32
        var forcedStart = false
        var start = false
        var stop = false
        /// Palette indices per pixel code (0 background, 1 pattern, 2 emphasis 1, 3 emphasis 2).
        var colors: [UInt8]?
        /// Contrast (0 transparent ... 15 opaque) per pixel code.
        var contrast: [UInt8]?
        /// Display area, inclusive.
        var area: (x0: Int, y0: Int, x1: Int, y1: Int)?
        var topFieldOffset: Int?
        var bottomFieldOffset: Int?

        static func == (a: Control, b: Control) -> Bool {
            a.delay90k == b.delay90k && a.forcedStart == b.forcedStart && a.start == b.start && a.stop == b.stop &&
                a.colors == b.colors && a.contrast == b.contrast && a.topFieldOffset == b.topFieldOffset &&
                a.bottomFieldOffset == b.bottomFieldOffset &&
                a.area.map { [$0.x0, $0.y0, $0.x1, $0.y1] } == b.area.map { [$0.x0, $0.y0, $0.x1, $0.y1] }
        }
    }

    let data: [UInt8]
    let controls: [Control]

    /// Parses a complete unit (the 2-byte size header says how long it is). nil when malformed.
    static func parse(_ data: [UInt8]) -> DVDSubpictureUnit? {
        let b = DVDBytes(data)
        guard let size = b.u16(0), let dcsqStart = b.u16(2), Int(size) <= data.count, dcsqStart >= 4,
              Int(dcsqStart) < Int(size) else { return nil }
        var controls: [Control] = []
        var at = Int(dcsqStart)
        var visited = Set<Int>()
        while visited.insert(at).inserted, controls.count < 64 {
            guard let stm = b.u16(at), let next = b.u16(at + 2) else { break }
            var c = Control(delay90k: UInt32(stm) * 1024)
            var i = at + 4
            loop: while i < Int(size), let cmd = b.u8(i) {
                i += 1
                switch cmd {
                case 0x00: c.forcedStart = true
                case 0x01: c.start = true
                case 0x02: c.stop = true
                case 0x03:
                    guard let v = b.u16(i) else { break loop }
                    c.colors = [UInt8(v & 0xF), UInt8(v >> 4 & 0xF), UInt8(v >> 8 & 0xF), UInt8(v >> 12 & 0xF)]
                    i += 2
                case 0x04:
                    guard let v = b.u16(i) else { break loop }
                    c.contrast = [UInt8(v & 0xF), UInt8(v >> 4 & 0xF), UInt8(v >> 8 & 0xF), UInt8(v >> 12 & 0xF)]
                    i += 2
                case 0x05:
                    guard let r = b.slice(i, 6) else { break loop }
                    let x0 = Int(r[0]) << 4 | Int(r[1] >> 4), x1 = Int(r[1] & 0xF) << 8 | Int(r[2])
                    let y0 = Int(r[3]) << 4 | Int(r[4] >> 4), y1 = Int(r[4] & 0xF) << 8 | Int(r[5])
                    c.area = (x0, y0, x1, y1)
                    i += 6
                case 0x06:
                    guard let t = b.u16(i), let bo = b.u16(i + 2) else { break loop }
                    c.topFieldOffset = Int(t); c.bottomFieldOffset = Int(bo)
                    i += 4
                case 0x07:
                    // CHG_COLCON: skipped (parameter area length includes its own size word).
                    guard let len = b.u16(i) else { break loop }
                    i += Int(len)
                case 0xFF:
                    break loop
                default:
                    break loop          // unknown command: the rest of this sequence is undecodable
                }
            }
            controls.append(c)
            if Int(next) == at { break }
            at = Int(next)
        }
        return controls.isEmpty ? nil : DVDSubpictureUnit(data: Array(data.prefix(Int(size))), controls: controls)
    }

    /// The first control's (or the merged first non-nil) presentation parameters.
    var displayArea: (x0: Int, y0: Int, x1: Int, y1: Int)? { controls.lazy.compactMap(\.area).first }
    var colors: [UInt8] { controls.lazy.compactMap(\.colors).first ?? [0, 1, 2, 3] }
    var contrast: [UInt8] { controls.lazy.compactMap(\.contrast).first ?? [0, 15, 15, 15] }
    var isForced: Bool { controls.contains { $0.forcedStart } }
    /// Ticks after the PTS at which display stops, if a stop command is present.
    var stopDelay90k: UInt32? { controls.first { $0.stop }?.delay90k }

    /// Decodes the RLE pixel data into one pixel code per pixel over the display area (row-major).
    func decodePixels() -> DVDSubpictureBitmap? {
        guard let area = displayArea, let top = controls.lazy.compactMap(\.topFieldOffset).first,
              let bottom = controls.lazy.compactMap(\.bottomFieldOffset).first else { return nil }
        let w = area.x1 - area.x0 + 1, h = area.y1 - area.y0 + 1
        guard w > 0, h > 0, w <= 1920, h <= 1152 else { return nil }
        var codes = [UInt8](repeating: 0, count: w * h)
        for (field, offset) in [(0, top), (1, bottom)] {
            var reader = NibbleReader(data: data, nibble: offset * 2)
            var y = field
            while y < h {
                var x = 0
                while x < w {
                    guard let (count, code) = reader.run() else { y = h; break }
                    let n = count == 0 ? w - x : min(count, w - x)        // 0 = to end of line
                    if n > 0 { codes.replaceSubrange(y * w + x ..< y * w + x + n, with: repeatElement(code, count: n)) }
                    x += n
                    if count == 0 { break }
                }
                reader.alignToByte()
                y += 2
            }
        }
        return DVDSubpictureBitmap(x: area.x0, y: area.y0, width: w, height: h, codes: codes)
    }
}

/// 2-bit pixel codes for a subpicture's display area.
struct DVDSubpictureBitmap: Equatable, Sendable {
    let x: Int, y: Int
    let width: Int, height: Int
    let codes: [UInt8]

    func code(atX px: Int, y py: Int) -> UInt8? {
        let cx = px - x, cy = py - y
        guard cx >= 0, cy >= 0, cx < width, cy < height else { return nil }
        return codes[cy * width + cx]
    }
}

/// Reads the variable-length run codes: 1-3 px in 4 bits, 4-15 in 8, 16-63 in 12, 64-255 in 16
/// (count 0 in the 16-bit form = until end of line). Code = low 2 bits, count = the bits above.
private struct NibbleReader {
    let data: [UInt8]
    var nibble: Int

    mutating func next() -> UInt16? {
        let byte = nibble / 2
        guard byte < data.count else { return nil }
        let v = nibble % 2 == 0 ? data[byte] >> 4 : data[byte] & 0xF
        nibble += 1
        return UInt16(v)
    }

    mutating func run() -> (count: Int, code: UInt8)? {
        guard var v = next() else { return nil }
        if v < 0x4 {
            guard let n = next() else { return nil }
            v = v << 4 | n
            if v < 0x10 {
                guard let n2 = next() else { return nil }
                v = v << 4 | n2
                if v < 0x40 {
                    guard let n3 = next() else { return nil }
                    v = v << 4 | n3
                }
            }
        }
        return (Int(v >> 2), UInt8(v & 0x3))
    }

    mutating func alignToByte() { if nibble % 2 == 1 { nibble += 1 } }
}

// MARK: - Highlight rendering

/// Renders a menu subpicture with the highlight state of one button applied, as straight RGBA.
enum DVDHighlightRenderer {
    /// PGC palette entry (0x00YYCrCb) -> RGB, BT.601 limited range.
    static func rgb(fromYCrCb v: UInt32) -> (r: UInt8, g: UInt8, b: UInt8) {
        let y = Double((v >> 16) & 0xFF) - 16, cr = Double((v >> 8) & 0xFF) - 128, cb = Double(v & 0xFF) - 128
        func clamp(_ x: Double) -> UInt8 { UInt8(max(0, min(255, x.rounded()))) }
        return (clamp(1.164 * y + 1.596 * cr), clamp(1.164 * y - 0.813 * cr - 0.391 * cb), clamp(1.164 * y + 2.018 * cb))
    }

    /// Button state used for its rectangle.
    enum ButtonState: Equatable, Sendable { case selected, activated }

    /// Straight-alpha RGBA pixels of the subpicture's display area (`bitmap.width` x `bitmap.height`,
    /// placed at `bitmap.x`, `bitmap.y` on the menu canvas), plus whether any pixel is visible.
    /// Outside the highlighted button the subpicture's own colours / contrast apply; inside its
    /// rectangle the PCI scheme's selection (or action) colours / contrast replace them.
    static func renderRGBA(bitmap: DVDSubpictureBitmap, spuColors: [UInt8], spuContrast: [UInt8],
                           palette: [UInt32], button: DVDButton?, scheme: DVDButtonColors?,
                           state: ButtonState) -> (pixels: [UInt8], visible: Bool) {
        var out = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        var visible = false
        let rgbPalette = (0..<16).map { palette.indices.contains($0) ? rgb(fromYCrCb: palette[$0]) : (0, 0, 0) }
        let hlColors = scheme.map { state == .activated ? $0.actionColor : $0.selectionColor }
        let hlContrast = scheme.map { state == .activated ? $0.actionContrast : $0.selectionContrast }
        // Per-code lookups for the two regions, so the pixel loop is table reads only.
        func lut(_ colors: [UInt8], _ contrast: [UInt8]) -> [(UInt8, UInt8, UInt8, UInt8)] {
            (0..<4).map { code in
                let c = rgbPalette[Int(colors[code]) & 0xF]
                return (c.0, c.1, c.2, UInt8(min(255, Int(contrast[code]) * 17)))
            }
        }
        let normal = lut(spuColors, spuContrast)
        let lit = (hlColors != nil && hlContrast != nil) ? lut(hlColors!, hlContrast!) : normal
        bitmap.codes.withUnsafeBufferPointer { codes in
            out.withUnsafeMutableBufferPointer { o in
                for row in 0..<bitmap.height {
                    let py = bitmap.y + row
                    for col in 0..<bitmap.width {
                        let px = bitmap.x + col
                        let i = row * bitmap.width + col
                        let inButton = button.map { px >= $0.x0 && px <= $0.x1 && py >= $0.y0 && py <= $0.y1 } ?? false
                        let v = (inButton ? lit : normal)[Int(codes[i])]
                        guard v.3 > 0 else { continue }
                        o[i * 4] = v.0; o[i * 4 + 1] = v.1; o[i * 4 + 2] = v.2; o[i * 4 + 3] = v.3
                        visible = true
                    }
                }
            }
        }
        return (out, visible)
    }

    /// The same as a premultiplied CGImage for the subtitle overlay path.
    static func image(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        var pre = rgba
        pre.withUnsafeMutableBufferPointer { p in
            for i in stride(from: 0, to: p.count, by: 4) {
                let a = UInt16(p[i + 3])
                if a < 255 {
                    p[i] = UInt8(UInt16(p[i]) * a / 255)
                    p[i + 1] = UInt8(UInt16(p[i + 1]) * a / 255)
                    p[i + 2] = UInt8(UInt16(p[i + 2]) * a / 255)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pre) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Pulls subpicture units straight out of MPEG-PS sectors (private stream 1, substreams 0x20-0x3F), so
/// the menu player knows a VOBU's subpictures before its video is due, independent of how far the video
/// decoder has read. Pack / PES layout per ISO 13818-1 and dvd.sourceforge.net's dvdmpeg notes.
struct DVDSubpictureScanner: Sendable {
    private static let noPTS = Int64.min
    private var assemblers: [Int: DVDSubpictureAssembler] = [:]

    /// Scans whole 2048-byte sectors; returns completed units with their stream number and PTS (seconds).
    mutating func scan(_ bytes: [UInt8]) -> [(stream: Int, unit: DVDSubpictureUnit, pts: Double?)] {
        var out: [(stream: Int, unit: DVDSubpictureUnit, pts: Double?)] = []
        var sector = 0
        while sector + 2048 <= bytes.count {
            let s = sector
            sector += 2048
            guard bytes[s] == 0, bytes[s + 1] == 0, bytes[s + 2] == 1, bytes[s + 3] == 0xBA else { continue }
            // MPEG-2 pack header: 14 bytes + stuffing (low 3 bits of byte 13).
            var i = s + 14 + Int(bytes[s + 13] & 0x07)
            let end = s + 2048
            while i + 6 <= end, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let id = bytes[i + 3]
                let len = Int(bytes[i + 4]) << 8 | Int(bytes[i + 5])
                let next = i + 6 + len
                defer { i = next }
                guard next <= end, id == 0xBD, len >= 4 else { continue }
                let flags = bytes[i + 7]
                let hdrLen = Int(bytes[i + 8])
                let subAt = i + 9 + hdrLen
                guard subAt < next else { continue }
                let sub = bytes[subAt]
                guard (0x20...0x3F).contains(sub) else { continue }
                var pts: Double?
                if flags & 0x80 != 0, hdrLen >= 5 {
                    let p = i + 9
                    let v = (Int64(bytes[p] >> 1) & 0x07) << 30 | Int64(bytes[p + 1]) << 22 |
                        (Int64(bytes[p + 2]) >> 1) << 15 | Int64(bytes[p + 3]) << 7 | Int64(bytes[p + 4]) >> 1
                    pts = Double(v) / 90000
                }
                let stream = Int(sub & 0x1F)
                var asm = assemblers[stream] ?? DVDSubpictureAssembler()
                let ptsTicks = pts.map { Int64(($0 * 90000).rounded()) } ?? Self.noPTS
                let timing = DVDSubpictureAssembler.Timing(pts: ptsTicks, dts: ptsTicks, pos: Int64(s), duration: 0)
                if let done = bytes[(subAt + 1) ..< next].withUnsafeBytes({ asm.ingest($0, timing: timing) }),
                   let unit = DVDSubpictureUnit.parse(done.data) {
                    out.append((stream, unit, done.timing.pts == Self.noPTS ? nil : Double(done.timing.pts) / 90000))
                }
                assemblers[stream] = asm
            }
        }
        return out
    }
}
