import Foundation

/// 單台 DVR 的連線管理（ConnectionManager）。
///
/// - 登入只會同時進行一次（多個播放器同時要求 Session 時共用同一次登入）
/// - Session 失效（536871011 / 536870934）時自動重新登入並重試一次
/// - 密碼不保存在記憶體中，每次登入時由 `passwordProvider` 從 Keychain 取得
public actor DVRConnection {
    public nonisolated let host: String
    public nonisolated let port: Int
    public nonisolated let username: String
    /// TVT 私有協定（SERVICE）連接埠：韌體不支援 WebSocket 時使用
    public nonisolated let servicePort: Int
    private let passwordProvider: @Sendable () throws -> String
    private var privateClient: TVTPrivateClient?
    private var privateConnectTask: Task<TVTPrivateClient, Error>?
    /// 強制使用私有協定（測試用）
    public var forcePrivateProtocol = false

    private var client: NVMSClient
    private var loginTask: Task<String, Error>?
    public private(set) var channels: [DVRChannel] = []
    public private(set) var info: DeviceInfo?
    /// DVR 韌體是否支援 WebSocket 影像串流（較舊的 NVMS-9000 韌體只支援瀏覽器外掛／私有協定）
    public private(set) var supportsWebStreaming: Bool?

    public struct DeviceInfo: Sendable, Equatable {
        public let name: String
        public let model: String
        public let firmware: String
        public let analogChannels: Int
        public let ipChannels: Int
    }

    /// 錄影區段（時間已換算成 Date）
    public struct RecordRange: Sendable, Hashable {
        public let type: String
        public let start: Date
        public let end: Date
    }

    public init(host: String, port: Int, username: String, servicePort: Int = 6036,
                passwordProvider: @escaping @Sendable () throws -> String) {
        self.host = host
        self.port = port
        self.username = username
        self.servicePort = servicePort
        self.passwordProvider = passwordProvider
        self.client = NVMSClient(host: host, port: port)
    }

    static let sessionErrors: Set<Int> = [536_871_011, 536_870_934]
    /// 「沒有錄影資料」：較舊韌體在當天無錄影時回傳錯誤而非空清單（536870942）
    static let noRecordErrors: Set<Int> = [536_870_942, 513]

    public static func isSessionError(_ e: Error) -> Bool {
        if case NVMSError.device(_, let code) = e { return sessionErrors.contains(code) }
        return false
    }

    /// 取得有效的 sessionId（必要時登入）
    public func sessionId() async throws -> String {
        if let sid = await client.sessionId { return sid }
        return try await login()
    }

    private func login() async throws -> String {
        if let t = loginTask { return try await t.value }
        let client = self.client
        let user = username
        let provider = passwordProvider
        let t = Task<String, Error> {
            let pw = try provider()
            _ = try await client.login(user: user, password: pw)
            guard let sid = await client.sessionId else { throw NVMSError.badXML("無 sessionId") }
            return sid
        }
        loginTask = t
        defer { loginTask = nil }
        return try await t.value
    }

    /// 強制重新登入（Session 失效時）
    public func relogin() async throws {
        client = NVMSClient(host: host, port: port)
        _ = try await login()
    }

    /// 執行查詢；Session 失效時重新登入並重試一次
    private func withSession<T: Sendable>(_ op: @Sendable (NVMSClient) async throws -> T) async throws -> T {
        _ = try await sessionId()
        do {
            return try await op(client)
        } catch where Self.isSessionError(error) {
            try await relogin()
            return try await op(client)
        }
    }

    /// 登入並載入設備資訊與頻道
    @discardableResult
    public func connect() async throws -> [DVRChannel] {
        _ = try await sessionId()
        let caps = try await withSession { try await $0.systemCaps() }
        let basic = (try? await withSession { try await $0.basicConfig() }) ?? [:]
        info = DeviceInfo(
            name: basic["name"] ?? host,
            model: basic["TVTProductModel"] ?? basic["productModel"] ?? "",
            firmware: basic["softwareVersion"] ?? "",
            analogChannels: Int(caps["analogChlCount"] ?? "") ?? 0,
            ipChannels: Int(caps["ipChlMaxCount"] ?? "") ?? 0)
        channels = try await withSession { try await $0.channels() }
        // 韌體類型不會變：已知就不再偵測。DVR 忙碌（多路串流）時網頁回應可能逾時，
        // 不能把已知結果覆蓋成「未知」，否則所有畫面會停下來等待。
        if supportsWebStreaming == nil {
            for attempt in 0..<3 where supportsWebStreaming == nil {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                supportsWebStreaming = await Self.probeWebStreaming(host: host, port: port)
            }
        }
        return channels
    }

    /// 以 DVR 網頁是否提供 `js/lib/websocket.cmd.js` 判斷（2019 版韌體為 404，2021 版為 200）
    /// 再偵測一次韌體類型（先前逾時、仍未知時使用）
    @discardableResult
    public func reprobeWebStreamingIfNeeded() async -> Bool? {
        if supportsWebStreaming == nil { supportsWebStreaming = await Self.probeWebStreaming(host: host, port: port) }
        return supportsWebStreaming
    }

    static func probeWebStreaming(host: String, port: Int) async -> Bool? {
        guard let url = URL(string: "http://\(host):\(port)/js/lib/websocket.cmd.js") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 200 { return true }
        if http.statusCode == 404 { return false }
        return nil
    }

    /// 在線頻道（同時作為 Session 保活）
    public func onlineChannelIds() async throws -> Set<String> {
        try await withSession { try await $0.onlineChannelIds() }
    }

    public func datesWithRecordings(channelId: String) async throws -> Set<String> {
        do {
            return Set(try await withSession { try await $0.datesWithRecordings(channelIds: [channelId]) })
        } catch NVMSError.device(_, let code) where Self.noRecordErrors.contains(code) {
            return []
        }
    }

    /// 與指定日期最接近、有錄影的前後日期（DVR 本地日期，假設與 Mac 時區相同）
    public func nearestRecordingDays(channelId: String, around day: Date, timeZone: TimeZone = .current) async throws -> (before: Date?, after: Date?) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        let days = try await datesWithRecordings(channelId: channelId).compactMap { f.date(from: String($0.prefix(10))) }.sorted()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let d = cal.startOfDay(for: day)
        return (days.last { $0 < d }, days.first { $0 > d })
    }

    /// 指定日期（DVR 本地時間，假設與 Mac 時區相同）的錄影區段
    public func recordRanges(channelId: String, day: Date, timeZone: TimeZone = .current) async throws -> [RecordRange] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: day)
        let end = start.addingTimeInterval(86399)
        let f = Self.formatter(timeZone)
        let segs: [RecordSegment]
        do {
            segs = try await withSession {
                try await $0.recordLog(channelId: channelId, start: f.string(from: start), end: f.string(from: end))
            }
        } catch NVMSError.device(_, let code) where Self.noRecordErrors.contains(code) {
            return []
        }
        return segs.compactMap { s in
            guard let a = f.date(from: s.start), let b = f.date(from: s.end) else { return nil }
            return RecordRange(type: s.type, start: a, end: b)
        }.sorted { $0.start < $1.start }
    }

    public func disconnect() async {
        await client.logout()
        if let p = privateClient { await p.disconnect() }
        privateClient = nil
    }

    public func setForcePrivateProtocol(_ on: Bool) { forcePrivateProtocol = on }

    // MARK: - 影像串流（自動選擇 WebSocket 或私有協定）

    public var usesPrivateProtocol: Bool { forcePrivateProtocol || supportsWebStreaming == false }

    func channel(_ id: String) -> DVRChannel? { channels.first { $0.id == id } }

    /// 取得已登入的私有協定連線（共用一條 TCP；斷線時重連）
    private func privateSession() async throws -> TVTPrivateClient {
        if let c = privateClient, await c.isConnected { return c }
        if let t = privateConnectTask { return try await t.value }
        let host = host, port = servicePort, user = username, provider = passwordProvider
        let t = Task<TVTPrivateClient, Error> {
            let c = TVTPrivateClient(host: host, port: port)
            try await c.connect(user: user, password: try provider())
            return c
        }
        privateConnectTask = t
        defer { privateConnectTask = nil }
        let c = try await t.value
        privateClient = c
        return c
    }

    public func openLive(channelId: String, mainStream: Bool, audio: Bool = false) async throws -> MediaStream {
        if channels.isEmpty { _ = try await connect() }
        if usesPrivateProtocol {
            guard let ch = channel(channelId) else { throw NVMSError.badXML("找不到頻道") }
            return try await openPrivateLive(ch, mainStream: mainStream)
        }
        // DVR 的網頁伺服器同時只接受有限條 WebSocket（實測 TD-2716NE-HC 為 6 條），
        // 超過時改用私有協定（一條 TCP 可同時傳多路，SuperLive Plus 也是如此）。
        if let cap = webLiveCap, activeWebLive >= cap, let ch = channel(channelId),
           let ms = try? await openPrivateLiveIfAvailable(ch, mainStream: mainStream) {
            return ms
        }
        let sid = try await sessionId()
        do {
            var ms = try await MediaStream.webSocket(host: host, port: port, sessionId: sid, live: true) { ws in
                try await ws.openPreview(channelId: channelId, streamIndex: mainStream ? 1 : 2)
            }
            activeWebLive += 1
            let inner = ms.close
            let closed = FlagBox()
            ms.close = { [weak self] in
                await inner()
                if !closed.value { closed.set(); await self?.webLiveClosed() }
            }
            return ms
        } catch {
            // 連線層級被拒（非 DVR 指令錯誤）→ 視為已達 WebSocket 上限
            if case NVMSError.device = error { throw error }
            webLiveCap = max(activeWebLive, 1)
            if let ch = channel(channelId), let ms = try? await openPrivateLiveIfAvailable(ch, mainStream: mainStream) {
                return ms
            }
            throw NVMSError.transport("DVR 同時影像連線已達上限，且無法連到影像服務 Port \(servicePort)（請在設備設定確認此 Port）")
        }
    }

    /// 目前開著的 WebSocket 即時串流數與偵測到的上限
    private var activeWebLive = 0
    private var webLiveCap: Int?
    /// 私有協定連不上時，暫停嘗試到此時間（避免每格都等逾時）
    private var privateRetryAfter: Date?

    private func webLiveClosed() { activeWebLive = max(activeWebLive - 1, 0) }

    private func openPrivateLiveIfAvailable(_ ch: DVRChannel, mainStream: Bool) async throws -> MediaStream {
        if let t = privateRetryAfter, t > Date() { throw NVMSError.transport("私有協定暫時無法連線") }
        do { return try await openPrivateLive(ch, mainStream: mainStream) } catch {
            privateRetryAfter = Date().addingTimeInterval(60)
            throw error
        }
    }

    private func openPrivateLive(_ ch: DVRChannel, mainStream: Bool) async throws -> MediaStream {
        let c = try await privateSession()
        let (task, frames) = try await c.openLive(channelGUID: ch.id, chNo: ch.index, streamType: mainStream ? 1 : 2)
        let audioTask = AudioTaskBox()
        var ms = MediaStream(frames: frames, acknowledge: { _ in }, setKeyFrameOnly: nil,
                             close: {
                                 if let t = audioTask.take() { await c.closeLiveAudio(channelGUID: ch.id, chNo: ch.index, task: t) }
                                 await c.closeLive(channelGUID: ch.id, chNo: ch.index, task: task)
                             },
                             transport: "私有協定")
        // 聲音：獨立的 0x501／0x502 任務，可在串流中途開關
        ms.setAudio = { on in
            if on {
                guard audioTask.peek() == nil else { return }
                if let t = try? await c.openLiveAudio(channelGUID: ch.id, chNo: ch.index) { audioTask.set(t) }
            } else if let t = audioTask.take() {
                await c.closeLiveAudio(channelGUID: ch.id, chNo: ch.index, task: t)
            }
        }
        return ms
    }

    public func openPlayback(channelId: String, start: Date, end: Date, mainStream: Bool,
                             typeMask: [String]) async throws -> MediaStream {
        if channels.isEmpty { _ = try await connect() }
        if usesPrivateProtocol {
            guard let ch = channel(channelId) else { throw NVMSError.badXML("找不到頻道") }
            let c = try await privateSession()
            let (task, frames) = try await c.openPlayback(chNo: ch.index, start: start, end: end)
            return MediaStream(frames: frames, acknowledge: { idx in await c.acknowledge(task: task, index: idx) },
                               setKeyFrameOnly: nil,
                               close: { await c.closePlayback(task: task, chNo: ch.index, start: start, end: end) },
                               transport: "私有協定")
        }
        let sid = try await sessionId()
        return try await MediaStream.webSocket(host: host, port: port, sessionId: sid, live: false) { ws in
            try await ws.openPlayback(channelId: channelId, start: Int(start.timeIntervalSince1970),
                                      end: Int(end.timeIntervalSince1970), streamIndex: mainStream ? 0 : 1, typeMask: typeMask)
        }
    }

    static func formatter(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }
}

/// 私有協定即時聲音任務 GUID（跨 Task 共用）
final class AudioTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Data?
    func set(_ t: Data) { lock.withLock { task = t } }
    func peek() -> Data? { lock.withLock { task } }
    func take() -> Data? { lock.withLock { defer { task = nil }; return task } }
}
