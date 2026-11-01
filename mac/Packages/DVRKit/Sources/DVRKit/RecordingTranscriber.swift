import AVFoundation
import Foundation
import FoundationModels
import Speech

/// 錄影逐字稿：從 DVR 回放串流取出一段時間的聲音，交給系統語音辨識（SpeechTranscriber，裝置端）。
///
/// 每段聲音都以 DVR 錄影時間作為辨識的起點時間（`bufferStartTime`），
/// 所以每一句都能對回錄影的實際時間；錄影中斷的空檔不會讓後面的時間偏移。
public enum RecordingTranscriber {
    /// 最近一次轉錄的聲音統計（只有音量，不含內容；驗證用）
    public struct AudioStats: Sendable {
        public var frames = 0
        public var seconds = 0.0
        /// 音量明顯（RMS > 500，約 -36 dBFS）的秒數
        public var loudSeconds = 0.0
        public var peakRMS = 0.0
    }
    nonisolated(unsafe) public static var lastStats = AudioStats()

    public struct Line: Sendable, Hashable, Identifiable, Codable {
        public let id: Int
        public let start: Date
        public let end: Date
        public let text: String
    }

    public struct Progress: Sendable {
        /// 0–1：已處理到的錄影時間
        public let fraction: Double
        public let lines: Int
    }

    public enum TranscribeError: Error, CustomStringConvertible {
        case unsupported
        case noAudio
        case noData
        case stalled

        public var description: String {
            switch self {
            case .unsupported: return "這台裝置的語音辨識不支援繁體中文"
            case .noAudio: return "這段錄影沒有聲音（攝影機可能沒有麥克風）"
            case .noData: return "這段時間沒有錄影"
            case .stalled: return "DVR 停止傳送資料"
            }
        }
    }

    /// 語音辨識語言（台灣中文）
    static func locale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-TW"))
    }

    public static func isAvailable() async -> Bool { await locale() != nil }

    public static func transcribe(connection: DVRConnection, channelId: String, start: Date, end: Date,
                                  progress: @escaping @Sendable (Progress) -> Void) async throws -> [Line] {
        guard let loc = await locale() else { throw TranscribeError.unsupported }
        let transcriber = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // 語音模型未下載時由系統下載（台灣中文通常已內建）
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscribeError.unsupported
        }
        let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()

        let counter = LineCounter()
        let collector = Task { () throws -> [Line] in
            var lines: [Line] = []
            for try await r in transcriber.results {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let s = r.range.start.seconds, e = r.range.end.seconds
                lines.append(Line(id: lines.count, start: start.addingTimeInterval(s.isFinite ? s : 0),
                                  end: start.addingTimeInterval(e.isFinite ? e : s), text: text))
                counter.set(lines.count)
            }
            return lines
        }
        try await analyzer.start(inputSequence: inputs)

        // 回放串流：只取聲音（影像訊框僅用於流量控制）
        let ms = try await connection.openPlayback(
            channelId: channelId, start: start, end: end, mainStream: false,
            typeMask: ["manual", "schedule", "motion", "sensor", "smart_motion", "osc", "avd",
                       "tripwire", "perimeter", "vfd", "pos", "cpc", "cdd", "ipd"])
        if let f = ms.setAudio { await f(true) }
        let lastData = RecordingExporter.Clock()
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if lastData.elapsed > .seconds(20) { lastData.stalled = true; await ms.close(); return }
            }
        }

        var batch = AudioBatch(format: format)
        var sawVideo = false, audioFrames = 0
        var stats = AudioStats()
        defer { lastStats = stats }
        let span = max(end.timeIntervalSince(start), 1)
        do {
            for try await payload in ms.frames {
                try Task.checkCancellation()
                lastData.touch()
                guard let f = SHFLFrame.parse(payload) else { continue }
                if !f.isAudio, f.sequence > 0, f.sequence % 8 == 0 { await ms.acknowledge(Int(f.sequence)) }
                if f.captureTime >= end { break }
                if !f.isAudio {
                    sawVideo = true
                    if f.sequence % 25 == 0 {
                        progress(Progress(fraction: min(max(f.captureTime.timeIntervalSince(start) / span, 0), 1),
                                          lines: counter.value))
                    }
                    continue
                }
                guard f.captureTime >= start, !f.videoData.isEmpty else { continue }
                audioFrames += 1
                stats.frames += 1
                let rate = Double(f.audioSampleRate ?? 8000)
                let d = Double(f.videoData.count) / rate
                stats.seconds += d
                let rms = (f.videoData.reduce(0.0) { let v = Double(G711.alaw($1)); return $0 + v * v } / Double(f.videoData.count)).squareRoot()
                stats.peakRMS = max(stats.peakRMS, rms)
                if rms > 500 { stats.loudSeconds += d }
                let t = f.captureTime.timeIntervalSince(start)
                if let ready = batch.append(f.videoData, rate: f.audioSampleRate ?? 8000, at: t) { input.yield(ready) }
            }
        } catch {
            watchdog.cancel(); await ms.close()
            input.finish(); collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        let stalled = lastData.stalled
        watchdog.cancel()
        await ms.close()
        if let last = batch.flush() { input.yield(last) }
        input.finish()
        if Task.isCancelled {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let lines = try await collector.value
        if audioFrames == 0 {
            if stalled { throw TranscribeError.stalled }
            throw sawVideo ? TranscribeError.noAudio : TranscribeError.noData
        }
        progress(Progress(fraction: 1, lines: lines.count))
        return lines.sorted { $0.start < $1.start }
    }

    /// 把 DVR 的 G.711 聲音（8 kHz）轉成辨識需要的格式，並依時間連續性分批（約 1 秒一批）
    struct AudioBatch {
        let format: AVAudioFormat
        private var samples: [Int16] = []
        private var startTime: TimeInterval = 0
        private var nextTime: TimeInterval = 0
        /// 上一批送出的結尾時間：辨識要求時間嚴格遞增，下一批不可早於此
        private var lastEnd: TimeInterval = -1

        init(format: AVAudioFormat) { self.format = format }

        /// 加入一個聲音訊框；累積滿 1 秒或遇到時間不連續時回傳上一批
        mutating func append(_ g711: Data, rate: Int, at t: TimeInterval) -> AnalyzerInput? {
            var out: AnalyzerInput?
            let duration = Double(g711.count) / Double(rate)
            if !samples.isEmpty, abs(t - nextTime) > 0.2 { out = flush() }   // 錄影空檔：另起一批
            if samples.isEmpty { startTime = max(t, lastEnd) }
            let ratio = format.sampleRate / Double(rate)
            let pcm = g711.map { G711.alaw($0) }
            let n = Int((Double(pcm.count) * ratio).rounded())
            samples.reserveCapacity(samples.count + n)
            for i in 0..<n {
                // 線性插值升頻（8 kHz → 16 kHz）
                let x = Double(i) / ratio
                let i0 = min(Int(x), pcm.count - 1), i1 = min(i0 + 1, pcm.count - 1)
                let frac = x - Double(i0)
                samples.append(Int16(Double(pcm[i0]) * (1 - frac) + Double(pcm[i1]) * frac))
            }
            nextTime = t + duration
            if out == nil, Double(samples.count) >= format.sampleRate { out = flush() }
            return out
        }

        mutating func flush() -> AnalyzerInput? {
            guard !samples.isEmpty,
                  let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let dst = buf.int16ChannelData?[0] else { samples = []; return nil }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: samples.count) }
            let input = AnalyzerInput(buffer: buf, bufferStartTime: CMTime(seconds: startTime, preferredTimescale: 16000))
            lastEnd = startTime + Double(samples.count) / format.sampleRate
            startTime = lastEnd
            samples = []
            return input
        }
    }

    final class LineCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func set(_ v: Int) { lock.withLock { n = v } }
        var value: Int { lock.withLock { n } }
    }
}

/// 逐字稿摘要：Apple Intelligence 裝置端模型（FoundationModels）
public enum TranscriptSummarizer {
    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// 不可用的原因（顯示給使用者）
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "請在系統設定開啟 Apple Intelligence"
        case .unavailable(.deviceNotEligible): return "這台裝置不支援 Apple Intelligence"
        case .unavailable(.modelNotReady): return "Apple Intelligence 模型尚未下載完成"
        default: return "Apple Intelligence 目前無法使用"
        }
    }

    static let instructions = """
        你是協助整理監視器錄音逐字稿的助理。逐字稿由語音辨識產生，可能有錯字或聽不清楚的片段。
        請用繁體中文、條列式整理重點：發生了什麼事、提到的人事物、時間點。不要編造逐字稿中沒有的內容。
        """

    /// 逐字稿太長時分段摘要再合併（裝置端模型的上下文有限）
    public static func summarize(_ lines: [RecordingTranscriber.Line]) async throws -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let rows = lines.map { "\(f.string(from: $0.start)) \($0.text)" }
        var chunks: [String] = [], cur = ""
        for r in rows {
            if cur.count + r.count > 2000, !cur.isEmpty { chunks.append(cur); cur = "" }
            cur += r + "\n"
        }
        if !cur.isEmpty { chunks.append(cur) }
        guard !chunks.isEmpty else { return "" }
        var parts: [String] = []
        for c in chunks {
            let s = LanguageModelSession(instructions: instructions)
            parts.append(try await s.respond(to: "以下是逐字稿（每行開頭為時間）：\n\(c)\n請整理重點。").content)
        }
        if parts.count == 1 { return parts[0] }
        let s = LanguageModelSession(instructions: instructions)
        let merged = parts.joined(separator: "\n\n").prefix(3000)
        return try await s.respond(to: "以下是同一段錄影各部分的重點，請合併成一份精簡的條列摘要：\n\(merged)").content
    }
}
