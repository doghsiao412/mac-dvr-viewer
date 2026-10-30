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
    private let passwordProvider: @Sendable () throws -> String

    private var client: NVMSClient
    private var loginTask: Task<String, Error>?
    public private(set) var channels: [DVRChannel] = []
    public private(set) var info: DeviceInfo?

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

    public init(host: String, port: Int, username: String, passwordProvider: @escaping @Sendable () throws -> String) {
        self.host = host
        self.port = port
        self.username = username
        self.passwordProvider = passwordProvider
        self.client = NVMSClient(host: host, port: port)
    }

    static let sessionErrors: Set<Int> = [536_871_011, 536_870_934]

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
        return channels
    }

    /// 在線頻道（同時作為 Session 保活）
    public func onlineChannelIds() async throws -> Set<String> {
        try await withSession { try await $0.onlineChannelIds() }
    }

    public func datesWithRecordings(channelId: String) async throws -> Set<String> {
        Set(try await withSession { try await $0.datesWithRecordings(channelIds: [channelId]) })
    }

    /// 指定日期（DVR 本地時間，假設與 Mac 時區相同）的錄影區段
    public func recordRanges(channelId: String, day: Date, timeZone: TimeZone = .current) async throws -> [RecordRange] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: day)
        let end = start.addingTimeInterval(86399)
        let f = Self.formatter(timeZone)
        let segs = try await withSession {
            try await $0.recordLog(channelId: channelId, start: f.string(from: start), end: f.string(from: end))
        }
        return segs.compactMap { s in
            guard let a = f.date(from: s.start), let b = f.date(from: s.end) else { return nil }
            return RecordRange(type: s.type, start: a, end: b)
        }.sorted { $0.start < $1.start }
    }

    public func disconnect() async {
        await client.logout()
    }

    static func formatter(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }
}
