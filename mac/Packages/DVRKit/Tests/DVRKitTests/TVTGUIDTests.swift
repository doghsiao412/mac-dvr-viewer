import Foundation
import Testing
@testable import DVRKit

/// 以封包中實際觀察到的對應驗證 GUID 位元組排列（Windows GUID，前三段 little-endian）
struct TVTGUIDTests {
    @Test func matchesCapturedLayout() throws {
        let s = "{B9748EC7-0C1A-6A46-A647-BF55FABEAEC3}"
        let d = try #require(TVTGUID.bytes(s))
        #expect(d == Data([0xC7, 0x8E, 0x74, 0xB9, 0x1A, 0x0C, 0x46, 0x6A, 0xA6, 0x47, 0xBF, 0x55, 0xFA, 0xBE, 0xAE, 0xC3]))
        #expect(TVTGUID.string(d) == s)
    }

    @Test func channelGUID() throws {
        let d = try #require(TVTGUID.bytes("{00000001-0000-0000-0000-000000000000}"))
        #expect(d == Data([1] + Array(repeating: 0, count: 15)))
    }

    @Test func rejectsMalformed() {
        #expect(TVTGUID.bytes("not-a-guid") == nil)
    }
}
