import DVRKit
import SwiftUI

/// 錄影時間軸的繪製與顏色（Mac 與 iPhone 共用；互動各平台自己處理）
enum TimelineStyle {
    /// 播放位置的顏色：固定深紅（系統 .red 疊在玻璃面板上會被淡化成粉紅，白字不易閱讀）
    static let playhead = Color(red: 0.78, green: 0.08, blue: 0.10)
    /// 下載範圍標記的顏色（避開排程藍、移動橘、播放紅）
    static let markColor = Color(red: 0.98, green: 0.78, blue: 0.10)
    /// 1 = 顯示 24 小時；1440 = 顯示 1 分鐘
    static let zoomRange: ClosedRange<Double> = 1...1440

    static func color(_ type: String) -> Color {
        switch type.uppercased() {
        case "SCHEDULE": return .blue
        case "MOTION": return .orange
        case "SENSOR": return .red
        case "MANUAL": return .green
        default: return .purple
        }
    }

    static func typeName(_ t: String) -> String {
        switch t.uppercased() {
        case "SCHEDULE": return "排程"
        case "MOTION": return "移動偵測"
        case "SENSOR": return "感應器"
        case "MANUAL": return "手動"
        case "INTELLIGENT": return "智慧偵測"
        case "POS": return "POS"
        default: return t
        }
    }

    /// 畫出時間條：start 為左緣時間，span 為可視秒數
    static func draw(_ ctx: GraphicsContext, size: CGSize, start: Date, span: TimeInterval, day: Date,
                     ranges: [DVRConnection.RecordRange], markers: [Date] = [], markIn: Date? = nil, markOut: Date? = nil) {
        let w = size.width, h = size.height
        let x: (Date) -> CGFloat = { CGFloat($0.timeIntervalSince(start) / span) * w }
        let barTop: CGFloat = 16

        // 當日範圍背景；範圍外較暗
        let dayA = max(x(day), 0), dayB = min(x(day.addingTimeInterval(86400)), w)
        ctx.fill(Path(CGRect(x: 0, y: barTop, width: w, height: h - barTop)), with: .color(.black.opacity(0.15)))
        if dayB > dayA {
            ctx.fill(Path(CGRect(x: dayA, y: barTop, width: dayB - dayA, height: h - barTop)),
                     with: .color(.secondary.opacity(0.14)))
        }

        // 錄影區段
        for r in ranges {
            let a = max(x(r.start), 0), b = min(x(r.end), w)
            guard b > a else { continue }
            ctx.fill(Path(CGRect(x: a, y: barTop + 4, width: max(b - a, 1), height: h - barTop - 8)),
                     with: .color(color(r.type).opacity(0.8)))
        }

        // 事件標記：時間條上方的小三角形
        for d in markers {
            let px = x(d)
            guard px >= 0, px <= w else { continue }
            ctx.fill(Path { p in
                p.move(to: CGPoint(x: px - 3, y: barTop)); p.addLine(to: CGPoint(x: px + 3, y: barTop))
                p.addLine(to: CGPoint(x: px, y: barTop + 5)); p.closeSubpath()
            }, with: .color(.orange))
        }

        // 下載範圍標記
        if let a0 = markIn ?? markOut {
            let b0 = markOut ?? a0
            let xa = x(min(a0, b0)), xb = x(max(a0, b0))
            if xb > xa {
                ctx.fill(Path(CGRect(x: xa, y: barTop, width: xb - xa, height: h - barTop)),
                         with: .color(markColor.opacity(0.35)))
            }
            for edge in [markIn, markOut].compactMap({ $0 }) {
                let px = x(edge)
                guard px >= -2, px <= w + 2 else { continue }
                ctx.fill(Path(CGRect(x: px - 1, y: barTop - 2, width: 2, height: h - barTop + 2)), with: .color(markColor))
            }
        }

        // 刻度：依可視範圍自動選擇間距
        let step = tickStep(span: span, width: w)
        let minor = step / 5
        let startSec = start.timeIntervalSince(day)
        var t = (startSec / minor).rounded(.down) * minor
        while t <= startSec + span {
            if t >= 0, t <= 86400 {
                let px = CGFloat((t - startSec) / span) * w
                let major = abs(t.truncatingRemainder(dividingBy: step)) < 0.001
                let top = major ? barTop - 4 : barTop
                ctx.stroke(Path { p in p.move(to: CGPoint(x: px, y: top)); p.addLine(to: CGPoint(x: px, y: major ? h : barTop + 6)) },
                           with: .color(.secondary.opacity(major ? 0.5 : 0.3)), lineWidth: major ? 0.8 : 0.5)
                if major {
                    let label = Text(tickLabel(t, step: step)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    ctx.draw(label, at: CGPoint(x: px, y: 0), anchor: .top)
                }
            }
            t += minor
        }
    }

    static func tickStep(span: TimeInterval, width: CGFloat) -> TimeInterval {
        let candidates: [TimeInterval] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800]
        let maxTicks = max(Double(width) / 70, 2)
        return candidates.first { span / $0 <= maxTicks } ?? 10800
    }

    static func tickLabel(_ secondsOfDay: TimeInterval, step: TimeInterval) -> String {
        let s = Int(secondsOfDay.rounded())
        if step < 60 { return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 3600, (s % 3600) / 60)
    }

    /// 顯示範圍文字（例如「2 小時」「30 分鐘」）
    static func spanText(zoom: Double) -> String {
        let s = 86400 / zoom
        if s >= 3600 { return s.truncatingRemainder(dividingBy: 3600) < 60 ? "\(Int(s / 3600)) 小時" : String(format: "%.1f 小時", s / 3600) }
        if s >= 60 { return "\(Int((s / 60).rounded())) 分鐘" }
        return "\(Int(s)) 秒"
    }
}
