import Foundation
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
}
