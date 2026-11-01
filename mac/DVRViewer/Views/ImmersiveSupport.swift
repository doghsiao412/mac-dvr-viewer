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

#if DEBUG
/// 版面自動測試（只在 Debug 版、設定環境變數 DVRVIEWER_UITEST=<輸出資料夾> 時啟用）：
/// 不開影像串流，自動進出全螢幕數次，記錄版面座標並截取本 App 視窗（不需螢幕錄製權限）。
@MainActor
enum UITestHarness {
    static let outputDir = ProcessInfo.processInfo.environment["DVRVIEWER_UITEST"]
    static var enabled: Bool { outputDir != nil }
    static var gridFrame: CGRect = .zero
    /// DVRVIEWER_UITEST_SCENE=transcript：回放頁並開啟逐字稿面板（只截圖，不進全螢幕）
    static let scene = ProcessInfo.processInfo.environment["DVRVIEWER_UITEST_SCENE"]
    private static var started = false

    static func startIfRequested(window: NSWindow, store: AppStore) {
        guard let dir = outputDir, !started else { return }
        started = true
        Task { @MainActor in
            var log = ""
            @MainActor func snap(_ name: String) {
                let theme = window.contentView?.superview ?? window.contentView
                var split = ""
                func walk(_ v: NSView, _ depth: Int) {
                    if let s = v as? NSSplitView {
                        split += s.subviews.map { "[x=\(Int($0.frame.minX)) w=\(Int($0.frame.width)) h=\(Int($0.frame.height)) hidden=\($0.isHidden)]" }.joined(separator: " ")
                        return
                    }
                    if depth < 12 { v.subviews.forEach { walk($0, depth + 1) } }
                }
                if let c = window.contentView { walk(c, 0) }
                let opts = NSApp.currentSystemPresentationOptions
                log += "== \(name)\n"
                log += "  全螢幕=\(window.styleMask.contains(.fullScreen)) 視窗=\(Int(window.frame.width))x\(Int(window.frame.height))"
                log += " 內容區=\(window.contentLayoutRect.integral) 工具列可見=\(window.toolbar?.isVisible ?? false)"
                log += " autoHideToolbar=\(opts.contains(.autoHideToolbar)) chromeHidden=\(store.chromeHidden)\n"
                log += "  分割畫面區(global)=\(gridFrame.integral)\n  分割欄位：\(split)\n"
                if let t = theme, let rep = t.bitmapImageRepForCachingDisplay(in: t.bounds) {
                    t.cacheDisplay(in: t.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
                }
            }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            // DVRVIEWER_UITEST_SIZE=寬x高：模擬小螢幕（例如 720p 電視）
            if let sz = ProcessInfo.processInfo.environment["DVRVIEWER_UITEST_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), sz.count == 2 {
                window.setFrame(NSRect(x: 0, y: 0, width: sz[0], height: sz[1]), display: true)
            }
            if scene == "transcript" {
                store.mode = .playback
                try? await Task.sleep(for: .seconds(5))
                snap("transcript")
                try? log.write(to: URL(fileURLWithPath: dir).appending(path: "layout.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            try? await Task.sleep(for: .seconds(4))
            snap("0-一般")
            log += "  啟用狀態 isActive=\(NSApp.isActive) isKey=\(window.isKeyWindow) 可全螢幕=\(window.collectionBehavior.contains(.fullScreenPrimary)) 行為=\(window.collectionBehavior.rawValue)\n"
            for round in 1...2 {
                store.immersive = true
                try? await Task.sleep(for: .milliseconds(300))
                log += "  設定 immersive 後 0.3 秒：全螢幕=\(window.styleMask.contains(.fullScreen)) isActive=\(NSApp.isActive)\n"
                try? await Task.sleep(for: .seconds(4))
                snap("\(round)a-全螢幕")
                store.immersive = false
                try? await Task.sleep(for: .seconds(4))
                snap("\(round)b-離開後")
            }
            try? log.write(to: URL(fileURLWithPath: dir).appending(path: "layout.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
#endif
