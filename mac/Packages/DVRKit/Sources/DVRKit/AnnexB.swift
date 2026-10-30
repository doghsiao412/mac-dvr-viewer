import Foundation

/// H.264 / H.265 Annex-B（00 00 01 / 00 00 00 01 start code）分析工具
public enum VideoCodec: String, Sendable {
    case h264 = "H.264/AVC"
    case h265 = "H.265/HEVC"
}

public struct AnnexBReport: Sendable, CustomStringConvertible {
    public var firstStartCodeOffset: Int?
    public var codec: VideoCodec?
    public var nalTypes: [String: Int] = [:]

    public init() {}

    public var description: String {
        let off = firstStartCodeOffset.map(String.init) ?? "無"
        let types = nalTypes.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        return "codec=\(codec?.rawValue ?? "未知") 首個 start code 偏移=\(off) NAL=[\(types)]"
    }
}

public enum AnnexB {
    /// 回傳每個 NAL 起點（start code 之後的位置）
    public static func nalStarts(_ d: Data, limit: Int = 4096) -> [Int] {
        var out: [Int] = []
        let b = [UInt8](d)
        var i = 0
        while i + 3 < b.count, out.count < limit {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                out.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        return out
    }

    public static func analyze(_ d: Data) -> AnnexBReport {
        var r = AnnexBReport()
        let b = [UInt8](d)
        let starts = nalStarts(d)
        guard let first = starts.first else { return r }
        // 起點前若是 00 00 00 01，偏移以 4 bytes start code 計
        r.firstStartCodeOffset = first >= 4 && b[first - 4] == 0 ? first - 4 : first - 3
        var h264 = [Int: Int](), h265 = [Int: Int]()
        for s in starts where s < b.count {
            let x = b[s]
            guard x & 0x80 == 0 else { continue }
            h264[Int(x & 0x1F), default: 0] += 1
            h265[Int((x >> 1) & 0x3F), default: 0] += 1
        }
        let s264 = (h264[7] ?? 0) + (h264[8] ?? 0) + (h264[5] ?? 0)
        let s265 = (h265[32] ?? 0) + (h265[33] ?? 0) + (h265[34] ?? 0)
        if s265 > 0, (h265[32] ?? 0) > 0, s265 >= s264 {
            r.codec = .h265
            let names = [1: "TRAIL_R", 0: "TRAIL_N", 19: "IDR_W_RADL", 20: "IDR_N_LP", 21: "CRA",
                         32: "VPS", 33: "SPS", 34: "PPS", 35: "AUD", 39: "SEI"]
            for (k, v) in h265 { r.nalTypes[names[k] ?? "\(k)", default: 0] += v }
        } else if s264 > 0 {
            r.codec = .h264
            let names = [1: "slice", 5: "IDR", 6: "SEI", 7: "SPS", 8: "PPS", 9: "AUD"]
            for (k, v) in h264 { r.nalTypes[names[k] ?? "\(k)", default: 0] += v }
        }
        return r
    }

    public static func hexRow(_ d: Data, count: Int = 32) -> String {
        let bytes = [UInt8](d.prefix(count))
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        let asc = String(bytes.map { (32..<127).contains($0) ? Character(UnicodeScalar($0)) : "." })
        return "\(hex)  |\(asc)|"
    }
}
