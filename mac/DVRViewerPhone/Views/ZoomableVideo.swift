import SwiftUI

/// 可雙指放大的影像（數位縮放，1–8 倍）
///
/// - 雙指捏合：以手指位置為中心放大／縮小
/// - 放大後單指拖曳：平移（不會拖出畫面邊界）
/// - 點兩下：未放大時放大 2.5 倍（以點的位置為中心）；已放大時還原
/// - 左上角顯示倍率，點一下還原
struct ZoomableVideo: View {
    let renderer: VideoRenderer
    var aspect: VideoAspect = .fit

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
            .accessibilityAction(named: "放大") { setZoom(min(zoom * 2, Self.maxZoom), anchor: center) }
            .accessibilityAction(named: "還原畫面大小") { reset() }
    }

    private var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    // MARK: - 手勢

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let s = pinchStart ?? (zoom, pan)
                if pinchStart == nil { pinchStart = s }
                dragStart = nil
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
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                guard zoomed, pinchStart == nil else { return }
                let s = dragStart ?? (pan, v.translation)
                if dragStart == nil { dragStart = s }
                pan = clamp(CGSize(width: s.pan.width + v.translation.width - s.translation.width,
                                   height: s.pan.height + v.translation.height - s.translation.height), zoom: zoom)
            }
            .onEnded { _ in dragStart = nil }
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
