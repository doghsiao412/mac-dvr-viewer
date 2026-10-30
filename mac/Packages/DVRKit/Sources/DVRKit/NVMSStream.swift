import Foundation

/// NVMS-9000 WebSocket 串流（DVR 網頁 wasm 播放器使用的同一套協定）。
///
/// 協定來源：DVR 網頁 `js/lib/websocket.cmd.js`、`js/lib/WasmPlayer/downloader.js`、`decoder.js`。
/// 1. 連線 `ws://host:port/requestWebsocketConnection?sessionID=<sessionId>`
/// 2. 等待文字訊息 `{"url":"/device/create_connection#response","data":{"code":0}}`
/// 3. 送出 JSON 指令（例如 `/device/preview/open`），之後收到二進位訊框
/// 4. 二進位訊框（little-endian）：
///    `u32 a`：0 → 標頭 8 bytes，否則 16 bytes；`u32 jsonLen` 位於 offset 4
///    JSON 位於 [hdr, hdr+jsonLen)，其 `data.live_stream_data` / `data.playback_stream_data` = "偏移,長度"
///    媒體資料位於 hdr + jsonLen + 偏移，長度為「長度」
public actor NVMSStream {
    public enum Kind: Sendable { case live, playback }

    public struct Frame: Sendable {
        public let url: String
        public let json: [String: any Sendable]
        public let header: Data   // 8 或 16 bytes 外層標頭
        public let payload: Data  // 媒體資料（TVT 訊框，內含 H.264/H.265）
    }

    public enum Event: Sendable {
        case frame(Frame)
        case message(url: String, code: Int?, raw: String)
        case closed(String)
    }

    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private var requestId = 0
    public private(set) var taskId: String?

    public init(host: String, port: Int, sessionId: String) {
        let url = URL(string: "ws://\(host):\(port)/requestWebsocketConnection?sessionID=\(sessionId)")!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
    }

    /// 建立連線並等待設備回覆 create_connection
    public func connect(timeout: Duration = .seconds(10)) async throws {
        task.resume()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let msg = try await task.receive()
            if case .string(let s) = msg, let obj = Self.parseJSON(Data(s.utf8)) {
                let url = obj["url"] as? String ?? ""
                let code = (obj["data"] as? [String: Any])?["code"] as? Int
                if url == "/device/create_connection#response" {
                    if code == 0 { return }
                    throw NVMSError.device(command: url, code: code ?? -1)
                }
            }
        }
        throw NVMSError.transport("WebSocket 建立逾時")
    }

    private func basic() -> [String: Any] {
        requestId += 1
        return ["ver": "1.0", "time": Int(Date().timeIntervalSince1970 * 1000), "id": requestId,
                "nonce": Int.random(in: 1...2_147_483_646)]
    }

    public static func newTaskId() -> String { "{" + UUID().uuidString.lowercased() + "}" }

    public func send(url: String, data: [String: Any]) async throws {
        let obj: [String: Any] = ["url": url, "basic": basic(), "data": data]
        let json = try JSONSerialization.data(withJSONObject: obj)
        try await task.send(.string(String(decoding: json, as: UTF8.self)))
    }

    // MARK: - 指令（對應 websocket.cmd.js）

    /// 即時影像。streamIndex：1 = 主串流，2 = 子串流（網頁預設 2）
    public func openPreview(channelId: String, streamIndex: Int = 2, audio: Bool = false) async throws {
        let tid = Self.newTaskId()
        taskId = tid
        try await send(url: "/device/preview/open",
                       data: ["task_id": tid, "channel_id": channelId, "stream_index": streamIndex, "audio": audio])
    }

    /// 回放。時間為 Unix 秒；streamIndex：0 = 主串流，1 = 子串流（網頁預設 1）
    public func openPlayback(channelId: String, start: Int, end: Int, streamIndex: Int = 1,
                             typeMask: [String] = ["manual", "schedule", "motion", "sensor"]) async throws {
        let tid = Self.newTaskId()
        taskId = tid
        try await send(url: "/device/playback/open",
                       data: ["task_id": tid, "channel_id": channelId, "start_time": start, "end_time": end,
                              "stream_index": streamIndex, "type_mask": typeMask])
    }

    /// 網頁 frameTime2UTC：UTC "yyyy-MM-dd HH:mm:ss:S"
    public static func frameTimeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss:S"
        return f.string(from: date)
    }

    public func seek(to date: Date) async throws {
        guard let tid = taskId else { return }
        try await send(url: "/device/playback/seek", data: ["task_id": tid, "frame_time": Self.frameTimeString(date)])
    }

    /// 只傳關鍵幀（>4 倍速）／恢復全部幀；frameTime 為目前播放時間
    public func keyFrameOnly(_ on: Bool, at date: Date) async throws {
        guard let tid = taskId else { return }
        try await send(url: on ? "/device/playback/key_frame" : "/device/playback/all_frame",
                       data: ["task_id": tid, "frame_time": Self.frameTimeString(date)])
    }

    /// 播放流量控制：回報目前已播放到的訊框序號
    public func refreshPlayIndex(_ index: Int) async throws {
        guard let tid = taskId else { return }
        try await send(url: "/device/playback/refresh_play_index", data: ["task_id": tid, "play_frame_index": index])
    }

    public func close(kind: Kind) async {
        if let tid = taskId {
            try? await send(url: kind == .live ? "/device/preview/close" : "/device/playback/close", data: ["task_id": tid])
        }
        taskId = nil
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    /// 立即中斷 socket（讓等待中的 receive() 返回 .closed）
    public func cancelSocket() {
        task.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - 接收

    public func receive() async throws -> Event {
        let msg: URLSessionWebSocketTask.Message
        do {
            msg = try await task.receive()
        } catch {
            return .closed(error.localizedDescription)
        }
        switch msg {
        case .string(let s):
            let obj = Self.parseJSON(Data(s.utf8)) ?? [:]
            let url = obj["url"] as? String ?? ""
            let data = obj["data"] as? [String: Any]
            let code = (data?["code"] as? Int) ?? ((obj["basic"] as? [String: Any])?["code"] as? Int)
            return .message(url: url, code: code, raw: s)
        case .data(let d):
            if let f = try Self.parseFrame(d) {
                return .frame(f)
            }
            return .message(url: "(無法解析的二進位)", code: nil, raw: "\(d.count) bytes")
        @unknown default:
            return .closed("未知訊息類型")
        }
    }

    // MARK: - 解析

    static func parseJSON(_ d: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    public static func parseFrame(_ d: Data) throws -> Frame? {
        guard d.count >= 8 else { return nil }
        let first = d.u32le(at: 0)
        let hdr = first == 0 ? 8 : 16
        let jsonLen = Int(d.u32le(at: 4))
        guard d.count >= hdr + jsonLen else { return nil }
        let jsonData = d.subdata(in: (d.startIndex + hdr)..<(d.startIndex + hdr + jsonLen))
        guard let obj = parseJSON(jsonData) else { return nil }
        let url = obj["url"] as? String ?? ""
        let data = obj["data"] as? [String: Any] ?? [:]
        if let code = data["code"] as? Int, code != 0 {
            throw NVMSError.device(command: url, code: code)
        }
        let spec = (data["live_stream_data"] as? String) ?? (data["playback_stream_data"] as? String)
        var payload = Data()
        if let spec {
            let parts = spec.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 {
                let start = parts[0] + jsonLen + hdr
                let end = start + parts[1]
                if start >= 0, end <= d.count {
                    payload = d.subdata(in: (d.startIndex + start)..<(d.startIndex + end))
                }
            }
        }
        var flat: [String: any Sendable] = [:]
        for (k, v) in data { flat[k] = "\(v)" }
        flat["url"] = url
        return Frame(url: url, json: flat, header: d.prefix(hdr), payload: payload)
    }
}

extension Data {
    func u32le(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
