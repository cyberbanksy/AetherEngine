import Testing
import AetherLibavutil
@testable import AetherEngine

struct DeinterlaceEndOfInputTests {
    @Test("EOF emits the temporal filter's final buffered picture without losing its timestamp")
    func drainsTemporalTail() throws {
        let filter = DeinterlaceFilter()
        filter.config = DeinterlaceConfig(mode: .software, fieldRate: .frame)
        let frame = try #require(av_frame_alloc())
        let output = try #require(av_frame_alloc())
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            var o: UnsafeMutablePointer<AVFrame>? = output
            av_frame_free(&f)
            av_frame_free(&o)
        }
        var timestamps: [Int64] = []
        for pts in Int64(0)..<4 {
            av_frame_unref(frame)
            frame.pointee.width = 64
            frame.pointee.height = 64
            frame.pointee.format = AV_PIX_FMT_YUV420P.rawValue
            frame.pointee.pts = pts
            frame.pointee.flags |= (1 << 3)
            try #require(av_frame_get_buffer(frame, 0) >= 0)
            try #require(filter.ensureGraph(frame: frame, timeBase: AVRational(num: 1, den: 25)))
            try #require(filter.push(frame) >= 0)
            // Push preserves the caller's decoded frame for a direct-render fallback.
            #expect(frame.pointee.width == 64)
            while filter.pull(into: output) >= 0 {
                timestamps.append(output.pointee.pts)
                av_frame_unref(output)
            }
        }
        #expect(timestamps.count < 4)
        try #require(filter.finish() >= 0)
        while filter.pull(into: output) >= 0 {
            timestamps.append(output.pointee.pts)
            av_frame_unref(output)
        }
        #expect(timestamps.count == 4)
        #expect(timestamps == timestamps.sorted())
        #expect(timestamps.last == 6) // bwdif doubles the 1/25 input time base.
    }
}
