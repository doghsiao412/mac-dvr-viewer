import DVRKit
import Foundation
import Observation
import QuartzCore

/// 一個 Live 格子的播放控制：綁定 View 生命週期（`.task` 開始、取消時停止）
@Observable
@MainActor
final class LiveTileController {
    enum Phase: Equatable {
        case idle, connecting, playing
        case reconnecting(String)
    }

    let renderer = VideoRenderer()
    private(set) var phase: Phase = .idle
    private(set) var lastFrameTime: Date?
    private(set) var audioUnsupported = false
    private var player: LiveStreamPlayer?
    private var wantAudio = false
    private var volume: Float = 0.8
    var onAudioUnsupported: (() -> Void)?

    func setAudio(_ on: Bool) {
        wantAudio = on
        if on { audioUnsupported = false }
        player?.setAudio(on)
    }

    func setVolume(_ v: Double) {
        volume = Float(v)
        player?.audioPlayer.volume = volume
    }

    /// 執行直到所屬 Task 被取消（View 消失或頻道改變）
    func run(connection: DVRConnection, channelID: String, mainStream: Bool) async {
        // 切換頻道／頁面時，舊的播放器會在背景慢慢結束；它的回報（尤其是最後的「已停止」）
        // 可能晚於新播放器的「播放中」。用 token 只接受這一次的回報，避免畫面一直轉圈。
        current?.active = false
        let token = RunToken()
        current = token
        renderer.clear()
        let p = LiveStreamPlayer(connection: connection, channelId: channelID, mainStream: mainStream)
        let r = renderer
        // 時間顯示只需約每秒更新數次：在解碼執行緒節流，不要每幀都切到主執行緒
        let gate = UpdateGate(interval: 0.25)
        p.onFrame = { [weak self] pb, t in
            guard token.active else { return }
            r.enqueue(pb, time: t)
            if gate.pass() { Task { @MainActor [weak self] in if token.active { self?.lastFrameTime = t } } }
        }
        p.onState = { [weak self] s in
            Task { @MainActor [weak self] in
                guard let self, token.active else { return }
                switch s {
                case .connecting: self.phase = .connecting
                case .playing: self.phase = .playing
                case .reconnecting(let why): self.phase = .reconnecting(why)
                case .stopped: self.phase = .idle
                }
            }
        }
        p.onAudioUnsupported = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, token.active else { return }
                self.audioUnsupported = true
                self.onAudioUnsupported?()
            }
        }
        p.audioPlayer.volume = volume
        player = p
        if wantAudio { p.setAudio(true) }
        p.start()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        p.stop()
        // 新的一次已經開始時，不要動到它的狀態
        if token.active {
            token.active = false
            player = nil
            phase = .idle
        }
    }

    private var current: RunToken?

}

/// 回放控制
@Observable
@MainActor
final class PlaybackController {
    enum Phase: Equatable {
        case idle, loading, playing, paused, ended
        case failed(String)
    }

    let renderer = VideoRenderer()
    private(set) var phase: Phase = .idle
    private(set) var currentTime: Date?
    private(set) var speed: Double = 1
    private var player: PlaybackStreamPlayer?
    private(set) var audioOn = false
    private var volume: Float = 0.8

    func setAudio(_ on: Bool) {
        audioOn = on
        player?.setAudio(on)
    }

    func setVolume(_ v: Double) {
        volume = Float(v)
        player?.audioPlayer.volume = volume
    }
    private var key: String?

    var isPaused: Bool { phase == .paused }

    func open(connection: DVRConnection, channelID: String, mainStream: Bool, at date: Date) {
        let k = "\(ObjectIdentifier(connection))|\(channelID)|\(mainStream)"
        if key != k || player == nil {
            player?.stop()
            let p = PlaybackStreamPlayer(connection: connection, channelId: channelID, mainStream: mainStream)
            let r = renderer
            p.onFrame = { pb, t in r.enqueue(pb, time: t) }
            // 目前時間每秒更新約 10 次即可（每幀更新會讓整個回放畫面重繪）
            let gate = UpdateGate(interval: 0.1)
            // 只接受目前這個播放器的回報（舊播放器結束時的「已停止」可能晚到）
            p.onTime = { [weak self, weak p] t in
                if gate.pass() { Task { @MainActor [weak self, weak p] in if let self, let p, self.player === p { self.currentTime = t } } }
            }
            p.onState = { [weak self, weak p] s in
                Task { @MainActor [weak self, weak p] in
                    guard let self, let p, self.player === p else { return }
                    switch s {
                    case .loading: self.phase = .loading
                    case .playing: self.phase = .playing
                    case .paused: self.phase = .paused
                    case .ended: self.phase = .ended
                    case .failed(let e): self.phase = .failed(e)
                    case .stopped: self.phase = .idle
                    }
                }
            }
            p.setSpeed(speed)
            p.audioPlayer.volume = volume
            p.setAudio(audioOn)
            player = p
            key = k
            renderer.clear()
        }
        currentTime = date
        player?.play(from: date)
    }

    func seek(to date: Date) {
        currentTime = date
        player?.play(from: date)
    }

    func togglePause() {
        guard let p = player else { return }
        if p.isPaused { p.resume() } else { p.pause() }
    }

    func step() { player?.stepFrame() }

    func setSpeed(_ s: Double) {
        speed = s
        player?.setSpeed(s)
    }

    func skip(_ seconds: TimeInterval) {
        guard let t = currentTime else { return }
        seek(to: t.addingTimeInterval(seconds))
    }

    func stop() {
        player?.stop()
        player = nil
        key = nil
        phase = .idle
    }
}

/// 一次播放的有效旗標（跨執行緒讀取）
final class RunToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _active = true
    var active: Bool {
        get { lock.withLock { _active } }
        set { lock.withLock { _active = newValue } }
    }
}

/// 跨執行緒的更新節流：距離上次放行超過 interval 秒才回傳 true
final class UpdateGate: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: CFTimeInterval
    private var last: CFTimeInterval = 0
    init(interval: CFTimeInterval) { self.interval = interval }
    func pass() -> Bool {
        let now = CACurrentMediaTime()
        return lock.withLock {
            if now - last < interval { return false }
            last = now
            return true
        }
    }
}
