import AVFoundation
import CoreMedia
import CoreVideo
import SwiftUI

/// 把解碼後的 CVPixelBuffer 立即顯示在 AVSampleBufferDisplayLayer 上。
/// 可在任何執行緒呼叫 `enqueue`（解碼執行緒直接送，不經主執行緒）。
final class VideoRenderer: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var _last: CVPixelBuffer?
    private var _lastTime: Date?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    var lastPixelBuffer: CVPixelBuffer? { lock.withLock { _last } }
    var lastTime: Date? { lock.withLock { _lastTime } }

    func enqueue(_ pb: CVPixelBuffer, time: Date) {
        let fmt: CMVideoFormatDescription? = lock.withLock {
            _last = pb
            _lastTime = time
            if let f = format, CMVideoFormatDescriptionMatchesImageBuffer(f, imageBuffer: pb) { return f }
            var nf: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &nf)
            format = nf
            return nf
        }
        guard let fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    func clear() {
        lock.withLock { _last = nil; _lastTime = nil }
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func setAspect(_ a: VideoAspect) {
        switch a {
        case .fit: layer.videoGravity = .resizeAspect
        case .fill: layer.videoGravity = .resizeAspectFill
        case .stretch: layer.videoGravity = .resize
        }
    }
}

/// SwiftUI 包裝：承載 renderer 的 layer
#if os(macOS)
struct VideoSurface: NSViewRepresentable {
    let renderer: VideoRenderer
    var aspect: VideoAspect = .fit

    func makeNSView(context: Context) -> NSView {
        let v = LayerHostView()
        v.wantsLayer = true
        v.layer = CALayer()
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.hosted = renderer.layer
        v.layer?.addSublayer(renderer.layer)
        renderer.setAspect(aspect)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        renderer.setAspect(aspect)
        if let h = v as? LayerHostView, h.hosted !== renderer.layer {
            h.hosted?.removeFromSuperlayer()
            h.hosted = renderer.layer
            v.layer?.addSublayer(renderer.layer)
            h.needsLayout = true
        }
    }

    final class LayerHostView: NSView {
        var hosted: CALayer?
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}
#else
struct VideoSurface: UIViewRepresentable {
    let renderer: VideoRenderer
    var aspect: VideoAspect = .fit

    func makeUIView(context: Context) -> LayerHostView {
        let v = LayerHostView()
        v.backgroundColor = .black
        v.hosted = renderer.layer
        v.layer.addSublayer(renderer.layer)
        renderer.setAspect(aspect)
        return v
    }

    func updateUIView(_ v: LayerHostView, context: Context) {
        renderer.setAspect(aspect)
        if v.hosted !== renderer.layer {
            v.hosted?.removeFromSuperlayer()
            v.hosted = renderer.layer
            v.layer.addSublayer(renderer.layer)
            v.setNeedsLayout()
        }
    }

    final class LayerHostView: UIView {
        var hosted: CALayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}
#endif
