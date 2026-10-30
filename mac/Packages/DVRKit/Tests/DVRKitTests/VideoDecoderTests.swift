import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import DVRKit

/// Mock 測試：用 VideoToolbox 編碼合成畫面 → Annex-B → 包成 SHFL → SHFLFrame.parse → VideoDecoder
/// 不使用任何監視影像。
struct VideoDecoderTests {
    /// 編碼 n 張漸層畫面，回傳每張的 Annex-B（第一張含參數集）
    func encode(codec: CMVideoCodecType, frames n: Int, w: Int32 = 320, h: Int32 = 240) throws -> [Data] {
        var session: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: w, height: h, codecType: codec, encoderSpecification: nil,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                            refcon: nil, compressionSessionOut: &session)
        guard st == noErr, let session else { throw VideoDecoder.DecodeError.session(st) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        var out: [Data] = []
        for i in 0..<n {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(w), Int(h), kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<Int(h) { for x in 0..<Int(w) {
                let o = y * stride + x * 4
                p[o] = UInt8((x + i * 8) & 0xFF); p[o + 1] = UInt8(y & 0xFF); p[o + 2] = UInt8((x ^ y) & 0xFF); p[o + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            let props = i == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            var encoded: CMSampleBuffer?
            VTCompressionSessionEncodeFrame(session, imageBuffer: buf, presentationTimeStamp: CMTime(value: Int64(i), timescale: 25),
                                            duration: .invalid, frameProperties: props, infoFlagsOut: nil) { _, _, sb in encoded = sb }
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            if let sb = encoded { out.append(annexB(sb, codec: codec, includeParams: i == 0)) }
        }
        VTCompressionSessionInvalidate(session)
        return out
    }

    func annexB(_ sb: CMSampleBuffer, codec: CMVideoCodecType, includeParams: Bool) -> Data {
        var d = Data()
        let sc = Data([0, 0, 0, 1])
        if includeParams, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            if codec == kCMVideoCodecType_HEVC {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                   parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                   parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            for k in 0..<count {
                var ptr: UnsafePointer<UInt8>?; var size = 0
                if codec == kCMVideoCodecType_HEVC {
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: k, parameterSetPointerOut: &ptr,
                                                                       parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                } else {
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: k, parameterSetPointerOut: &ptr,
                                                                       parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                }
                if let ptr { d.append(sc); d.append(ptr, count: size) }
            }
        }
        let block = CMSampleBufferGetDataBuffer(sb)!
        var len = 0; var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
        let raw = Data(bytes: ptr!, count: len)
        var o = 0
        while o + 4 <= raw.count {
            let n = Int(raw[o]) << 24 | Int(raw[o + 1]) << 16 | Int(raw[o + 2]) << 8 | Int(raw[o + 3])
            d.append(sc); d.append(raw.subdata(in: (o + 4)..<(o + 4 + n))); o += 4 + n
        }
        return d
    }

    /// 依實測格式包成 SHFL 訊框
    func shfl(_ video: Data, keyframe: Bool, seq: UInt32, w: UInt16, h: UInt16, fourcc: String) -> Data {
        var d = Data("SHFL".utf8)
        d.append(contentsOf: [3, 1, 2, keyframe ? 1 : 0])
        d.append(contentsOf: [1, 0, 0, 0]); d.append(Data(count: 12))
        let ext = keyframe ? 12 : 0
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let ft: UInt64 = 134_064_000_000_000_000 + UInt64(seq) * 400_000  // 2025 年某時 + 40ms * seq
        d.append(u32(UInt32(24 + ext + video.count)))  // 24：dataLen = 總長 - 44
        d.append(u64(ft)); d.append(u32(seq)); d.append(u32(0))
        d.append(contentsOf: [0, UInt8(ext), keyframe ? 1 : 0, 0])
        d.append(u32(UInt32(video.count))); d.append(u64(ft)); d.append(u64(ft))
        if keyframe {
            d.append(u32(0x100)); d.append(Data(fourcc.utf8))
            d.append(withUnsafeBytes(of: w.littleEndian) { Data($0) }); d.append(withUnsafeBytes(of: h.littleEndian) { Data($0) })
        }
        d.append(video)
        return d
    }

    func roundTrip(_ codec: CMVideoCodecType, expect: VideoCodec, fourcc: String) throws {
        let aus = try encode(codec: codec, frames: 10)
        #expect(aus.count == 10)
        let dec = VideoDecoder()
        var decoded = 0
        for (i, au) in aus.enumerated() {
            let frame = try #require(SHFLFrame.parse(shfl(au, keyframe: i == 0, seq: UInt32(i + 1), w: 320, h: 240, fourcc: fourcc)))
            #expect(frame.isKeyframe == (i == 0))
            #expect(frame.sequence == UInt32(i + 1))
            #expect(frame.videoData == au)
            if i == 0 { #expect(frame.fourCC == fourcc); #expect(frame.width == 320); #expect(frame.height == 240) }
            if let out = try dec.decode(annexB: frame.videoData, pts: CMTime(value: Int64(i), timescale: 25)) {
                decoded += 1
                #expect(CVPixelBufferGetWidth(out.pixelBuffer) == 320)
                let st = try #require(Snapshot.lumaStats(out.pixelBuffer))
                #expect(st.looksValid)
            }
        }
        #expect(decoded == 10)
        #expect(dec.codec == expect)
    }

    @Test func hevcRoundTrip() throws { try roundTrip(kCMVideoCodecType_HEVC, expect: .h265, fourcc: "HEVC") }
    @Test func h264RoundTrip() throws { try roundTrip(kCMVideoCodecType_H264, expect: .h264, fourcc: "H264") }

    @Test func waitsForKeyframeBeforeDecoding() throws {
        let aus = try encode(codec: kCMVideoCodecType_HEVC, frames: 3)
        let dec = VideoDecoder()
        #expect(try dec.decode(annexB: aus[1], pts: .zero) == nil)  // P 幀在關鍵幀之前：等待
        #expect(try dec.decode(annexB: aus[0], pts: .zero) != nil)  // 關鍵幀到達後可解碼
    }
}
