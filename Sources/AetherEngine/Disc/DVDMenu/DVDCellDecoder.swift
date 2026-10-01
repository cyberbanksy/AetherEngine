import Foundation
import CoreVideo
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import AetherLibswscale

/// Software decode of one cell (or any short MPEG-PS span) for the DVD menu player: MPEG-2 video frames
/// as BGRA `CVPixelBuffer`s. Subpictures are not taken from here: `DVDSubpictureScanner` reads them
/// straight from the VOBUs ahead of their display time. Menus are SD and short, so the
/// software path is cheap; title playback goes through the normal engine pipeline instead.
/// Not thread-safe: the menu player drives it from its own queue.
final class DVDCellDecoder {
    enum Event {
        case video(CVPixelBuffer, pts: Double)
    }

    private let demuxer = Demuxer()
    private var codec: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var sws: UnsafeMutablePointer<SwsContext>?
    private var videoIndex: Int32 = -1
    private var videoTimeBase = AVRational(num: 1, den: 90000)
    private var pending: [Event] = []
    private var eof = false
    private var drained = false
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)

    init(reader: IOReader) throws {
        try demuxer.open(reader: reader, formatHint: "mpeg", profile: .stillExtraction)
        videoIndex = demuxer.videoStreamIndex
        if videoIndex >= 0, let st = demuxer.stream(at: videoIndex), let par = st.pointee.codecpar,
           let dec = avcodec_find_decoder(par.pointee.codec_id), let ctx = avcodec_alloc_context3(dec) {
            avcodec_parameters_to_context(ctx, par)
            ctx.pointee.thread_count = 1
            if avcodec_open2(ctx, dec, nil) >= 0 {
                codec = ctx
                videoTimeBase = st.pointee.time_base
            } else {
                var c: UnsafeMutablePointer<AVCodecContext>? = ctx
                avcodec_free_context(&c)
            }
        }
        frame = av_frame_alloc()
    }

    deinit { close() }

    func close() {
        if codec != nil { avcodec_free_context(&codec) }
        if frame != nil { av_frame_free(&frame) }
        if let s = sws { sws_freeContext(s); sws = nil }
        demuxer.close()
    }

    var hasVideo: Bool { codec != nil }

    /// The next decoded event in stream order, or nil at the end of the cell.
    func next() -> Event? {
        while pending.isEmpty {
            if drained { return nil }
            if eof {
                if let ctx = codec { avcodec_send_packet(ctx, nil); receiveFrames() }
                drained = true
                continue
            }
            guard let pkt = try? demuxer.readPacket() else { eof = true; continue }
            defer { av_packet_free_safe(pkt) }
            if pkt.pointee.stream_index == videoIndex, let ctx = codec {
                if avcodec_send_packet(ctx, pkt) >= 0 { receiveFrames() }
            }
        }
        return pending.removeFirst()
    }

    private func receiveFrames() {
        guard let ctx = codec, let f = frame else { return }
        while avcodec_receive_frame(ctx, f) >= 0 {
            let ts = f.pointee.best_effort_timestamp != Int64.min ? f.pointee.best_effort_timestamp : f.pointee.pts
            let seconds = ts == Int64.min ? 0 : Double(ts) * Double(videoTimeBase.num) / Double(videoTimeBase.den)
            if let pb = toBGRA(f) { pending.append(.video(pb, pts: seconds)) }
            av_frame_unref(f)
        }
    }

    private func toBGRA(_ f: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let w = Int(f.pointee.width), h = Int(f.pointee.height)
        guard w > 0, h > 0 else { return nil }
        sws = sws_getCachedContext(sws, Int32(w), Int32(h), AVPixelFormat(rawValue: f.pointee.format),
                                   Int32(w), Int32(h), AV_PIX_FMT_BGRA, Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
        guard sws != nil else { return nil }
        if pool == nil || poolSize != (w, h) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p; poolSize = (w, h)
        }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        var dst: (UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?,
                  UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?)
            = (CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self), nil, nil, nil, nil, nil, nil, nil)
        var dstLs: (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32) = (Int32(CVPixelBufferGetBytesPerRow(pb)), 0, 0, 0, 0, 0, 0, 0)
        withUnsafePointer(to: &f.pointee.data) { srcData in
            withUnsafePointer(to: &f.pointee.linesize) { srcLs in
                withUnsafeMutablePointer(to: &dst) { d in
                    withUnsafeMutablePointer(to: &dstLs) { dl in
                        _ = sws_scale(sws,
                                      UnsafeRawPointer(srcData).assumingMemoryBound(to: UnsafePointer<UInt8>?.self),
                                      UnsafeRawPointer(srcLs).assumingMemoryBound(to: Int32.self),
                                      0, Int32(h),
                                      UnsafeMutableRawPointer(d).assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self),
                                      UnsafeMutableRawPointer(dl).assumingMemoryBound(to: Int32.self))
                    }
                }
            }
        }
        return pb
    }
}
