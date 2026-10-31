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
    /// DVR 同時影像連線已達上限，且影像服務 Port 連不上
    var onLiveLimit: (() -> Void)?

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
                case .reconnecting(let why):
                    self.phase = .reconnecting(why)
                    if why.contains(DVRConnection.liveLimitMessage) { self.onLiveLimit?() }
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
    /// 多路同步回放的共用時鐘（單路時為 nil）
    var clock: PlaybackClock?

    var isPaused: Bool { phase == .paused }
    var isActive: Bool { player != nil }

    func open(connection: DVRConnection, channelID: String, mainStream: Bool, at date: Date) {
        let k = "\(ObjectIdentifier(connection))|\(channelID)|\(mainStream)|\(clock.map { "\(ObjectIdentifier($0))" } ?? "-")"
        if key != k || player == nil {
            player?.stop()
            let p = PlaybackStreamPlayer(connection: connection, channelId: channelID, mainStream: mainStream)
            p.clock = clock
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

/// 多路同步回放：最多 4 格共用一個時鐘與一條時間軸。
/// 對外介面與 PlaybackController 相同；顯示狀態、聲音、截圖以「選取的格子」為準。
@Observable
@MainActor
final class MultiPlaybackController {
    let subs = (0..<4).map { _ in PlaybackController() }
    private let clock = PlaybackClock()
    private(set) var focus = 0
    private var sources: [(conn: DVRConnection, channelID: String)?] = []
    private var mainStream = true

    private var focused: PlaybackController { subs[focus] }
    private var active: [PlaybackController] { subs.indices.filter { sources.indices.contains($0) && sources[$0] != nil }.map { subs[$0] } }

    var renderer: VideoRenderer { focused.renderer }
    var phase: PlaybackController.Phase { focused.phase }
    var currentTime: Date? { focused.currentTime ?? active.lazy.compactMap(\.currentTime).first }
    var isPaused: Bool { focused.isPaused }
    var speed: Double { focused.speed }
    var audioOn: Bool { focused.audioOn }

    /// 開始或跳轉：sources 依格子順序（nil＝空格）；超過 1 格時共用時鐘
    func open(_ sources: [(conn: DVRConnection, channelID: String)?], focus: Int, mainStream: Bool, at date: Date) {
        self.sources = sources
        self.mainStream = mainStream
        setFocus(focus)
        let multi = sources.compactMap { $0 }.count > 1
        clock.reset()
        clock.setSpeed(focused.speed)
        clock.resume()
        for (i, c) in subs.enumerated() {
            guard sources.indices.contains(i), let src = sources[i] else { c.stop(); continue }
            c.clock = multi ? clock : nil
            c.setSpeed(focused.speed)
            c.open(connection: src.conn, channelID: src.channelID, mainStream: mainStream, at: date)
        }
    }

    /// 換選取的格子：聲音跟著移過去，不重新播放
    func setFocus(_ i: Int) {
        guard subs.indices.contains(i), i != focus else { return }
        let audio = focused.audioOn
        if audio { focused.setAudio(false) }
        focus = i
        if audio { focused.setAudio(true) }
    }

    func togglePause() {
        if focused.isPaused {
            clock.resume()
            active.filter(\.isPaused).forEach { $0.togglePause() }
        } else {
            clock.pause()
            active.filter { !$0.isPaused }.forEach { $0.togglePause() }
        }
    }

    func setSpeed(_ s: Double) {
        clock.setSpeed(s)
        subs.forEach { $0.setSpeed(s) }
    }

    func skip(_ seconds: TimeInterval) {
        guard let t = currentTime else { return }
        open(sources, focus: focus, mainStream: mainStream, at: t.addingTimeInterval(seconds))
    }

    func step() { active.forEach { $0.step() } }
    func setAudio(_ on: Bool) { focused.setAudio(on) }
    func setVolume(_ v: Double) { subs.forEach { $0.setVolume(v) } }

    func stop() {
        subs.forEach { $0.stop() }
        sources = []
    }
}
