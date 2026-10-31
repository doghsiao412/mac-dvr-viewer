import AppKit
import DVRKit
import SwiftUI

/// 錄影時間軸（拖曳式）
///
/// - 播放位置固定在正中央的紅線；播放時時間條自動捲動
/// - 拖曳時間條：放開後跳到紅線所指時間
/// - 觸控板左右滑動：平移，停止約 0.35 秒後跳轉
/// - 縮放（調整精度）：觸控板捏合、滑鼠滾輪／上下滑動、外部按鈕；範圍 24 小時 → 1 分鐘
/// - 單擊：直接跳到點擊位置的時間
/// - 按住 Shift 拖曳：標記下載範圍（起點／終點）
struct RecordTimeline: View {
    static let playhead = TimelineStyle.playhead
    static let markColor = TimelineStyle.markColor

    let day: Date                       // 當日 00:00（本地時間）
    let ranges: [DVRConnection.RecordRange]
    let current: Date?
    @Binding var zoom: Double           // 1 = 顯示 24 小時；1440 = 顯示 1 分鐘
    /// 下載範圍標記
    var markIn: Date? = nil
    var markOut: Date? = nil
    /// 事件標記（例如系統日誌的移動偵測時間）
    var markers: [Date] = []
    /// Shift＋拖曳選取範圍
    var onSelect: ((Date, Date) -> Void)? = nil
    var onSeek: (Date) -> Void

    static let zoomRange = TimelineStyle.zoomRange

    /// 互動中（拖曳／滑動）時的中心時間；nil 表示跟隨播放位置
    @State private var interactiveCenter: Date?
    @State private var dragBase: Date?
    @State private var scrollSeekTask: Task<Void, Never>?
    /// Shift 拖曳選取時，按下時的時間軸起點（拖曳中時間軸不跟著播放捲動）
    @State private var selectStart: Date?

    private var span: TimeInterval { 86400 / zoom }

    private var center: Date {
        clamp(interactiveCenter ?? current ?? day.addingTimeInterval(43200))
    }

    static func color(_ type: String) -> Color { TimelineStyle.color(type) }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let c = center
            let start = selectStart ?? c.addingTimeInterval(-span / 2)
            let secPerPt = span / Double(w)
            ZStack(alignment: .top) {
                Canvas { ctx, size in draw(ctx, size: size, start: start) }

                // 中央播放位置
                VStack(spacing: 0) {
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Self.playhead)
                    Rectangle().fill(Self.playhead).frame(width: 2)
                }
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)

                // 互動時顯示目標時間
                if interactiveCenter != nil {
                    Text(c, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit().weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Self.playhead, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(y: -18)
                        .allowsHitTesting(false)
                }

                TimelineEventCatcher(
                    onDragBegan: { dragBase = center },
                    onDrag: { dx in
                        guard let base = dragBase else { return }
                        interactiveCenter = clamp(base.addingTimeInterval(-Double(dx) * secPerPt))
                    },
                    onDragEnded: {
                        dragBase = nil
                        commitSeek()
                    },
                    onClick: { x in
                        let t = clamp(start.addingTimeInterval(Double(x) * secPerPt))
                        interactiveCenter = nil
                        onSeek(t)
                    },
                    onSelectBegan: { selectStart = start },
                    onSelect: { x0, x1 in
                        guard let base = selectStart else { return }
                        let a = clamp(base.addingTimeInterval(Double(x0) * secPerPt))
                        let b = clamp(base.addingTimeInterval(Double(x1) * secPerPt))
                        onSelect?(min(a, b), max(a, b))
                    },
                    onSelectEnded: { selectStart = nil },
                    onScroll: { dx, dy, precise in handleScroll(dx: dx, dy: dy, precise: precise, secPerPt: secPerPt) },
                    onMagnify: { m in setZoom(zoom * (1 + Double(m))) }
                )
            }
        }
        .frame(height: 60)
        .padding(.top, 14)  // 給時間標籤空間
        .help("拖曳時間條選擇時間；捏合或滾輪縮放；按住 Shift 拖曳標記下載範圍")
    }

    // MARK: - 互動

    private func commitSeek() {
        scrollSeekTask?.cancel()
        guard let t = interactiveCenter else { return }
        interactiveCenter = nil
        onSeek(t)
    }

    private func handleScroll(dx: CGFloat, dy: CGFloat, precise: Bool, secPerPt: Double) {
        if abs(dx) > abs(dy) {
            // 左右滑動：平移
            let base = interactiveCenter ?? center
            interactiveCenter = clamp(base.addingTimeInterval(-Double(dx) * secPerPt))
            scrollSeekTask?.cancel()
            scrollSeekTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, dragBase == nil else { return }
                commitSeek()
            }
        } else if dy != 0 {
            // 上下：縮放（往上 = 放大）
            let factor = precise ? exp(Double(dy) * 0.01) : (dy > 0 ? 1.2 : 1 / 1.2)
            setZoom(zoom * factor)
        }
    }

    private func setZoom(_ z: Double) {
        zoom = min(max(z, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    private func clamp(_ d: Date) -> Date { min(max(d, day), day.addingTimeInterval(86399)) }

    // MARK: - 繪製

    private func draw(_ ctx: GraphicsContext, size: CGSize, start: Date) {
        TimelineStyle.draw(ctx, size: size, start: start, span: span, day: day, ranges: ranges,
                           markers: markers, markIn: markIn, markOut: markOut)
    }

    static func spanText(zoom: Double) -> String { TimelineStyle.spanText(zoom: zoom) }
}

/// 透明的 AppKit 事件層：拖曳、單擊、滾輪／觸控板滑動、捏合
struct TimelineEventCatcher: NSViewRepresentable {
    var onDragBegan: () -> Void
    var onDrag: (CGFloat) -> Void
    var onDragEnded: () -> Void
    var onClick: (CGFloat) -> Void
    var onSelectBegan: () -> Void = {}
    var onSelect: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onSelectEnded: () -> Void = {}
    var onScroll: (CGFloat, CGFloat, Bool) -> Void
    var onMagnify: (CGFloat) -> Void

    func makeNSView(context: Context) -> EventView { EventView() }

    func updateNSView(_ v: EventView, context: Context) {
        v.onDragBegan = onDragBegan
        v.onDrag = onDrag
        v.onDragEnded = onDragEnded
        v.onClick = onClick
        v.onSelectBegan = onSelectBegan
        v.onSelect = onSelect
        v.onSelectEnded = onSelectEnded
        v.onScroll = onScroll
        v.onMagnify = onMagnify
    }

    final class EventView: NSView {
        var onDragBegan: () -> Void = {}
        var onDrag: (CGFloat) -> Void = { _ in }
        var onDragEnded: () -> Void = {}
        var onClick: (CGFloat) -> Void = { _ in }
        var onSelectBegan: () -> Void = {}
        var onSelect: (CGFloat, CGFloat) -> Void = { _, _ in }
        var onSelectEnded: () -> Void = {}
        var onScroll: (CGFloat, CGFloat, Bool) -> Void = { _, _, _ in }
        var onMagnify: (CGFloat) -> Void = { _ in }

        private var downX: CGFloat = 0
        private var dragging = false
        /// Shift＋拖曳：選取範圍
        private var selecting = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with e: NSEvent) {
            downX = convert(e.locationInWindow, from: nil).x
            dragging = false
            selecting = e.modifierFlags.contains(.shift)
            if selecting { onSelectBegan() }
        }

        override func mouseDragged(with e: NSEvent) {
            if selecting {
                onSelect(downX, convert(e.locationInWindow, from: nil).x)
                return
            }
            let dx = convert(e.locationInWindow, from: nil).x - downX
            if !dragging, abs(dx) > 3 {
                dragging = true
                NSCursor.closedHand.push()
                onDragBegan()
            }
            if dragging { onDrag(dx) }
        }

        override func mouseUp(with e: NSEvent) {
            if selecting {
                selecting = false
                onSelectEnded()
                return
            }
            if dragging {
                dragging = false
                NSCursor.pop()
                onDragEnded()
            } else {
                onClick(convert(e.locationInWindow, from: nil).x)
            }
        }

        override func scrollWheel(with e: NSEvent) {
            onScroll(e.scrollingDeltaX, e.scrollingDeltaY, e.hasPreciseScrollingDeltas)
        }

        override func magnify(with e: NSEvent) {
            onMagnify(e.magnification)
        }
    }
}
