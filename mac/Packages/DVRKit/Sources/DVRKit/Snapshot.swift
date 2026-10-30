import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Snapshot {
    /// 把解碼後的 CVPixelBuffer 存成 JPEG（截圖功能也會用到）
    public static func writeJPEG(_ pb: CVPixelBuffer, to url: URL, quality: Double = 0.85) throws {
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// 亮度（Y 平面）統計：用來在不看畫面內容的情況下判斷解碼是否正常
    /// （全灰/全綠/全黑 → 標準差極低）
    public struct LumaStats: Sendable, CustomStringConvertible {
        public let width: Int, height: Int
        public let mean: Double, stddev: Double, min: UInt8, max: UInt8
        public var looksValid: Bool { stddev > 4 && max > min }
        public var description: String {
            String(format: "%dx%d 亮度平均 %.1f 標準差 %.1f 範圍 %d–%d", width, height, mean, stddev, min, max)
        }
    }

    public static func lumaStats(_ pb: CVPixelBuffer) -> LumaStats? {
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pb)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, sq = 0.0, n = 0.0
        var lo: UInt8 = 255, hi: UInt8 = 0
        for y in Swift.stride(from: 0, to: h, by: 4) {
            for x in Swift.stride(from: 0, to: w, by: 4) {
                let v = p[y * stride + x]
                let dv = Double(v)
                sum += dv; sq += dv * dv; n += 1
                lo = Swift.min(lo, v); hi = Swift.max(hi, v)
            }
        }
        let mean = sum / n
        return LumaStats(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                         mean: mean, stddev: (sq / n - mean * mean).squareRoot(), min: lo, max: hi)
    }
}
