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
            let s = LanguageModelSession(model: TranscriptPolisher.model, instructions: instructions)
            parts.append(try await s.respond(to: "以下是逐字稿（每行開頭為時間）：\n\(c)\n請整理重點。").content)
        }
        if parts.count == 1 { return parts[0] }
        let s = LanguageModelSession(model: TranscriptPolisher.model, instructions: instructions)
        let merged = parts.joined(separator: "\n\n").prefix(3000)
        return try await s.respond(to: "以下是同一段錄影各部分的重點，請合併成一份精簡的條列摘要：\n\(merged)").content
    }
}

/// 逐字稿潤飾（參考用）：Apple Intelligence 依上下文修正同音錯字、補標點。
/// 一句對一句（保留每句的時間），模型漏回或回錯的句子保留原文。原始辨識結果不會被取代。
public enum TranscriptPolisher {
    static let instructions = """
        你負責校對監視器錄音的語音辨識逐字稿（繁體中文）。辨識結果常有同音或近音錯字、缺少標點。
        規則：只修正明顯的錯字並補上標點；不要改寫句意、不要增加或刪除內容、不要合併或拆開句子；
        聽不懂或不確定的句子保持原樣。每一句都要回傳，格式為「編號｜句子」，一句一行，不要其他說明。
        """

    /// 每批句數（裝置端模型上下文有限）
    static let batchSize = 30
    /// 最近一次潤飾失敗的批次與原因（驗證用，不含內容）
    nonisolated(unsafe) public static var lastFailures: [String] = []

    /// 轉換使用者自己的文字（校對、摘要）用寬鬆的內容過濾；預設過濾會把日常對話誤判為敏感內容
    static var model: SystemLanguageModel { SystemLanguageModel(guardrails: .permissiveContentTransformations) }

    /// 回傳與 lines 一一對應的潤飾文字（順序相同）
    public static func polish(_ lines: [RecordingTranscriber.Line],
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [String] {
        var out = lines.map(\.text)
        var failures: [String] = []
        defer { lastFailures = failures }
        var i = 0
        while i < lines.count {
            try Task.checkCancellation()
            let range = i..<min(i + batchSize, lines.count)
            try await polishBatch(Array(range), lines: lines, into: &out, failures: &failures)
            i += batchSize
            progress(min(Double(i) / Double(lines.count), 1))
        }
        return out
    }

    /// 一批失敗時拆成兩半重試（找出觸發過濾的少數句子，其餘照常潤飾）
    static func polishBatch(_ idx: [Int], lines: [RecordingTranscriber.Line],
                            into out: inout [String], failures: inout [String]) async throws {
        guard !idx.isEmpty else { return }
        let input = idx.enumerated().map { "\($0.offset + 1)｜\(lines[$0.element].text)" }.joined(separator: "\n")
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let r = try await session.respond(to: "請校對以下 \(idx.count) 句：\n\(input)")
            for row in r.content.split(whereSeparator: \.isNewline) {
                let parts = row.split(separator: "｜", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      let n = Int(parts[0].trimmingCharacters(in: .whitespaces).filter(\.isNumber)),
                      (1...idx.count).contains(n) else { continue }
                let t = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let original = lines[idx[n - 1]].text
                // 防護：空白、或長度變化過大（可能改寫或補了內容）就保留原文
                if !t.isEmpty, Double(t.count) <= Double(original.count) * 1.5 + 4, Double(t.count) >= Double(original.count) * 0.5 {
                    out[idx[n - 1]] = t
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if idx.count > 3 {
                let mid = idx.count / 2
                try await polishBatch(Array(idx[..<mid]), lines: lines, into: &out, failures: &failures)
                try await polishBatch(Array(idx[mid...]), lines: lines, into: &out, failures: &failures)
            } else {
                failures.append("\(idx.count) 句保留原文：\(error)")
            }
        }
    }
}
