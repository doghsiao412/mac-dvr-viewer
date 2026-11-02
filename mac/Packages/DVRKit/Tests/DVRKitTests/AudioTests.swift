import Foundation
import Testing
@testable import DVRKit

/// Mock 測試：G.711 解碼與 SHFL 聲音訊框解析（依實測標頭格式合成）
struct AudioTests {
    @Test func alawKnownValues() {
        #expect(G711.alaw(0xD5) == 8)       // A-law 靜音（正）
        #expect(G711.alaw(0x55) == -8)      // A-law 靜音（負）
        #expect(G711.alaw(0xAA) == 32256)   // 最大正值
        #expect(G711.alaw(0x2A) == -32256)  // 最大負值
    }

    @Test func ulawKnownValues() {
        #expect(G711.ulaw(0xFF) == 0)
        #expect(G711.ulaw(0x7F) == 0)
        #expect(G711.ulaw(0x80) == 32124)
        #expect(G711.ulaw(0x00) == -32124)
    }

    @Test func aLawToneDoesNotChangePlaybackEncoding() {
        // 正常的 180 Hz A-law 音訊也含 FF/7F；舊統計法第 91 框會誤判 μ-law。
        let codebook = (0...255).map { UInt8($0) }
        let cycle = (0..<400).map { i -> UInt8 in
            let sample = 850 * sin(2 * Double.pi * 180 * Double(i) / 8000)
            return codebook.min { abs(Double(G711.alaw($0)) - sample) < abs(Double(G711.alaw($1)) - sample) }!
        }
        let player = AudioPlayer()  // 不啟動音訊裝置
        var aLawVotes = 0, muLawVotes = 0
        for frame in 0..<91 {
            for i in 0..<320 {
                let byte = cycle[(frame * 320 + i) % cycle.count]
                if i < 64 {
                    if byte == 0xD5 || byte == 0x55 { aLawVotes += 1 }
                    if byte == 0xFF || byte == 0x7F { muLawVotes += 1 }
                }
                let sample = player.encoding.decode(byte)
                #expect(sample == Float(G711.alaw(byte)) / 32768)
                #expect(abs(sample) < 0.027)
            }
        }
        #expect(aLawVotes + muLawVotes > 800)
        #expect(muLawVotes > aLawVotes)
        #expect(player.encoding == .aLaw)
        #expect(AudioPlayer.Encoding.muLaw.decode(0xFF) == 0)
        #expect(AudioPlayer.Encoding.aLaw.decode(0xFF) == Float(848) / 32768)
    }

    @Test func parsesAudioFrame() throws {
        // 依 8083 實測：03 01 06 01 | ... | extLen 12 | 長度 320 | 延伸區 00 01 01 00 10 00 80 3e 40 1f 00 00
        var d = Data("SHFL".utf8) + Data([3, 1, 6, 1]) + Data([1, 0, 0, 0]) + Data(count: 12)
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let samples = Data(repeating: 0xD5, count: 320)
        d += u32(UInt32(24 + 12 + 320)) + u64(134_064_000_000_000_000) + u32(1) + u32(0)
        d += Data([1, 12, 0, 0]) + u32(320) + u64(0) + u64(0)
        d += Data([0, 1, 1, 0, 0x10, 0, 0x80, 0x3E, 0x40, 0x1F, 0, 0]) + samples
        let f = try #require(SHFLFrame.parse(d))
        #expect(f.isAudio)
        #expect(f.audioSampleRate == 8000)
        #expect(f.videoData == samples)
    }
}
