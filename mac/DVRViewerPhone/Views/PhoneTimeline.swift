import DVRKit
import SwiftUI

/// iPhone 錄影時間軸
///
/// - 播放位置固定在正中央紅線，播放時時間條自動捲動
/// - 手指左右拖曳：放開後跳到紅線所指時間
/// - 雙指捏合：縮放（24 小時 → 1 分鐘）
/// - 點一下：跳到點擊位置的時間
struct PhoneTimeline: View {
    let day: Date
    let ranges: [DVRConnection.RecordRange]
    let current: Date?
    var markers: [Date] = []
    @Binding var zoom: Double
    var onSeek: (Date) -> Void

    @State private var interactiveCenter: Date?
    @State private var dragBase: Date?
    @State private var zoomBase: Double?

    private var span: TimeInterval { 86400 / zoom }
    private var center: Date { clamp(interactiveCenter ?? current ?? day.addingTimeInterval(43200)) }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let c = center
            let start = c.addingTimeInterval(-span / 2)
            let secPerPt = span / Double(w)
            ZStack(alignment: .top) {
                Canvas { ctx, size in
                    TimelineStyle.draw(ctx, size: size, start: start, span: span, day: day, ranges: ranges, markers: markers)
                }
                VStack(spacing: 0) {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10))
                    Rectangle().frame(width: 2)
                }
                .foregroundStyle(TimelineStyle.playhead)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)

                if interactiveCenter != nil {
                    Text(c, format: .dateTime.hour().minute().second())
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(TimelineStyle.playhead, in: .rect(cornerRadius: 6))
                        .foregroundStyle(.white)
                        .offset(y: -26)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        if dragBase == nil { dragBase = center }
                        guard let base = dragBase else { return }
                        interactiveCenter = clamp(base.addingTimeInterval(-Double(v.translation.width) * secPerPt))
                    }
                    .onEnded { _ in
                        dragBase = nil
                        commitSeek()
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        if zoomBase == nil { zoomBase = zoom }
                        zoom = min(max((zoomBase ?? zoom) * v.magnification, TimelineStyle.zoomRange.lowerBound),
                                   TimelineStyle.zoomRange.upperBound)
                    }
                    .onEnded { _ in zoomBase = nil }
            )
            .onTapGesture { p in
                let t = clamp(start.addingTimeInterval(Double(p.x) * secPerPt))
                interactiveCenter = nil
                onSeek(t)
            }
        }
        .frame(height: 64)
        .padding(.top, 16)
    }

    private func commitSeek() {
        guard let t = interactiveCenter else { return }
        interactiveCenter = nil
        onSeek(t)
    }

    private func clamp(_ d: Date) -> Date { min(max(d, day), day.addingTimeInterval(86399)) }
}
