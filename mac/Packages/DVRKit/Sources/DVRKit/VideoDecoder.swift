import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// H.264 / H.265 Annex-B → VideoToolbox 硬體解碼。
///
/// - 從關鍵幀收集 VPS/SPS/PPS，建立 `CMVideoFormatDescription`；參數集改變時重建 session
/// - 其餘 NAL 轉成 4-byte 長度前綴（AVCC/HVCC 格式）後送入 `VTDecompressionSession`
/// - 同步解碼（呼叫端應在背景執行緒/actor 呼叫，不可在主執行緒）
public final class VideoDecoder: @unchecked Sendable {
    public struct DecodedFrame: @unchecked Sendable {
        public let pixelBuffer: CVPixelBuffer
        public let pts: CMTime
    }

    public enum DecodeError: Error, CustomStringConvertible {
        case noParameterSets
        case formatDescription(OSStatus)
        case session(OSStatus)
        case decode(OSStatus)
        case blockBuffer(OSStatus)

        public var description: String {
            switch self {
            case .noParameterSets: return "尚未收到參數集（等待關鍵幀）"
            case .formatDescription(let s): return "建立格式描述失敗 \(s)"
            case .session(let s): return "建立解碼 session 失敗 \(s)"
            case .decode(let s): return "解碼失敗 \(s)"
            case .blockBuffer(let s): return "建立 CMBlockBuffer 失敗 \(s)"
            }
        }
    }

    public private(set) var codec: VideoCodec?
    public private(set) var dimensions: CMVideoDimensions?
    public private(set) var usingHardware: Bool?

    private var paramSets: [Data] = []
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private let lock = NSLock()

    public init() {}

    deinit { invalidate() }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
    }

    /// 解碼一個 access unit（Annex-B）。尚未收到參數集（等待關鍵幀）或沒有影像 NAL 時回傳 nil。
    public func decode(annexB: Data, pts: CMTime) throws -> DecodedFrame? {
        lock.lock(); defer { lock.unlock() }
        let nals = Self.splitAnnexB(annexB)
        guard !nals.isEmpty else { return nil }

        // 判斷編碼（以第一個合法 NAL 判斷，H.265 參數集優先）
        let detected = codec ?? Self.detectCodec(nals)
        guard let cdc = detected else { return nil }
        codec = cdc

        var newParams: [Data] = []
        var vcl: [Data] = []
        for n in nals {
            if Self.isParameterSet(n, codec: cdc) { newParams.append(n) } else if !Self.isAUD(n, codec: cdc) { vcl.append(n) }
        }
        if !newParams.isEmpty, newParams != paramSets {
            paramSets = Self.ordered(newParams, codec: cdc)
            try rebuild()
        }
        guard let format, let session else { return nil }  // 尚未收到參數集：等待關鍵幀
        guard !vcl.isEmpty else { return nil }

        // 長度前綴
        var avcc = Data(capacity: vcl.reduce(0) { $0 + $1.count + 4 })
        for n in vcl {
            var len = UInt32(n.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(n)
        }
        let sample = try makeSampleBuffer(avcc, format: format, pts: pts)

        var result: DecodedFrame?
        var cbStatus: OSStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                       infoFlagsOut: nil) { st, _, image, ptsOut, _ in
            cbStatus = st
            if st == noErr, let image { result = DecodedFrame(pixelBuffer: image, pts: ptsOut) }
        }
        if status != noErr { throw DecodeError.decode(status) }
        if cbStatus != noErr { throw DecodeError.decode(cbStatus) }
        return result
    }

    // MARK: - 內部

    private func rebuild() throws {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
            session = nil
        }
        var fmt: CMFormatDescription?
        let status: OSStatus = paramSets.withPointers { ptrs, sizes in
            switch codec {
            case .h265:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
            default:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        guard status == noErr, let fmt else { throw DecodeError.formatDescription(status) }
        format = fmt
        dimensions = CMVideoFormatDescriptionGetDimensions(fmt)

        let spec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt,
                                              decoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: attrs as CFDictionary,
                                              outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let s else { throw DecodeError.session(st) }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var hw: CFTypeRef?
        if VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                 allocator: nil, valueOut: &hw) == noErr {
            usingHardware = (hw as? Bool) ?? (hw as? NSNumber)?.boolValue
        }
        session = s
    }

    private func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription, pts: CMTime) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard st == noErr, let block else { throw DecodeError.blockBuffer(st) }
        st = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard st == noErr else { throw DecodeError.blockBuffer(st) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                       sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                       sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard st == noErr, let sample else { throw DecodeError.blockBuffer(st) }
        return sample
    }

    // MARK: - NAL 工具

    static func splitAnnexB(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var starts: [(code: Int, nal: Int)] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                let code = (i > 0 && b[i - 1] == 0) ? i - 1 : i
                starts.append((code, i + 3))
                i += 3
            } else { i += 1 }
        }
        var out: [Data] = []
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].code : b.count
            if end > s.nal { out.append(Data(b[s.nal..<end])) }
        }
        return out
    }

    static func h265Type(_ n: Data) -> Int { Int((n[n.startIndex] >> 1) & 0x3F) }
    static func h264Type(_ n: Data) -> Int { Int(n[n.startIndex] & 0x1F) }

    static func detectCodec(_ nals: [Data]) -> VideoCodec? {
        if nals.contains(where: { [32, 33, 34].contains(h265Type($0)) }) && nals.contains(where: { h265Type($0) == 32 }) { return .h265 }
        if nals.contains(where: { [7, 8].contains(h264Type($0)) }) { return .h264 }
        return nil
    }

    static func isParameterSet(_ n: Data, codec: VideoCodec) -> Bool {
        codec == .h265 ? [32, 33, 34].contains(h265Type(n)) : [7, 8].contains(h264Type(n))
    }

    static func isAUD(_ n: Data, codec: VideoCodec) -> Bool {
        codec == .h265 ? h265Type(n) == 35 : h264Type(n) == 9
    }

    /// VideoToolbox 需要 VPS→SPS→PPS（H.264：SPS→PPS）順序，且每種只取第一個
    static func ordered(_ ps: [Data], codec: VideoCodec) -> [Data] {
        let order = codec == .h265 ? [32, 33, 34] : [7, 8]
        return order.compactMap { t in ps.first { (codec == .h265 ? h265Type($0) : h264Type($0)) == t } }
    }
}

private extension Array where Element == Data {
    func withPointers<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let buffers = map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        return body(buffers.map { UnsafePointer($0) }, map(\.count))
    }
}
