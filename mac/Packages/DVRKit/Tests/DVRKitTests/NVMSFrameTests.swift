import Foundation
import Testing
@testable import DVRKit

/// Mock 測試：依 DVR 網頁 decoder.js 的 readStreamFromBuf 規則合成訊框
struct NVMSFrameTests {
    func makeFrame(first: UInt32, json: String, prefix: Data, media: Data) -> Data {
        let hdr = first == 0 ? 8 : 16
        var d = Data()
        var a = first.littleEndian, l = UInt32(json.utf8.count).littleEndian
        d.append(Data(bytes: &a, count: 4)); d.append(Data(bytes: &l, count: 4))
        if hdr == 16 { d.append(Data(count: 8)) }
        d.append(Data(json.utf8)); d.append(prefix); d.append(media)
        return d
    }

    @Test func parsesLiveFrameWith8ByteHeader() throws {
        let media = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE, 0, 0, 0, 1, 0x65, 0x88])
        let prefix = Data(repeating: 0xAB, count: 12)
        let json = #"{"url":"/device/preview/data","data":{"task_id":"{x}","live_stream_data":"12,\#(media.count)"}}"#
        let f = try #require(try NVMSStream.parseFrame(makeFrame(first: 0, json: json, prefix: prefix, media: media)))
        #expect(f.url == "/device/preview/data")
        #expect(f.payload == media)
        let r = AnnexB.analyze(f.payload)
        #expect(r.codec == .h264)
        #expect(r.firstStartCodeOffset == 0)
    }

    @Test func parsesPlaybackFrameWith16ByteHeader() throws {
        let media = Data([0, 0, 0, 1, 0x40, 0x01, 0, 0, 0, 1, 0x42, 0x01, 0, 0, 0, 1, 0x44, 0x01, 0, 0, 1, 0x26, 0x01])
        let json = #"{"url":"/device/playback/data","data":{"playback_stream_data":"0,\#(media.count)"}}"#
        let f = try #require(try NVMSStream.parseFrame(makeFrame(first: 7, json: json, prefix: Data(), media: media)))
        #expect(f.payload == media)
        #expect(AnnexB.analyze(f.payload).codec == .h265)
    }

    @Test func deviceErrorCodeThrows() {
        let json = #"{"url":"/device/playback/data","data":{"code":536870961}}"#
        #expect(throws: NVMSError.self) { try NVMSStream.parseFrame(makeFrame(first: 0, json: json, prefix: Data(), media: Data())) }
    }
}
