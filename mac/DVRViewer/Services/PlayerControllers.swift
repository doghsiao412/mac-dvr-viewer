import DVRKit
import Foundation
import Observation

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
    private var timeTicker = 0
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
        renderer.clear()
        let p = LiveStreamPlayer(connection: connection, channelId: channelID, mainStream: mainStream)
        let r = renderer
        p.onFrame = { [weak self] pb, t in
            r.enqueue(pb, time: t)
            Task { @MainActor [weak self] in self?.noteFrame(t) }
        }
        p.onState = { [weak self] s in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
                guard let self else { return }
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
        player = nil
        phase = .idle
    }

    private func noteFrame(_ t: Date) {
        // 降低主執行緒更新頻率：每 5 幀更新一次時間
        timeTicker += 1
        if timeTicker % 5 == 0 || lastFrameTime == nil { lastFrameTime = t }
    }
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
            p.onTime = { [weak self] t in Task { @MainActor [weak self] in self?.currentTime = t } }
            p.onState = { [weak self] s in
                Task { @MainActor [weak self] in
                    guard let self else { return }
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
