import CoreMedia
import CoreVideo
import Foundation

/// 單一頻道即時播放器：WebSocket → SHFL → VideoToolbox → `onFrame`。
///
/// - 背景執行（解碼不在主執行緒）
/// - 斷線、10 秒無資料、Session 失效時自動重連（1→2→4…最多 15 秒）
/// - `stop()` 後關閉 socket、釋放解碼器
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
    private var current: NVMSStream?
    private var _main: Bool
    private var lastFrameAt = ContinuousClock.now

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
        let (t, s) = lock.withLock { () -> (Task<Void, Never>?, NVMSStream?) in
            defer { task = nil; current = nil }
            return (task, current)
        }
        t?.cancel()
        if let s { Task { await s.close(kind: .live) } }
    }

    /// 切換主／子串流（重新開啟串流）
    public func setMainStream(_ main: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard _main != main else { return false }
            _main = main
            return true
        }
        if changed, let s = lock.withLock({ current }) {
            Task { await s.cancelSocket() }  // run() 迴圈會以新設定重連
        }
    }

    private func emit(_ s: State) { onState?(s) }

    private func run() async {
        var backoff: Double = 1
        var first = true
        while !Task.isCancelled {
            emit(first ? .connecting : .reconnecting("重新連線中"))
            first = false
            do {
                let sid = try await connection.sessionId()
                let stream = NVMSStream(host: connection.host, port: connection.port, sessionId: sid)
                lock.withLock { current = stream; lastFrameAt = .now }
                try await stream.connect()
                let main = isMainStream
                try await stream.openPreview(channelId: channelId, streamIndex: main ? 1 : 2)

                // 監看：10 秒沒有訊框就中斷重連
                let watchdog = Task.detached { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        guard let self else { return }
                        if ContinuousClock.now - self.lock.withLock({ self.lastFrameAt }) > .seconds(10) {
                            await stream.cancelSocket(); return
                        }
                    }
                }
                defer { watchdog.cancel() }

                let decoder = VideoDecoder()
                var playing = false
                loop: while !Task.isCancelled {
                    switch try await stream.receive() {
                    case .frame(let f):
                        guard let frame = SHFLFrame.parse(f.payload) else { continue }
                        lock.withLock { lastFrameAt = .now }
                        let pts = CMTime(value: Int64(frame.fileTime / 10), timescale: 1_000_000)
                        if let out = try? decoder.decode(annexB: frame.videoData, pts: pts) {
                            if !playing { playing = true; backoff = 1; emit(.playing) }
                            onFrame?(out.pixelBuffer, frame.captureTime)
                        }
                    case .message(let url, let code, _):
                        if let code, code != 0, url.hasPrefix("/device/preview") {
                            throw NVMSError.device(command: url, code: code)
                        }
                    case .closed(let why):
                        if lock.withLock({ _main }) != main { break loop }  // 切換串流：立即重連
                        throw NVMSError.transport(why)
                    }
                }
                decoder.invalidate()
                await stream.close(kind: .live)
                if Task.isCancelled { break }
                continue  // 切換串流
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
        return e.localizedDescription
    }
}
