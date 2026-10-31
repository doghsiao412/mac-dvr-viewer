import AppKit
import QuartzCore

/// 下載飛入動畫（類似 Safari）：用 Core Animation 在透明的子視窗上播放。
/// 動畫由系統的繪圖伺服器執行，不受主執行緒或 SwiftUI 重繪影響，因此不會掉幀。
@MainActor
enum DownloadFlight {
    static func run(in window: NSWindow, landed: @escaping @MainActor () -> Void) {
        let frame = window.frame
        let overlay = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        overlay.contentView = host
        window.addChildWindow(overlay, ordered: .above)

        // 座標：AppKit 左下為原點
        let size: CGFloat = 56
        let start = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let end = CGPoint(x: frame.width - 30, y: frame.height - 26)   // 工具列右上角的下載按鈕
        let control = CGPoint(x: start.x + (end.x - start.x) * 0.15, y: end.y + 40)

        let icon = CALayer()
        icon.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        icon.position = end
        icon.cornerRadius = size / 2
        icon.backgroundColor = NSColor.controlAccentColor.cgColor
        icon.shadowColor = NSColor.black.cgColor
        icon.shadowOpacity = 0.3
        icon.shadowRadius = 8
        icon.shadowOffset = CGSize(width: 0, height: -3)
        let scale = window.backingScaleFactor
        if let img = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .bold).applying(.init(paletteColors: [.white]))) {
            let glyph = CALayer()
            glyph.contents = img.layerContents(forContentsScale: scale)
            glyph.contentsScale = scale
            glyph.contentsGravity = .center
            glyph.frame = icon.bounds
            icon.addSublayer(glyph)
        }
        icon.opacity = 0
        host.layer?.addSublayer(icon)

        let appear = 0.14, travel = 0.6, total = appear + travel

        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.beginTime = appear
        move.duration = travel
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.8, 0.6)
        move.fillMode = .both

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.6, 1.05, 1.0, 0.32]
        pop.keyTimes = [0, NSNumber(value: appear * 0.7 / total), NSNumber(value: appear / total), 1]
        pop.timingFunctions = [.init(name: .easeOut), .init(name: .easeInEaseOut), .init(name: .easeIn)]
        pop.duration = total

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: appear / total), NSNumber(value: (total - 0.1) / total), 1]
        fade.duration = total

        let group = CAAnimationGroup()
        group.animations = [move, pop, fade]
        group.duration = total

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                window.removeChildWindow(overlay)
                overlay.orderOut(nil)
                landed()
            }
        }
        icon.add(group, forKey: "flight")
        CATransaction.commit()
    }
}

private extension NSImage {
    func layerContents(forContentsScale s: CGFloat) -> Any {
        var r = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &r, context: nil, hints: [.ctm: AffineTransform(scale: s)]) as Any
    }
}
