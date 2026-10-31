import CoreMedia
import CoreVideo
import Foundation

/// 單一頻道即時播放器：MediaStream（WebSocket 或私有協定）→ SHFL → VideoToolbox → `onFrame`。
///
/// - 背景執行（解碼不在主執行緒）
/// - 斷線、10 秒無資料、Session 失效時自動重連（1→2→4…最多 15 秒）
/// - `stop()` 後關閉串流、釋放解碼器
public final class LiveStreamPlayer: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case connecting
        case playing
        case reconnecting(String)
        case stopped
    }

    public let channelId: String
    private let connection: DVRConnection
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var current: MediaStream?
    private var _main: Bool
    private var lastFrameAt = ContinuousClock.now
    private var _audio = false
    /// 聲音輸出（G.711）
    public let audioPlayer = AudioPlayer()
    /// DVR 回報此頻道沒有聲音
    public var onAudioUnsupported: (@Sendable () -> Void)?

    /// 解碼後的畫面與擷取時間（在背景執行緒呼叫）
    public var onFrame: (@Sendable (CVPixelBuffer, Date) -> Void)?
    public var onState: (@Sendable (State) -> Void)?

    public init(connection: DVRConnection, channelId: String, mainStream: Bool) {
        self.connection = connection
        self.channelId = channelId
        self._main = mainStream
    }

    deinit { task?.cancel() }

    public var isMainStream: Bool { lock.withLock { _main } }

    public func start() {
        lock.withLock {
            guard task == nil else { return }
            task = Task.detached(priority: .userInitiated) { [weak self] in await self?.run() }
        }
    }

    public func stop() {
        let (t, s) = lock.withLock { () -> (Task<Void, Never>?, MediaStream?) in
            defer { task = nil; current = nil }
            return (task, current)
        }
        t?.cancel()
        audioPlayer.stop()
        if let s { Task { await s.close() } }
    }

    /// 切換主／子串流（關閉目前串流，迴圈會以新設定重開）
    public func setMainStream(_ main: Bool) {
        let s = lock.withLock { () -> MediaStream? in
            guard _main != main else { return nil }
            _main = main
            return current
        }
        if let s { Task { await s.close() } }
    }

    public var isAudioEnabled: Bool { lock.withLock { _audio } }

    /// 開關聲音。WebSocket：直接送開／關命令；私有協定：以新設定重開串流
    public func setAudio(_ on: Bool) {
        let s = lock.withLock { () -> MediaStream? in
            guard _audio != on else { return nil }
            _audio = on
            return current
        }
        if !on { audioPlayer.stop() }
        guard let s else { return }
        if let f = s.setAudio {
            Task { await f(on) }
        } else {
            Task { await s.close() }  // 私有協定：重開
        }
    }

    private func emit(_ s: State) { onState?(s) }

    private func run() async {
        var backoff: Double = 1
        var first = true
        while !Task.isCancelled {
            emit(first ? .connecting : .reconnecting("重新連線中"))
            first = false
            let main = isMainStream
            let audio = isAudioEnabled
            do {
                let ms = try await connection.openLive(channelId: channelId, mainStream: main, audio: audio)
                lock.withLock { current = ms; lastFrameAt = .now }
                if audio, let f = ms.setAudio { await f(true) }

                // 監看：10 秒沒有訊框就關閉重連
                let watchdog = Task.detached { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        guard let self else { return }
                        if ContinuousClock.now - self.lock.withLock({ self.lastFrameAt }) > .seconds(10) {
                            await ms.close(); return
                        }
                    }
                }
                defer { watchdog.cancel() }

                let decoder = VideoDecoder()
                defer { decoder.invalidate() }
                var playing = false
                for try await payload in ms.frames {
                    if Task.isCancelled { break }
                    guard let frame = SHFLFrame.parse(payload) else { continue }
                    lock.withLock { lastFrameAt = .now }
                    if frame.isAudio {
                        if isAudioEnabled { audioPlayer.feed(frame.videoData, sampleRate: frame.audioSampleRate ?? 8000) }
                        continue
                    }
                    if isAudioEnabled, ms.audioUnsupported() { lock.withLock { _audio = false }; onAudioUnsupported?() }
                    let pts = CMTime(value: Int64(frame.fileTime / 10), timescale: 1_000_000)
                    if let out = try? decoder.decode(annexB: frame.videoData, pts: pts) {
                        if !playing { playing = true; backoff = 1; emit(.playing) }
                        onFrame?(out.pixelBuffer, frame.captureTime)
                    }
                }
                await ms.close()
                if Task.isCancelled { break }
                if isMainStream != main || isAudioEnabled != audio { continue }  // 切換串流或聲音：立即重開
                throw NVMSError.transport("串流已結束")
            } catch {
                if Task.isCancelled { break }
                if DVRConnection.isSessionError(error) { try? await connection.relogin() }
                emit(.reconnecting(Self.describe(error)))
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 15)
            }
        }
        emit(.stopped)
    }

    static func describe(_ e: Error) -> String {
        if let n = e as? NVMSError { return n.description }
        if let p = e as? TVTPrivateClient.ClientError { return p.description }
        return e.localizedDescription
    }
}
