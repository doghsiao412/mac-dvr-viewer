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
