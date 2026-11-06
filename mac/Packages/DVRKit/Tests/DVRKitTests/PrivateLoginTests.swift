import Foundation
import CommonCrypto
import Testing
@testable import DVRKit

/// Mock 測試：私有協定加密登入（演算法讀自原廠 SDK；期望值由 Python hashlib 獨立計算；假密碼）
struct PrivateLoginTests {
    static func head(flag: UInt8, nonce: [UInt8]) -> Data {
        var h = Data(count: 64)
        h.replaceSubrange(0..<4, with: Array("head".utf8))
        h[0x2C] = flag
        h.replaceSubrange(0x2D..<0x30, with: nonce)
        return h
    }

    @Test func plainWhenNoFlag() {
        let p = TVTPrivateClient.loginPayload(user: "admin", password: "123456", greeting: Self.head(flag: 0, nonce: [1, 2, 3]), random: 7)
        #expect(p.count == 236)
        #expect(p.cString(at: 36, max: 64) == "admin")
        #expect(p.cString(at: 100, max: 64) == "123456")
        #expect(p.u32(at: 204) == 0)
        // 沒收到 head（舊韌體）也用明文
        #expect(TVTPrivateClient.loginPayload(user: "a", password: "b", greeting: nil, random: 7).cString(at: 100, max: 64) == "b")
    }

    @Test func encryptedPasswordAndUser() {
        let g = Self.head(flag: 2, nonce: [0x39, 0x1C, 0xA8])
        #expect(TVTPrivateClient.headNonce(g) == 11_017_273)
        let p = TVTPrivateClient.loginPayload(user: "admin", password: "123456", greeting: g, random: 1234)
        let pw = p[p.startIndex + 100 ..< p.startIndex + 120].map { String(format: "%02x", $0) }.joined()
        #expect(pw == "d28692a0797f8c8e2b930791c4ccb5dbbcb46bf4")
        #expect(p[p.startIndex + 120 ..< p.startIndex + 164].allSatisfy { $0 == 0 })
        let user = p[p.startIndex + 36 ..< p.startIndex + 41].map { String(format: "%02x", $0) }.joined()
        #expect(user == "50555d5859")
        #expect(p[p.startIndex + 41] == 0)
        #expect(p.u32(at: 204) == 1234)
    }

    @Test func nonceIsZeroPaddedToEightDigits() {
        let p = TVTPrivateClient.loginPayload(user: "admin", password: "123456", greeting: Self.head(flag: 1, nonce: [5, 0, 0]), random: 0)
        let pw = p[p.startIndex + 100 ..< p.startIndex + 120].map { String(format: "%02x", $0) }.joined()
        #expect(pw == "8daabd35b15af71243b4a9b74406adeddd090150")
        #expect(p.cString(at: 36, max: 64) == "admin")   // 旗標沒有 0x02：帳號不混淆
    }

    @Test func replyTypeNormalized() {
        #expect(TVTPrivateClient.normalizedCmd(0x0100_000A) == 0x0100_0006)   // 實測：加密韌體的登入回覆
        #expect(TVTPrivateClient.normalizedCmd(0x0100_0006) == 0x0100_0006)
        #expect(TVTPrivateClient.normalizedCmd(0x0002_000A) == 0x0002_0006)
        #expect(TVTPrivateClient.normalizedCmd(0x0100_0003) == 0x0100_0003)
    }

    /// 依實測結構合成：SHFL 標頭 68 + 延伸區 44，影像資料開頭 128 bytes 以 AES-128-ECB 加密
    @Test func keyframeDecrypted() {
        let key = Data((0..<16).map { UInt8($0 * 7 &+ 3) })
        var plain = Data([0, 0, 0, 1, 0x40, 0x01]) + Data((0..<250).map { UInt8($0 & 0xFF) })
        var frame = Data("SHFL".utf8) + Data(count: 108)
        frame[7] = 1; frame[45] = 44
        var enc = Data(count: 128); var moved = 0
        let head = plain.prefix(128)
        _ = enc.withUnsafeMutableBytes { o in head.withUnsafeBytes { i in key.withUnsafeBytes { k in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    k.baseAddress, 16, nil, i.baseAddress, 128, o.baseAddress, 128, &moved) } } }
        let encryptedFrame = frame + enc + plain.dropFirst(128)
        let out = TVTPrivateClient.decryptKeyframe(encryptedFrame, key: key)
        #expect(out.suffix(from: 112) == plain)
        // 未加密（已有起始碼）與非關鍵幀：原樣
        let clear = frame + plain
        #expect(TVTPrivateClient.decryptKeyframe(clear, key: key) == clear)
        var pframe = encryptedFrame; pframe[7] = 0
        #expect(TVTPrivateClient.decryptKeyframe(pframe, key: key) == pframe)
        // 金鑰錯誤：解不出起始碼就原樣傳回
        #expect(TVTPrivateClient.decryptKeyframe(encryptedFrame, key: Data(count: 16)) == encryptedFrame)
        plain.removeAll()
    }
}
