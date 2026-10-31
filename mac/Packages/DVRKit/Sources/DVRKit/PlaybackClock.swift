import Foundation

/// 多路同步回放的共用時鐘：所有播放器依同一個「目前回放時間」顯示畫面。
///
/// - 第一個畫面到達時才開始走（避免載入較慢的頻道一開始就要快轉追趕）
/// - 暫停時停止；播放器不顯示也不回報進度，DVR 會自動停止傳送
public final class PlaybackClock: @unchecked Sendable {
    private let lock = NSLock()
    private var anchorWall: ContinuousClock.Instant?
    private var anchorMedia: Date = .distantPast
    private var speed: Double = 1
    private var paused = false

    public init() {}

    /// 重新開始（跳轉時）：等第一個畫面到達才開始走
    public func reset() {
        lock.withLock { anchorWall = nil }
    }

    /// 目前回放時間（尚未開始時為 nil）
    public var now: Date? {
        lock.withLock { mediaNowLocked() }
    }

    public var isPaused: Bool { lock.withLock { paused } }

    public func pause() {
        lock.withLock {
            if let n = mediaNowLocked() { anchorMedia = n; anchorWall = .now }
            paused = true
        }
    }

    public func resume() {
        lock.withLock {
            if anchorWall != nil { anchorWall = .now }
            paused = false
        }
    }

    public func setSpeed(_ s: Double) {
        lock.withLock {
            if let n = mediaNowLocked() { anchorMedia = n; anchorWall = .now }
            speed = max(0.25, min(s, 32))
        }
    }

    public enum Decision: Sendable {
        case show
        case wait(Duration)
    }

    /// 某個畫面（擷取時間 t）現在該顯示，還是要再等
    public func decision(for t: Date) -> Decision {
        lock.withLock {
            if paused { return .wait(.milliseconds(50)) }
            guard let n = mediaNowLocked() else {
                anchorWall = .now          // 第一個畫面：從這裡開始走
                anchorMedia = t
                return .show
            }
            let ahead = t.timeIntervalSince(n)
            if ahead <= 0 { return .show }
            return .wait(.milliseconds(Int64(ahead / speed * 1000)))
        }
    }

    private func mediaNowLocked() -> Date? {
        guard let w = anchorWall else { return nil }
        if paused { return anchorMedia }
        let elapsed = ContinuousClock.now - w
        let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return anchorMedia.addingTimeInterval(secs * speed)
    }
}
