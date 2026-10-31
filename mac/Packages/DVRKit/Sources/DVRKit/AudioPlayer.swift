import AVFoundation
import Foundation

/// DVR 聲音播放：G.711（A-law／μ-law）→ Float32 → AVAudioEngine。
///
/// - 實測 TVT DVR 為 G.711 A-law、8000 Hz、單聲道，每個訊框 320 取樣（40 毫秒）
/// - 以前 50 個訊框的靜音值判斷 A-law（0xD5/0x55）或 μ-law（0xFF/0x7F）
/// - 可在任何執行緒呼叫 `feed`
public final class AudioPlayer: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var sampleRate: Double = 8000
    private var queued = 0
    private var _volume: Float = 1
    private var muLaw: Bool?
    private var hist = (alaw: 0, mulaw: 0)

    private var _fed = 0
    /// 已送入的聲音訊框數（測試／診斷用）
    public var fedFrames: Int { lock.withLock { _fed } }
    public var detectedMuLaw: Bool? { lock.withLock { muLaw } }

    /// 佇列上限（秒）：超過就丟棄，避免即時聲音延遲越來越大
    public var maxLatency: Double = 0.6

    public init() {}
    deinit { stop() }

    public var volume: Float {
        get { lock.withLock { _volume } }
        set { lock.withLock { _volume = newValue; node?.volume = newValue } }
    }

    public func feed(_ data: Data, sampleRate rate: Int) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        _fed += 1
        detectLaw(data)
        if engine == nil || Double(rate) != sampleRate { start(rate: Double(rate)) }
        guard let node, let format else { return }
        let maxFrames = Int(sampleRate * maxLatency)
        if queued > maxFrames { return }  // 落後太多：丟棄
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count)) else { return }
        buf.frameLength = AVAudioFrameCount(data.count)
        let out = buf.floatChannelData![0]
        let mu = muLaw ?? false
        data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            for i in 0..<b.count { out[i] = Float(mu ? G711.ulaw(b[i]) : G711.alaw(b[i])) / 32768 }
        }
        queued += data.count
        let n = data.count
        node.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.queued = max(self.queued - n, 0) }
        }
        if !node.isPlaying { node.play() }
    }

    // 注意：AVAudioPlayerNode.stop() 會同步呼叫已排程緩衝區的完成回呼（回呼內會取 lock），
    // 所以 stop() 必須在 lock 外呼叫，否則會死結。

    /// 清空佇列（暫停、跳轉時）
    public func flush() {
        let n = lock.withLock { () -> AVAudioPlayerNode? in queued = 0; return node }
        n?.stop()
        lock.withLock { queued = 0 }
    }

    public func stop() {
        let (n, e) = lock.withLock { () -> (AVAudioPlayerNode?, AVAudioEngine?) in
            defer { node = nil; engine = nil; queued = 0 }
            return (node, engine)
        }
        n?.stop()
        e?.stop()
    }

    private func start(rate: Double) {
        // 由 feed()（持有 lock）呼叫：舊節點的停止移到背景，避免在 lock 內觸發完成回呼
        if let oldNode = node, let oldEngine = engine {
            DispatchQueue.global().async { oldNode.stop(); oldEngine.stop() }
        }
        let e = AVAudioEngine()
        let n = AVAudioPlayerNode()
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return }
        Self.activateAudioSession()
        e.attach(n)
        e.connect(n, to: e.mainMixerNode, format: f)
        n.volume = _volume
        do { try e.start() } catch { return }
        engine = e; node = n; format = f; sampleRate = rate; queued = 0
    }

    /// iPhone 需要先設定音訊工作階段：用 .playback，靜音開關打開時仍有聲音，並與其他 App 的聲音混音。
    /// macOS 沒有音訊工作階段，不需要做任何事。
    private static func activateAudioSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? s.setActive(true)
        #endif
    }

    private func detectLaw(_ d: Data) {
        guard muLaw == nil else { return }
        for x in d.prefix(64) {
            if x == 0xD5 || x == 0x55 { hist.alaw += 1 }
            if x == 0xFF || x == 0x7F { hist.mulaw += 1 }
        }
        if hist.alaw + hist.mulaw > 800 { muLaw = hist.mulaw > hist.alaw }
    }
}

/// ITU-T G.711 解碼
enum G711 {
    static func alaw(_ v: UInt8) -> Int16 {
        let a = v ^ 0x55
        var t = Int16(a & 0x0F) << 4
        let seg = (a & 0x70) >> 4
        switch seg {
        case 0: t += 8
        case 1: t += 0x108
        default: t += 0x108; t <<= Int16(seg - 1)
        }
        return (a & 0x80) != 0 ? t : -t
    }

    static func ulaw(_ v: UInt8) -> Int16 {
        let u = ~v
        var t = (Int16(u & 0x0F) << 3) + 0x84
        t <<= Int16((u & 0x70) >> 4)
        return (u & 0x80) != 0 ? 0x84 - t : t - 0x84
    }
}
