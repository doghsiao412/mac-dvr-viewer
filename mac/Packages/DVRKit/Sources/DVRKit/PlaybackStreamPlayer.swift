import CoreMedia
import CoreVideo
import Foundation

/// 歷史錄影播放器（同 DVR 網頁 wasm-player 的行為）。
///
/// - 接收：WebSocket `/device/playback/open`，SHFL 訊框放入佇列
/// - 顯示：依訊框 FILETIME 與倍速控制節奏；每顯示 8 個訊框回報 `refresh_play_index`（流量控制）
///   → 暫停時不回報，DVR 自然停止傳送
/// - 倍速 > 4：要求 DVR 只送關鍵幀（`key_frame`）
/// - 跳轉：關閉後以新時間重新開啟（網頁版亦同）
/// - 逐格：暫停狀態下顯示下一格
public final class PlaybackStreamPlayer: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case loading
        case playing
        case paused
        case ended
        case failed(String)
        case stopped
    }

    public let channelId: String
    private let connection: DVRConnection
    private let mainStream: Bool
    private let lock = NSLock()

    // 以下由 lock 保護
    private var generation = 0
    private var stream: MediaStream?
    private var queue: [SHFLFrame] = []
    private var deviceEnded = false
    private var paused = false
    private var stepRequested = false
    private var speed: Double = 1
    private var keyFrameMode = false
    private var currentTime: Date?
    private var tasks: [Task<Void, Never>] = []

    public var onFrame: (@Sendable (CVPixelBuffer, Date) -> Void)?
    public var onState: (@Sendable (State) -> Void)?
    public var onTime: (@Sendable (Date) -> Void)?

    public init(connection: DVRConnection, channelId: String, mainStream: Bool = false) {
        self.connection = connection
        self.channelId = channelId
        self.mainStream = mainStream
    }

    deinit { tasks.forEach { $0.cancel() } }

    public var time: Date? { lock.withLock { currentTime } }
    public var isPaused: Bool { lock.withLock { paused } }
    public var playbackSpeed: Double { lock.withLock { speed } }

    // MARK: - 控制

    /// 從指定時間開始播放（也用於跳轉）
    public func play(from date: Date, until end: Date? = nil) {
        let gen = lock.withLock { () -> Int in
            generation += 1
            tasks.forEach { $0.cancel() }
            tasks = []
            if let s = stream { Task { await s.close() } }
            stream = nil
            queue = []
            deviceEnded = false
            stepRequested = false
            currentTime = date
            return generation
        }
        onState?(.loading)
        let endDate = end ?? date.addingTimeInterval(12 * 3600)
        let t1 = Task.detached(priority: .userInitiated) { [weak self] () -> Void in
            await self?.receiveLoop(gen: gen, start: date, end: endDate)
        }
        let t2 = Task.detached(priority: .userInitiated) { [weak self] () -> Void in
            await self?.renderLoop(gen: gen)
        }
        lock.withLock { tasks = [t1, t2] }
    }

    public func pause() {
        lock.withLock { paused = true }
        onState?(.paused)
    }

    public func resume() {
        let (s, idx) = lock.withLock { () -> (MediaStream?, UInt32?) in
            paused = false
            return (stream, queue.last?.sequence)
        }
        onState?(.playing)
        // 立即回報一次，讓 DVR 繼續送資料（同網頁 _resumeDownload）
        if let s, let idx { Task { await s.acknowledge(Int(idx)) } }
    }

    public func stepFrame() {
        lock.withLock { paused = true; stepRequested = true }
    }

    public func setSpeed(_ newSpeed: Double) {
        let (s, needKey, wasKey, t) = lock.withLock { () -> (MediaStream?, Bool, Bool, Date?) in
            let was = keyFrameMode
            speed = max(0.25, min(newSpeed, 32))
            keyFrameMode = speed > 4
            return (stream, keyFrameMode, was, currentTime)
        }
        if needKey != wasKey, let s, let t, let kf = s.setKeyFrameOnly {
            Task { await kf(needKey, t) }
        }
    }

    public func stop() {
        let (ts, s) = lock.withLock { () -> ([Task<Void, Never>], MediaStream?) in
            generation += 1
            defer { tasks = []; stream = nil; queue = [] }
            return (tasks, stream)
        }
        ts.forEach { $0.cancel() }
        if let s { Task { await s.close() } }
        onState?(.stopped)
    }

    // MARK: - 迴圈

    private func isCurrent(_ gen: Int) -> Bool { lock.withLock { generation == gen } }

    private func receiveLoop(gen: Int, start: Date, end: Date) async {
        do {
            let ms = try await connection.openPlayback(
                channelId: channelId, start: start, end: end, mainStream: mainStream,
                typeMask: ["manual", "schedule", "motion", "sensor", "smart_motion", "osc", "avd",
                           "tripwire", "perimeter", "vfd", "pos", "cpc", "cdd", "ipd"])
            guard isCurrent(gen) else { await ms.close(); return }
            lock.withLock { stream = ms }
            if lock.withLock({ keyFrameMode }), let kf = ms.setKeyFrameOnly { await kf(true, start) }
            for try await payload in ms.frames {
                if Task.isCancelled || !isCurrent(gen) { return }
                if let fr = SHFLFrame.parse(payload) {
                    lock.withLock { if generation == gen { queue.append(fr) } }
                }
            }
            markEnded(gen)  // 串流正常結束（播完）
        } catch {
            guard isCurrent(gen), !Task.isCancelled else { return }
            if DVRConnection.isSessionError(error) { try? await connection.relogin() }
            markEnded(gen)
            if isCurrent(gen) { onState?(.failed(LiveStreamPlayer.describe(error))) }
        }
    }

    private func renderLoop(gen: Int) async {
        let decoder = VideoDecoder()
        defer { decoder.invalidate() }
        var anchorWall: ContinuousClock.Instant?
        var anchorFT: UInt64 = 0
        var anchorSpeed: Double = 1
        var reportedPlaying = false
        var idleSince: ContinuousClock.Instant?

        while !Task.isCancelled, isCurrent(gen) {
            let (isPaused, step, spd) = lock.withLock { (paused, stepRequested, speed) }
            if isPaused && !step {
                anchorWall = nil
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            guard let frame = lock.withLock({ queue.isEmpty ? nil : queue.removeFirst() }) else {
                if lock.withLock({ deviceEnded }) {
                    // 已顯示完所有訊框
                    if isCurrent(gen) { onState?(.ended) }
                    return
                }
                if idleSince == nil { idleSince = .now }
                anchorWall = nil  // 緩衝不足：重新對齊時間
                try? await Task.sleep(for: .milliseconds(10))
                continue
            }
            idleSince = nil

            // 控速
            if anchorWall == nil || spd != anchorSpeed || frame.fileTime < anchorFT {
                anchorWall = .now; anchorFT = frame.fileTime; anchorSpeed = spd
            } else if let aw = anchorWall, !step {
                let mediaSeconds = Double(frame.fileTime - anchorFT) / 10_000_000 / spd
                let target = aw + .milliseconds(Int64(mediaSeconds * 1000))
                let now = ContinuousClock.now
                if target > now {
                    let wait = target - now
                    if wait > .seconds(5) {  // 錄影中斷（區段間隙）：不要真的等，直接重新對齊（關鍵幀模式的正常間距不會超過）
                        anchorWall = .now; anchorFT = frame.fileTime
                    } else {
                        try? await Task.sleep(for: wait)
                    }
                } else if now - target > .seconds(1) {
                    anchorWall = now; anchorFT = frame.fileTime  // 落後太多：重新對齊
                }
            }
            guard isCurrent(gen) else { return }

            let pts = CMTime(value: Int64(frame.fileTime / 10), timescale: 1_000_000)
            if let out = try? decoder.decode(annexB: frame.videoData, pts: pts), isCurrent(gen) {
                onFrame?(out.pixelBuffer, frame.captureTime)
                lock.withLock { currentTime = frame.captureTime }
                onTime?(frame.captureTime)
                if !reportedPlaying { reportedPlaying = true; onState?(isPausedNow() ? .paused : .playing) }
            }
            // 流量控制（同網頁：每 8 格，或關鍵幀模式每格）
            let seq = Int(frame.sequence)
            let (s, keyMode) = lock.withLock { (stream, keyFrameMode) }
            if seq > 0, seq % 8 == 0 || keyMode, let s {
                await s.acknowledge(seq)
            }
            if step { lock.withLock { stepRequested = false } }
        }
    }

    private func isPausedNow() -> Bool { lock.withLock { paused } }

    private func markEnded(_ gen: Int) {
        lock.withLock { if generation == gen { deviceEnded = true } }
    }
}
