import AVFoundation
import CoreMedia
import Foundation

/// 錄影下載：以回放串流快速取得 DVR 錄影，不轉碼直接封裝成 MP4。
///
/// - 每收到一個訊框就回報流量控制序號 → DVR 以最快速度傳送（實測約即時 19 倍）
/// - H.265 / H.264 原始資料 → AVAssetWriter passthrough（hvc1 / avc1）
/// - 從第一個關鍵幀開始寫入；超過 `end` 即停止
/// - 聲音：G.711 A-law → 16-bit PCM → AVAssetWriter 編碼為 AAC（MP4 不支援 G.711）
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
        /// 寫入的聲音訊框數（0 = 沒有聲音軌）
        public let audioFrames: Int
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

    /// 開始寫檔前最多等待聲音出現的時間（DVR 聲音從指定時間才送，影像從之前的關鍵幀開始）
    static let audioWait: UInt64 = 80_000_000  // 8 秒（100ns）

    public static func export(connection: DVRConnection, channelId: String, start: Date, end: Date,
                              mainStream: Bool, includeAudio: Bool = true, to url: URL,
                              progress: @escaping @Sendable (Progress) -> Void) async throws -> Result {
        try? FileManager.default.removeItem(at: url)
        let ms = try await connection.openPlayback(
            channelId: channelId, start: start, end: end, mainStream: mainStream,
            typeMask: ["manual", "schedule", "motion", "sensor", "smart_motion", "osc", "avd",
                       "tripwire", "perimeter", "vfd", "pos", "cpc", "cdd", "ipd"])
        if includeAudio, let f = ms.setAudio { await f(true) }

        // 監看：20 秒沒有新資料就中斷
        let lastData = Clock()
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if lastData.elapsed > .seconds(20) { lastData.stalled = true; await ms.close(); return }
            }
        }

        var w = Writer(url: url, includeAudio: includeAudio)
        var pending: [SHFLFrame] = []     // 寫檔開始前暫存（自第一個關鍵幀起）
        var firstKeyFT: UInt64?
        var sawAudio = false
        let span = max(end.timeIntervalSince(start), 1)

        func cleanup() async {
            watchdog.cancel()
            await ms.close()
        }

        do {
            for try await payload in ms.frames {
                try Task.checkCancellation()
                lastData.touch()
                guard let f = SHFLFrame.parse(payload) else { continue }
                // 流量控制只依影像訊框（聲音沿用影像序號）：立即回報，讓 DVR 持續快速傳送
                if !f.isAudio, f.sequence > 0, f.sequence % 8 == 0 { await ms.acknowledge(Int(f.sequence)) }
                if f.captureTime >= end { break }
                if f.isAudio && !includeAudio { continue }

                if !w.started {
                    if firstKeyFT == nil {
                        guard !f.isAudio, f.isKeyframe, try w.prepareVideo(f) else { continue }
                        firstKeyFT = f.fileTime
                    }
                    pending.append(f)
                    if f.isAudio { sawAudio = true }
                    let waited = f.fileTime > firstKeyFT! ? f.fileTime - firstKeyFT! : 0
                    if !includeAudio || sawAudio || waited > audioWait {
                        try w.start(withAudio: includeAudio && sawAudio,
                                    audioRate: pending.first(where: \.isAudio)?.audioSampleRate ?? 8000)
                        for p in pending.sorted(by: { $0.fileTime < $1.fileTime }) { try await w.write(p) }
                        pending = []
                    }
                    continue
                }
                try await w.write(f)
                if w.frames % 10 == 0, !f.isAudio {
                    progress(Progress(fraction: min(max(f.captureTime.timeIntervalSince(start) / span, 0), 1),
                                      mediaTime: f.captureTime, frames: w.frames, bytes: w.bytes))
                }
            }
            // 錄影很短、還沒開始寫：用暫存的資料完成
            if !w.started, firstKeyFT != nil, !Task.isCancelled {
                try w.start(withAudio: includeAudio && sawAudio,
                            audioRate: pending.first(where: \.isAudio)?.audioSampleRate ?? 8000)
                for p in pending.sorted(by: { $0.fileTime < $1.fileTime }) { try await w.write(p) }
            }
        } catch {
            await cleanup()
            w.cancel()
            throw error
        }
        let stalled = lastData.stalled
        await cleanup()
        // 取消時串流迭代會直接結束：不可當成完成，刪除未完成的檔案
        if Task.isCancelled {
            w.cancel()
            throw CancellationError()
        }
        guard w.started, w.frames > 0 else {
            w.cancel()
            throw stalled ? ExportError.stalled : ExportError.noData
        }
        try await w.finish()
        progress(Progress(fraction: 1, mediaTime: w.lastTime, frames: w.frames, bytes: w.bytes))
        return Result(url: url, frames: w.frames, keyframes: w.keyframes, bytes: w.bytes, codec: w.codec,
                      width: w.dims.width, height: w.dims.height, firstFrameTime: w.firstTime, lastFrameTime: w.lastTime,
                      gapsRemoved: w.gaps, audioFrames: w.audioFrames)
    }

    /// MP4 寫入：影像 passthrough（hvc1/avc1）＋ 聲音 G.711 → PCM → AAC
    struct Writer {
        let url: URL
        let includeAudio: Bool
        var writer: AVAssetWriter?
        var video: AVAssetWriterInput?
        var audio: AVAssetWriterInput?
        var codec: VideoCodec = .h265
        var params: [Data] = []
        var videoFormat: CMVideoFormatDescription?
        var audioFormat: CMAudioFormatDescription?
        var audioRate = 8000
        var dims = CMVideoDimensions(width: 0, height: 0)
        var baseFT: UInt64 = 0, lastVideoFT: UInt64 = 0, lastAnyFT: UInt64 = 0, shift: UInt64 = 0
        var lastVideoPTS = CMTime.zero
        var nextAudioPTS = CMTime.zero
        var frames = 0, keyframes = 0, gaps = 0, audioFrames = 0
        var bytes: Int64 = 0
        var firstTime = Date(), lastTime = Date()

        var started: Bool { writer != nil }

        init(url: URL, includeAudio: Bool) {
            self.url = url
            self.includeAudio = includeAudio
        }

        /// 以第一個關鍵幀決定影像格式
        mutating func prepareVideo(_ f: SHFLFrame) throws -> Bool {
            let nals = VideoDecoder.splitAnnexB(f.videoData)
            guard let c = VideoDecoder.detectCodec(nals) else { return false }
            codec = c
            params = VideoDecoder.ordered(nals.filter { VideoDecoder.isParameterSet($0, codec: c) }, codec: c)
            let fmt = try RecordingExporter.makeFormat(params, codec: c)
            videoFormat = fmt
            dims = CMVideoFormatDescriptionGetDimensions(fmt)
            baseFT = f.fileTime; lastVideoFT = 0; lastAnyFT = f.fileTime
            firstTime = f.captureTime
            return true
        }

        mutating func start(withAudio: Bool, audioRate rate: Int) throws {
            guard let vf = videoFormat else { throw ExportError.noData }
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vf)
            v.expectsMediaDataInRealTime = true  // 避免交錯等待造成卡死
            guard w.canAdd(v) else { throw ExportError.writer("無法加入影像軌") }
            w.add(v)
            if withAudio {
                audioRate = rate
                audioFormat = try RecordingExporter.makeAudioFormat(rate: rate)
                var settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24_000]
                if !w.canApply(outputSettings: settings, forMediaType: .audio) { settings.removeValue(forKey: AVEncoderBitRateKey) }
                let a = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: audioFormat)
                a.expectsMediaDataInRealTime = true
                if w.canAdd(a) { w.add(a); audio = a }
            }
            guard w.startWriting() else { throw ExportError.writer(w.error?.localizedDescription ?? "startWriting") }
            w.startSession(atSourceTime: .zero)
            writer = w; video = v
        }

        /// 錄影空檔壓縮（影像與聲音共用時間軸）
        mutating func applyGap(_ ft: UInt64) {
            if ft > lastAnyFT {
                if ft - lastAnyFT > RecordingExporter.gapThreshold {
                    shift += ft - lastAnyFT - RecordingExporter.gapReplacement
                    gaps += 1
                }
                lastAnyFT = ft
            }
        }

        mutating func write(_ f: SHFLFrame) async throws {
            guard f.fileTime >= baseFT else { return }
            if f.isAudio { try await writeAudio(f) } else { try await writeVideo(f) }
        }

        mutating func writeVideo(_ f: SHFLFrame) async throws {
            guard let w = writer, let i = video, let fmt = videoFormat else { return }
            guard lastVideoFT == 0 || f.fileTime > lastVideoFT else { return }  // 亂序或重複
            let nals = VideoDecoder.splitAnnexB(f.videoData)
            if f.isKeyframe, lastVideoFT != 0 {
                let ps = VideoDecoder.ordered(nals.filter { VideoDecoder.isParameterSet($0, codec: codec) }, codec: codec)
                if !ps.isEmpty, ps != params, let nf = try? RecordingExporter.makeFormat(ps, codec: codec) {
                    let nd = CMVideoFormatDescriptionGetDimensions(nf)
                    if nd.width != dims.width || nd.height != dims.height { throw ExportError.formatChanged }
                }
            }
            applyGap(f.fileTime)
            var avcc = Data()
            for n in nals where !VideoDecoder.isParameterSet(n, codec: codec) && !VideoDecoder.isAUD(n, codec: codec) {
                var len = UInt32(n.count).bigEndian
                avcc.append(Data(bytes: &len, count: 4))
                avcc.append(n)
            }
            guard !avcc.isEmpty else { return }
            let pts = CMTime(value: Int64(f.fileTime - baseFT - shift), timescale: 10_000_000)
            let sample = try RecordingExporter.makeSample(avcc, format: fmt, pts: pts, keyframe: f.isKeyframe)
            try await RecordingExporter.waitReady(i)
            guard i.append(sample) else { throw ExportError.writer(w.error?.localizedDescription ?? "append video") }
            frames += 1
            if f.isKeyframe { keyframes += 1 }
            bytes += Int64(avcc.count)
            lastVideoFT = f.fileTime
            lastVideoPTS = pts
            lastTime = f.captureTime
        }

        mutating func writeAudio(_ f: SHFLFrame) async throws {
            guard let w = writer, let a = audio, let fmt = audioFormat, !f.videoData.isEmpty else { return }
            applyGap(f.fileTime)
            var pts = CMTime(value: Int64(Double(f.fileTime - baseFT - shift) / 10_000_000 * Double(audioRate)),
                             timescale: CMTimeScale(audioRate))
            if pts < nextAudioPTS { pts = nextAudioPTS }  // 避免與前一段重疊
            var pcm = Data(count: f.videoData.count * 2)
            pcm.withUnsafeMutableBytes { out in
                let o = out.bindMemory(to: Int16.self)
                for (k, b) in f.videoData.enumerated() { o[k] = G711.alaw(b).littleEndian }
            }
            // 聲音開始前或中斷的空檔補靜音，讓兩條軌道持續推進（AVAssetWriter 交錯寫入需要）
            try await fillSilence(until: pts)
            let sample = try RecordingExporter.makeAudioSample(pcm, format: fmt, pts: pts)
            try await RecordingExporter.waitReady(a)
            guard a.append(sample) else { throw ExportError.writer(w.error?.localizedDescription ?? "append audio") }
            audioFrames += 1
            nextAudioPTS = pts + CMTime(value: CMTimeValue(f.videoData.count), timescale: CMTimeScale(audioRate))
        }

        /// 從 nextAudioPTS 補靜音到 pts（每段 40 毫秒；超過 80 毫秒的空檔才補）
        mutating func fillSilence(until pts: CMTime) async throws {
            guard let w = writer, let a = audio, let fmt = audioFormat else { return }
            let chunk = audioRate / 25  // 40 毫秒
            let gap = (pts - nextAudioPTS).seconds
            guard gap > 0.08, gap < 3600 else { return }
            var t = nextAudioPTS
            while (pts - t).seconds > 0.001 {
                let n = min(chunk, Int((pts - t).seconds * Double(audioRate)))
                guard n > 0 else { break }
                let sample = try RecordingExporter.makeAudioSample(Data(count: n * 2), format: fmt, pts: t)
                try await RecordingExporter.waitReady(a)
                guard a.append(sample) else { throw ExportError.writer(w.error?.localizedDescription ?? "append silence") }
                t = t + CMTime(value: CMTimeValue(n), timescale: CMTimeScale(audioRate))
            }
            nextAudioPTS = t
        }

        mutating func finish() async throws {
            guard let w = writer else { return }
            video?.markAsFinished()
            audio?.markAsFinished()
            let videoEnd = lastVideoPTS + CMTime(value: 1, timescale: 25)
            w.endSession(atSourceTime: CMTimeMaximum(videoEnd, audio != nil ? nextAudioPTS : .zero))
            await w.finishWriting()
            guard w.status == .completed else {
                try? FileManager.default.removeItem(at: url)
                throw ExportError.writer(w.error?.localizedDescription ?? "finishWriting")
            }
        }

        func cancel() {
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 等待輸入可接收資料（最多 3 秒，避免無限等待）
    static func waitReady(_ input: AVAssetWriterInput) async throws {
        var waited = 0
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
            waited += 5
            if waited > 3000 { throw ExportError.writer("寫入逾時（\(input.mediaType == .audio ? "聲音" : "影像")軌）") }
        }
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

    static func makeAudioFormat(rate: Int) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        let st = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        guard st == noErr, let fmt else { throw ExportError.writer("聲音格式建立失敗 \(st)") }
        return fmt
    }

    static func makeAudioSample(_ pcm: Data, format: CMAudioFormatDescription, pts: CMTime) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: pcm.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: pcm.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard st == noErr, let block else { throw ExportError.writer("audio block \(st)") }
        st = pcm.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: pcm.count) }
        guard st == noErr else { throw ExportError.writer("audio copy \(st)") }
        var sample: CMSampleBuffer?
        st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: pcm.count / 2,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample)
        guard st == noErr, let sample else { throw ExportError.writer("audio sample \(st)") }
        return sample
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
