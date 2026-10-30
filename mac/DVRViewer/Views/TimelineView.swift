import DVRKit
import SwiftUI

/// 24 小時錄影時間軸：顯示錄影區段、目前時間，點擊或拖曳跳轉；可縮放
struct RecordTimeline: View {
    let day: Date                       // 當日 00:00（本地時間）
    let ranges: [DVRConnection.RecordRange]
    let current: Date?
    @Binding var zoom: Double           // 1 = 24 小時，2 = 12 小時 …
    var onSeek: (Date) -> Void

    @State private var dragTime: Date?

    private var windowLength: TimeInterval { 86400 / zoom }

    /// 可視範圍：以目前時間為中心，限制在當日內
    private var windowStart: Date {
        let center = dragTime ?? current ?? day.addingTimeInterval(43200)
        var s = center.addingTimeInterval(-windowLength / 2)
        s = max(s, day)
        s = min(s, day.addingTimeInterval(86400 - windowLength))
        return s
    }

    static func color(_ type: String) -> Color {
        switch type.uppercased() {
        case "SCHEDULE": return .blue
        case "MOTION": return .orange
        case "SENSOR": return .red
        case "MANUAL": return .green
        default: return .purple
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let start = windowStart
            let x: (Date) -> CGFloat = { CGFloat($0.timeIntervalSince(start) / windowLength) * w }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // 背景
                    ctx.fill(Path(CGRect(x: 0, y: 18, width: size.width, height: size.height - 18)),
                             with: .color(.secondary.opacity(0.12)))
                    // 錄影區段
                    for r in ranges {
                        let a = max(x(r.start), 0), b = min(x(r.end), size.width)
                        guard b > a else { continue }
                        ctx.fill(Path(CGRect(x: a, y: 22, width: max(b - a, 1), height: size.height - 26)),
                                 with: .color(Self.color(r.type).opacity(0.75)))
                    }
                    // 刻度
                    let step = tickStep()
                    var t = (start.timeIntervalSince(day) / step).rounded(.down) * step
                    while t <= start.timeIntervalSince(day) + windowLength {
                        let d = day.addingTimeInterval(t)
                        let px = x(d)
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: px, y: 14)); p.addLine(to: CGPoint(x: px, y: size.height)) },
                                   with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
                        let label = Text(Self.tickLabel(t)).font(.system(size: 9)).foregroundStyle(.secondary)
                        ctx.draw(label, at: CGPoint(x: px + 2, y: 1), anchor: .topLeading)
                        t += step
                    }
                    // 目前時間
                    if let c = dragTime ?? current {
                        let px = x(c)
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: px, y: 12)); p.addLine(to: CGPoint(x: px, y: size.height)) },
                                   with: .color(.red), lineWidth: 2)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in dragTime = clamp(start.addingTimeInterval(Double(v.location.x / w) * windowLength)) }
                    .onEnded { v in
                        let t = clamp(start.addingTimeInterval(Double(v.location.x / w) * windowLength))
                        dragTime = nil
                        onSeek(t)
                    }
            )
            .overlay(alignment: .topTrailing) {
                if let d = dragTime {
                    Text(d, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .frame(height: 56)
    }

    private func clamp(_ d: Date) -> Date { min(max(d, day), day.addingTimeInterval(86399)) }

    private func tickStep() -> TimeInterval {
        switch windowLength {
        case ..<1800: return 120
        case ..<7200.0: return 600
        case ..<21600.0: return 1800
        case ..<43200.0: return 3600
        default: return 7200
        }
    }

    static func tickLabel(_ secondsOfDay: TimeInterval) -> String {
        let s = Int(secondsOfDay)
        return String(format: "%02d:%02d", s / 3600, (s % 3600) / 60)
    }
}
