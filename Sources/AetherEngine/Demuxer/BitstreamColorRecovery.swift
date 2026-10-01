import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Recovers HEVC colour signalling from the bitstream when the container left it out.
///
/// libavformat fills `codecpar.color_trc / color_primaries` from the CONTAINER (Matroska `Colour`,
/// MP4 `colr`). A file whose container omits them while the HEVC SPS VUI carries PQ / HLG / BT.2020
/// is then read as SDR: the master declared `VIDEO-RANGE=SDR`, the init segment carried no HDR
/// signalling, and on the engine lab's `g-hdr10-hevc` row (HDR10 MKV, no Colour element, AC-3
/// audio) AVPlayer failed the item with CoreMedia -12927 before fetching a segment.
///
/// The HEVC decoder exports the first SPS's VUI into the codec context while it parses extradata in
/// `avcodec_open2` (`hevc_decode_extradata` -> `export_stream_params`), so opening a decoder on the
/// stream's own extradata answers the question without decoding a frame. Only unspecified fields are
/// filled; a container that states a value always wins.
enum BitstreamColorRecovery {

    /// What the decoder found in the extradata's SPS VUI. Fields stay unspecified when it has none.
    struct Signal: Equatable {
        var transfer: AVColorTransferCharacteristic = AVCOL_TRC_UNSPECIFIED
        var primaries: AVColorPrimaries = AVCOL_PRI_UNSPECIFIED
        var matrix: AVColorSpace = AVCOL_SPC_UNSPECIFIED
    }

    /// Pure merge rule: fill only what the container left unspecified (or reserved).
    static func merged(container: Signal, bitstream: Signal) -> Signal {
        var out = container
        if isUnspecified(trc: out.transfer) { out.transfer = bitstream.transfer }
        if isUnspecified(pri: out.primaries) { out.primaries = bitstream.primaries }
        if isUnspecified(spc: out.matrix) { out.matrix = bitstream.matrix }
        return out
    }

    static func isUnspecified(trc: AVColorTransferCharacteristic) -> Bool {
        trc == AVCOL_TRC_UNSPECIFIED || trc == AVCOL_TRC_RESERVED || trc == AVCOL_TRC_RESERVED0
    }
    static func isUnspecified(pri: AVColorPrimaries) -> Bool {
        pri == AVCOL_PRI_UNSPECIFIED || pri == AVCOL_PRI_RESERVED || pri == AVCOL_PRI_RESERVED0
    }
    static func isUnspecified(spc: AVColorSpace) -> Bool {
        spc == AVCOL_SPC_UNSPECIFIED || spc == AVCOL_SPC_RESERVED
    }

    /// Fill unspecified colour fields of every HEVC video stream from its SPS VUI. Returns the
    /// indices it changed. Cheap: one decoder open on extradata per qualifying stream, no decode.
    @discardableResult
    static func repair(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> [Int32] {
        var changed: [Int32] = []
        for index in 0..<Int32(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[Int(index)],
                  let par = stream.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
                  par.pointee.codec_id == AV_CODEC_ID_HEVC,
                  par.pointee.extradata_size > 0 else { continue }
            let container = Signal(transfer: par.pointee.color_trc, primaries: par.pointee.color_primaries,
                                   matrix: par.pointee.color_space)
            guard isUnspecified(trc: container.transfer) || isUnspecified(pri: container.primaries) else { continue }
            guard let found = bitstreamSignal(par) else { continue }
            let out = merged(container: container, bitstream: found)
            guard out != container else { continue }
            par.pointee.color_trc = out.transfer
            par.pointee.color_primaries = out.primaries
            par.pointee.color_space = out.matrix
            changed.append(index)
            EngineLog.emit(
                "[Demuxer] stream=\(index) container carries no colour signalling; HEVC SPS VUI says "
                + "trc=\(out.transfer.rawValue) primaries=\(out.primaries.rawValue) matrix=\(out.matrix.rawValue), "
                + "adopting it (engine lab g-hdr10-hevc)",
                category: .demux
            )
        }
        return changed
    }

    private static func bitstreamSignal(_ par: UnsafeMutablePointer<AVCodecParameters>) -> Signal? {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_HEVC) else { return nil }
        var ctxPtr: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&ctxPtr) }
        guard let dec = ctxPtr else { return nil }
        guard avcodec_parameters_to_context(dec, par) >= 0 else { return nil }
        // The context copied the container's (unspecified) values; clear them so only what the
        // extradata's SPS exports is read back.
        dec.pointee.color_trc = AVCOL_TRC_UNSPECIFIED
        dec.pointee.color_primaries = AVCOL_PRI_UNSPECIFIED
        dec.pointee.colorspace = AVCOL_SPC_UNSPECIFIED
        dec.pointee.thread_count = 1
        var opts: OpaquePointer?
        av_dict_set(&opts, "hwaccel", "none", 0)
        let ret = avcodec_open2(dec, codec, &opts)
        av_dict_free(&opts)
        guard ret >= 0 else { return nil }
        let s = Signal(transfer: dec.pointee.color_trc, primaries: dec.pointee.color_primaries,
                       matrix: dec.pointee.colorspace)
        return s == Signal() ? nil : s
    }
}
