import Foundation

/// 一路影像串流（即時或回放）的統一介面：播放器不需知道底層是 WebSocket 還是 TVT 私有協定。
public struct MediaStream: Sendable {
    /// SHFL 訊框（每個元素為一個完整 SHFL payload）；結束 = 串流結束（回放播完）
    public let frames: AsyncThrowingStream<Data, Error>
    /// 回放流量控制：回報已顯示的訊框序號
    public let acknowledge: @Sendable (Int) async -> Void
    /// 只送關鍵幀（快轉）；不支援時為 nil
    public let setKeyFrameOnly: (@Sendable (Bool, Date) async -> Void)?
    public let close: @Sendable () async -> Void
    /// 底層方式（顯示用）
    public let transport: String
}

extension MediaStream {
    /// WebSocket（NVMS-9000 新版韌體）
    static func webSocket(host: String, port: Int, sessionId: String, live: Bool,
                          open: @escaping @Sendable (NVMSStream) async throws -> Void) async throws -> MediaStream {
        let ws = NVMSStream(host: host, port: port, sessionId: sessionId)
        try await ws.connect()
        try await open(ws)
        let (stream, cont) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: live ? .bufferingNewest(240) : .unbounded)
        let reader = Task {
            while !Task.isCancelled {
                let ev: NVMSStream.Event? = try? await ws.receive()
                switch ev {
                case .frame(let f)?:
                    cont.yield(f.payload)
                case .message(let url, let code, _)?:
                    if let code, code != 0, url.hasPrefix("/device/preview") || url.hasPrefix("/device/playback") {
                        if code == 536_870_961 { cont.finish() } else { cont.finish(throwing: NVMSError.device(command: url, code: code)) }
                        return
                    }
                case .closed(let why)?:
                    if live { cont.finish(throwing: NVMSError.transport(why)) } else { cont.finish() }
                    return
                case nil:
                    cont.finish(throwing: NVMSError.transport("WebSocket 讀取失敗"))
                    return
                }
            }
            cont.finish()
        }
        let ack: @Sendable (Int) async -> Void = { idx in _ = try? await ws.refreshPlayIndex(idx) }
        let kfImpl: @Sendable (Bool, Date) async -> Void = { on, t in _ = try? await ws.keyFrameOnly(on, at: t) }
        let keyFrame: (@Sendable (Bool, Date) async -> Void)? = live ? nil : kfImpl
        let kind: NVMSStream.Kind = live ? .live : .playback
        let close: @Sendable () async -> Void = {
            reader.cancel()
            await ws.close(kind: kind)
            cont.finish()
        }
        return MediaStream(frames: stream, acknowledge: ack, setKeyFrameOnly: keyFrame, close: close, transport: "WebSocket")
    }
}
