import Foundation

/// TVT NVMS-9000 WebSocket 媒體訊框（開頭 "SHFL"）。格式由實體 DVR 資料推得，見 docs/protocol-analysis.md §0.2。
///
/// ```
/// 0   "SHFL"
/// 4   u8 ver | u8 ? | u8 ?(即時 2 / 回放 7) | u8 keyframe
/// 24  u32 = 總長 - 44
/// 28  u64 FILETIME（UTC）
/// 36  u32 即時：毫秒計數；回放：訊框序號
/// 44  u8 flags | u8 extLen | u8 | u8
/// 48  u32 影像長度
/// 68  [ext：u32 | fourcc | u16 寬 | u16 高]（關鍵幀，extLen=12）
/// 68+extLen  Annex-B 影像資料
/// ```
public struct SHFLFrame: Sendable {
    public let isKeyframe: Bool
    public let captureTime: Date
    /// FILETIME 原值（100ns since 1601-01-01 UTC），用於精確 PTS
    public let fileTime: UInt64
    public let sequence: UInt32
    public let fourCC: String?
    public let width: Int?
    public let height: Int?
    public let videoData: Data

    static let magic = Data("SHFL".utf8)
    static let headerSize = 68

    public static func parse(_ d: Data) -> SHFLFrame? {
        guard d.count >= headerSize, d.prefix(4) == magic else { return nil }
        let base = d.startIndex
        let keyframe = d[base + 7] == 1
        let ft = UInt64(d.u32le(at: 28)) | UInt64(d.u32le(at: 32)) << 32
        let seq = d.u32le(at: 36)
        let extLen = Int(d[base + 45])
        let videoLen = Int(d.u32le(at: 48))
        var fourCC: String?
        var w: Int?, h: Int?
        if extLen >= 12, d.count >= headerSize + 12 {
            let fcc = d.subdata(in: (base + 72)..<(base + 76))
            fourCC = String(data: fcc, encoding: .ascii)
            w = Int(d[base + 76]) | Int(d[base + 77]) << 8
            h = Int(d[base + 78]) | Int(d[base + 79]) << 8
        }
        let start = headerSize + extLen
        var end = start + videoLen
        if videoLen <= 0 || end > d.count { end = d.count }  // 長度欄位異常時取到結尾
        guard start < end else { return nil }
        let unixSeconds = Double(Int64(ft) - 116_444_736_000_000_000) / 10_000_000
        return SHFLFrame(isKeyframe: keyframe, captureTime: Date(timeIntervalSince1970: unixSeconds),
                         fileTime: ft, sequence: seq, fourCC: fourCC, width: w, height: h,
                         videoData: d.subdata(in: (base + start)..<(base + end)))
    }
}
