import AVFoundation
import Foundation
import Speech
import Testing
@testable import DVRKit

/// Mock 測試：G.711 聲音分批、升頻與時間對應（不需實體 DVR）
struct TranscriberTests {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!

    @Test func upsamplesAndBatchesPerSecond() {
        var b = RecordingTranscriber.AudioBatch(format: format)
        var out: [AnalyzerInput] = []
        // 8 kHz、每框 40 毫秒（320 bytes），連續 1.2 秒
        for i in 0..<30 {
            if let x = b.append(Data(repeating: 0xD5, count: 320), rate: 8000, at: Double(i) * 0.04) { out.append(x) }
        }
        if let x = b.flush() { out.append(x) }
        #expect(out.count == 2)
        #expect(out[0].buffer.frameLength == 16000)          // 1 秒 × 16 kHz
        #expect(out[0].bufferStartTime?.seconds == 0)
        #expect(abs((out[1].bufferStartTime?.seconds ?? -1) - 1.0) < 0.001)
        #expect(out.reduce(0) { $0 + Int($1.buffer.frameLength) } == 30 * 640)
    }

    @Test func gapStartsNewBatchWithRecordingTime() {
        var b = RecordingTranscriber.AudioBatch(format: format)
        var out: [AnalyzerInput] = []
        for i in 0..<5 { if let x = b.append(Data(count: 320), rate: 8000, at: Double(i) * 0.04) { out.append(x) } }
        // 錄影空檔 30 秒後繼續
        for i in 0..<5 { if let x = b.append(Data(count: 320), rate: 8000, at: 30 + Double(i) * 0.04) { out.append(x) } }
        if let x = b.flush() { out.append(x) }
        #expect(out.count == 2)
        #expect(out[0].bufferStartTime?.seconds == 0)
        #expect(abs((out[1].bufferStartTime?.seconds ?? -1) - 30) < 0.001)
    }

    /// DVR 訊框時間有誤差（比累加的結尾早）：下一批起點不可早於上一批結尾
    @Test func batchesNeverOverlap() {
        var b = RecordingTranscriber.AudioBatch(format: format)
        var out: [AnalyzerInput] = []
        // 每框實際 40 毫秒，但時間戳只前進 38 毫秒（模擬誤差）
        for i in 0..<100 { if let x = b.append(Data(count: 320), rate: 8000, at: Double(i) * 0.038) { out.append(x) } }
        if let x = b.flush() { out.append(x) }
        var end = -1.0
        for x in out {
            let s = x.bufferStartTime!.seconds
            #expect(s >= end - 0.0001)
            end = s + Double(x.buffer.frameLength) / 16000
        }
    }
}
