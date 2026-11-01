import AppKit
import SwiftUI

/// 取得 SwiftUI 畫面所在的 NSWindow（全螢幕切換用）
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(v.window) }
    }
}

/// 滑鼠靜止一段時間後隱藏（全螢幕時的回放控制列、游標）
@MainActor
@Observable
final class IdleHider {
    private(set) var visible = true
    /// 滑鼠停在控制列上時不隱藏
    var pinned = false { didSet { if pinned { show() } else { poke() } } }
    private var task: Task<Void, Never>?
    let delay: Duration

    init(delay: Duration = .seconds(3)) { self.delay = delay }

    /// 滑鼠移動：顯示並重新計時
    func poke() {
        visible = true
        task?.cancel()
        guard !pinned else { return }
        task = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.pinned else { return }
            self.visible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func show() {
        task?.cancel()
        visible = true
    }

    func stop() {
        task?.cancel()
        visible = true
    }
}
