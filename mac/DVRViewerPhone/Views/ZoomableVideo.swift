import SwiftUI

/// 可雙指放大的影像（數位縮放，1–8 倍）
///
/// - 雙指捏合：以手指位置為中心放大／縮小
/// - 放大後單指拖曳：平移（不會拖出畫面邊界）
/// - 點兩下：未放大時放大 2.5 倍（以點的位置為中心）；已放大時還原
/// - 左上角顯示倍率，點一下還原
/// - 未放大時左右滑：切換到上一支／下一支攝影機（onSwipe：-1 上一支、+1 下一支）
struct ZoomableVideo: View {
    let renderer: VideoRenderer
    var aspect: VideoAspect = .fit
    var onSwipe: ((Int) -> Void)? = nil

    /// 未放大時左右滑的位移（畫面跟著手指移動一點，放開後彈回）
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeCount = 0
    /// 這次觸控有捏合過（結束時兩指的移動不算左右滑）
    @State private var pinchedThisTouch = false

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    /// 捏合開始時的狀態
    @State private var pinchStart: (zoom: CGFloat, pan: CGSize)?
    /// 拖曳的基準（開始拖曳或捏合結束時重設，避免捏合時兩指的移動造成跳動）
    @State private var dragStart: (pan: CGSize, translation: CGSize)?
    @State private var size: CGSize = .zero

    private static let maxZoom: CGFloat = 8
    private var zoomed: Bool { zoom > 1.01 }

    var body: some View {
        VideoSurface(renderer: renderer, aspect: aspect)
            .scaleEffect(zoom)
            .offset(pan)
            .offset(x: swipeOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(.rect)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .gesture(magnify.simultaneously(with: drag))
            .onTapGesture(count: 2) { p in toggleZoom(at: p) }
            .overlay(alignment: .topLeading) {
                if zoomed {
                    Button { reset() } label: {
                        Label(String(format: "%.1f×", zoom), systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .padding(8)
                    .accessibilityLabel("還原畫面大小")
                    .transition(.opacity)
                }
            }
            .sensoryFeedback(.selection, trigger: swipeCount)
            .accessibilityAction(named: "放大") { setZoom(min(zoom * 2, Self.maxZoom), anchor: center) }
            .accessibilityAction(named: "還原畫面大小") { reset() }
            .accessibilityAction(named: "下一支攝影機") { onSwipe?(1) }
            .accessibilityAction(named: "上一支攝影機") { onSwipe?(-1) }
    }

    private var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    // MARK: - 手勢

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let s = pinchStart ?? (zoom, pan)
                if pinchStart == nil { pinchStart = s }
                dragStart = nil
                pinchedThisTouch = true
                swipeOffset = 0
                let z = min(max(s.zoom * v.magnification, 1), Self.maxZoom)
                // 讓手指下方的那一點維持在原位
                let l = v.startLocation
                let k = 1 - z / s.zoom
                zoom = z
                pan = clamp(CGSize(width: s.pan.width + (l.x - center.x - s.pan.width) * k,
                                   height: s.pan.height + (l.y - center.y - s.pan.height) * k), zoom: z)
            }
            .onEnded { _ in
                pinchStart = nil
                dragStart = nil
                if !zoomed { reset() }
                // 捏合結束後稍等再允許左右滑（兩指放開時的移動不算）；沒觸發拖曳時也要清掉
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    pinchedThisTouch = false
                }
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                if !zoomed, pinchStart == nil, !pinchedThisTouch, onSwipe != nil,
                   abs(v.translation.width) > abs(v.translation.height) {
                    swipeOffset = v.translation.width * 0.35
                    return
                }
                guard zoomed, pinchStart == nil else { return }
                let s = dragStart ?? (pan, v.translation)
                if dragStart == nil { dragStart = s }
                pan = clamp(CGSize(width: s.pan.width + v.translation.width - s.translation.width,
                                   height: s.pan.height + v.translation.height - s.translation.height), zoom: zoom)
            }
            .onEnded { v in
                dragStart = nil
                if swipeOffset != 0 { withAnimation(.snappy) { swipeOffset = 0 } }
                // 未放大、水平滑超過 60 pt 且明顯比垂直多 → 切換攝影機
                let dx = v.translation.width, dy = v.translation.height
                if !zoomed, pinchStart == nil, !pinchedThisTouch, let onSwipe, abs(dx) > 60, abs(dx) > abs(dy) * 1.5 {
                    swipeCount += 1
                    onSwipe(dx < 0 ? 1 : -1)
                }
                pinchedThisTouch = false
            }
    }

    private func toggleZoom(at p: CGPoint) {
        if zoomed { reset() } else { setZoom(2.5, anchor: p) }
    }

    /// 從未放大狀態放大到 z，讓 anchor 那一點維持在原位
    private func setZoom(_ z: CGFloat, anchor p: CGPoint) {
        let k = 1 - z / zoom
        let target = CGSize(width: pan.width + (p.x - center.x - pan.width) * k,
                            height: pan.height + (p.y - center.y - pan.height) * k)
        withAnimation(.snappy) {
            zoom = z
            pan = clamp(target, zoom: z)
        }
    }

    /// 平移量限制在放大後畫面不露出邊界的範圍內
    private func clamp(_ p: CGSize, zoom z: CGFloat) -> CGSize {
        let maxX = size.width * (z - 1) / 2, maxY = size.height * (z - 1) / 2
        return CGSize(width: min(max(p.width, -maxX), maxX), height: min(max(p.height, -maxY), maxY))
    }

    private func reset() {
        withAnimation(.snappy) { zoom = 1; pan = .zero }
        pinchStart = nil
        dragStart = nil
    }
}
