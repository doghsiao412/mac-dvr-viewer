import AVFoundation
import CoreMedia
import Foundation

/// 錄影下載：以回放串流快速取得 DVR 錄影，不轉碼直接封裝成 MP4。
///
/// - 每收到一個訊框就回報流量控制序號 → DVR 以最快速度傳送（實測約即時 19 倍）
/// - H.265 / H.264 原始資料 → AVAssetWriter passthrough（hvc1 / avc1）
/// - 從第一個關鍵幀開始寫入；超過 `end` 即停止
/// - 錄影中斷超過 3 秒的空檔會被壓縮（避免 MP4 出現長時間靜止畫面）
/// - 支援 Task 取消（中途取消會刪除未完成的檔案）
public enum RecordingExporter {
    public struct Progress: Sendable {
        public let fraction: Double
        public let mediaTime: Date
        public let frames: Int
        public let bytes: Int64
    }

    public struct Result: Sendable {
        public let url: URL
        public let frames: Int
        public let keyframes: Int
        public let bytes: Int64
        public let codec: VideoCodec
        public let width: Int32
        public let height: Int32
        public let firstFrameTime: Date
        public let lastFrameTime: Date
        public let gapsRemoved: Int
    }

    public enum ExportError: Error, CustomStringConvertible {
        case noData
        case formatChanged
        case writer(String)
        case stalled

        public var description: String {
            switch self {
            case .noData: return "這段時間沒有可下載的錄影"
            case .formatChanged: return "錄影中途改變了影像格式（解析度或編碼），已停止下載"
            case .writer(let s): return "寫入 MP4 失敗：\(s)"
            case .stalled: return "DVR 停止傳送資料（逾時 20 秒）"
            }
        }
    }

    static let gapThreshold: UInt64 = 30_000_000      // 3 秒（100ns 單位）
    static let gapReplacement: UInt64 = 1_250_000     // 壓縮後保留 0.125 秒

    public static func export(connection: DVRConnection, channelId: String, start: Date, end: Date,
                              mainStream: Bool, to url: URL,
                              progress: @escaping @Sendable (Progress) -> Void) async throws -> Result {
        try? FileManager.default.removeItem(at: url)
        let ms = try await connection.openPlayback(
            channelId: channelId, start: start, end: end, mainStream: mainStream,
            typeMask: ["manual", "schedule", "motion", "sensor", "smart_motion", "osc", "avd",
                       "tripwire", "perimeter", "vfd", "pos", "cpc", "cdd", "ipd"])

        // 監看：20 秒沒有新資料就中斷
        let lastData = Clock()
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if lastData.elapsed > .seconds(20) { lastData.stalled = true; await ms.close(); return }
            }
        }

        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var codec: VideoCodec = .h265
        var params: [Data] = []
        var dims = CMVideoDimensions(width: 0, height: 0)
        var baseFT: UInt64 = 0, lastFT: UInt64 = 0, shift: UInt64 = 0
        var lastPTS = CMTime.zero
        var frames = 0, keyframes = 0, gaps = 0
        var bytes: Int64 = 0
        var firstTime = start, lastTime = start
        let span = max(end.timeIntervalSince(start), 1)

        func cleanup() async {
            watchdog.cancel()
            await ms.close()
        }

        do {
            for try await payload in ms.frames {
                try Task.checkCancellation()
                lastData.touch()
                guard let f = SHFLFrame.parse(payload), !f.isAudio else { continue }  // 目前只下載影像
                // 流量控制：立即回報，讓 DVR 持續快速傳送
                if f.sequence > 0, f.sequence % 8 == 0 { await ms.acknowledge(Int(f.sequence)) }
                if f.captureTime >= end { break }

                let nals = VideoDecoder.splitAnnexB(f.videoData)
                if writer == nil {
                    guard f.isKeyframe, let c = VideoDecoder.detectCodec(nals) else { continue }
                    codec = c
                    params = VideoDecoder.ordered(nals.filter { VideoDecoder.isParameterSet($0, codec: c) }, codec: c)
                    let fmt = try makeFormat(params, codec: c)
                    dims = CMVideoFormatDescriptionGetDimensions(fmt)
                    let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
                    let i = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
                    i.expectsMediaDataInRealTime = false
                    guard w.canAdd(i) else { throw ExportError.writer("無法加入影像軌") }
                    w.add(i)
                    guard w.startWriting() else { throw ExportError.writer(w.error?.localizedDescription ?? "startWriting") }
                    w.startSession(atSourceTime: .zero)
                    writer = w; input = i
                    baseFT = f.fileTime; lastFT = f.fileTime
                    firstTime = f.captureTime
                } else {
                    guard f.fileTime > lastFT else { continue }  // 亂序或重複
                    if f.fileTime - lastFT > gapThreshold {
                        shift += f.fileTime - lastFT - gapReplacement
                        gaps += 1
                    }
                    if f.isKeyframe {
                        let ps = VideoDecoder.ordered(nals.filter { VideoDecoder.isParameterSet($0, codec: codec) }, codec: codec)
                        if !ps.isEmpty, ps != params {
                            // 參數集內容不同：檢查解析度是否真的改變
                            if let nf = try? makeFormat(ps, codec: codec) {
                                let nd = CMVideoFormatDescriptionGetDimensions(nf)
                                if nd.width != dims.width || nd.height != dims.height { throw ExportError.formatChanged }
                            }
                        }
                    }
                }
                guard let w = writer, let i = input else { continue }

                var avcc = Data()
                for n in nals where !VideoDecoder.isParameterSet(n, codec: codec) && !VideoDecoder.isAUD(n, codec: codec) {
                    var len = UInt32(n.count).bigEndian
                    avcc.append(Data(bytes: &len, count: 4))
                    avcc.append(n)
                }
                guard !avcc.isEmpty else { continue }
                let pts = CMTime(value: Int64(f.fileTime - baseFT - shift), timescale: 10_000_000)
                let sample = try makeSample(avcc, format: try makeFormat(params, codec: codec), pts: pts, keyframe: f.isKeyframe)
                while !i.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard i.append(sample) else { throw ExportError.writer(w.error?.localizedDescription ?? "append") }

                frames += 1
                if f.isKeyframe { keyframes += 1 }
                bytes += Int64(avcc.count)
                lastFT = f.fileTime
                lastPTS = pts
                lastTime = f.captureTime
                if frames % 10 == 0 {
                    progress(Progress(fraction: min(max(f.captureTime.timeIntervalSince(start) / span, 0), 1),
                                      mediaTime: f.captureTime, frames: frames, bytes: bytes))
                }
            }
        } catch {
            await cleanup()
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let stalled = lastData.stalled
        await cleanup()
        // 取消時串流迭代會直接結束：不可當成完成，刪除未完成的檔案
        if Task.isCancelled {
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }

        guard let w = writer, let i = input, frames > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw stalled ? ExportError.stalled : ExportError.noData
        }
        i.markAsFinished()
        w.endSession(atSourceTime: lastPTS + CMTime(value: 1, timescale: 25))
        await w.finishWriting()
        guard w.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.writer(w.error?.localizedDescription ?? "finishWriting")
        }
        progress(Progress(fraction: 1, mediaTime: lastTime, frames: frames, bytes: bytes))
        return Result(url: url, frames: frames, keyframes: keyframes, bytes: bytes, codec: codec,
                      width: dims.width, height: dims.height, firstFrameTime: firstTime, lastFrameTime: lastTime,
                      gapsRemoved: gaps)
    }

    // MARK: - CoreMedia

    static func makeFormat(_ params: [Data], codec: VideoCodec) throws -> CMVideoFormatDescription {
        var fmt: CMFormatDescription?
        let bufs = params.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { bufs.forEach { $0.deallocate() } }
        let ptrs = bufs.map { UnsafePointer($0) }
        let sizes = params.map(\.count)
        let st: OSStatus
        switch codec {
        case .h265:
            st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: ptrs.count, parameterSetPointers: ptrs, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        case .h264:
            st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: ptrs.count, parameterSetPointers: ptrs, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        }
        guard st == noErr, let fmt else { throw ExportError.writer("格式描述建立失敗 \(st)") }
        return fmt
    }

    static func makeSample(_ data: Data, format: CMVideoFormatDescription, pts: CMTime, keyframe: Bool) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard st == noErr, let block else { throw ExportError.writer("block \(st)") }
        st = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard st == noErr else { throw ExportError.writer("block copy \(st)") }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: pts)
        var size = data.count
        var sample: CMSampleBuffer?
        st = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                       sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                       sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard st == noErr, let sample else { throw ExportError.writer("sample \(st)") }
        if !keyframe, let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// 監看用的時間戳（跨 Task 共用）
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = ContinuousClock.now
        private var _stalled = false
        func touch() { lock.withLock { last = .now } }
        var elapsed: Duration { lock.withLock { ContinuousClock.now - last } }
        var stalled: Bool {
            get { lock.withLock { _stalled } }
            set { lock.withLock { _stalled = newValue } }
        }
    }
}
