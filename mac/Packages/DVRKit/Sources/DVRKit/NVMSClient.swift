import Foundation

/// NVMS-9000 平台的 HTTP XML API 用戶端（DVR 網頁介面使用的同一套 API）。
///
/// 協定來源：DVR 網頁前端 `js/lib/Communication.js`、`js/app/login.js`（已於實體 DVR 讀取）。
/// - 每個指令都是 `POST /<指令名>`，Body 為 XML：
///   `<request version="1.0" systemType="NVMS-9000" clientType="WEB">…</request>`
/// - `doLogin` 的 `<password>` 是 Base64(明文密碼)；成功後回傳 `sessionId`
/// - 之後的請求以 Cookie `sessionId=<id>` 維持 Session
public actor NVMSClient {
    public nonisolated let host: String
    public nonisolated let port: Int
    public private(set) var sessionId: String?
    public private(set) var loginInfo: LoginInfo?

    private let session: URLSession

    public struct LoginInfo: Sendable {
        public let userId: String
        public let authGroupId: String
        public let adminName: String
    }

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    public var baseURL: URL { URL(string: "http://\(host):\(port)/")! }

    // MARK: - XML 組裝

    static let xmlHeader = #"<?xml version="1.0" encoding="utf-8" ?>"#

    static func emptyRequest() -> String {
        xmlHeader + #"<request version="1.0" systemType="NVMS-9000" clientType="WEB"/>"#
    }

    static func request(_ inner: String) -> String {
        xmlHeader + #"<request version="1.0" systemType="NVMS-9000" clientType="WEB">"# + inner + "</request>"
    }

    static func cdata(_ s: String) -> String {
        "<![CDATA[" + s.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>") + "]]>"
    }

    // MARK: - 傳送

    /// 傳送指令並回傳 `<response>` 根節點。`status != success` 時丟出 `NVMSError.device`。
    @discardableResult
    public func call(_ command: String, body: String? = nil) async throws -> DVRXMLElement {
        var req = URLRequest(url: baseURL.appending(path: command))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let sid = sessionId {
            req.setValue("sessionId=\(sid)", forHTTPHeaderField: "Cookie")
        }
        req.httpBody = Data((body ?? Self.emptyRequest()).utf8)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw NVMSError.transport("非 HTTP 回應") }
        guard http.statusCode == 200 else { throw NVMSError.http(http.statusCode) }
        let root = try DVRXMLElement.parse(data)
        let status = root.text("status")
        if status != "success" {
            let code = Int(root.text("errorCode") ?? "") ?? -1
            throw NVMSError.device(command: command, code: code)
        }
        return root
    }

    // MARK: - Session

    public func login(user: String, password: String) async throws -> LoginInfo {
        let pw64 = Data(password.utf8).base64EncodedString()
        let body = Self.request(
            "<content><userName>\(Self.cdata(user))</userName><password>\(Self.cdata(pw64))</password></content>")
        let root = try await call("doLogin", body: body)
        guard var sid = root.text("content/sessionId"), !sid.isEmpty else {
            throw NVMSError.badXML("doLogin 回應沒有 sessionId")
        }
        if let a = sid.firstIndex(of: "{"), let b = sid.lastIndex(of: "}"), a < b {
            sid = String(sid[sid.index(after: a)..<b])
        }
        sessionId = sid
        let info = LoginInfo(
            userId: root.text("content/userId") ?? "",
            authGroupId: root.text("content/authGroupId") ?? "",
            adminName: root.text("content/adminName") ?? "")
        loginInfo = info
        return info
    }

    public func logout() async {
        guard sessionId != nil else { return }
        _ = try? await call("doLogout")
        sessionId = nil
    }

    // MARK: - 查詢

    public func systemCaps() async throws -> [String: String] {
        try await call("querySystemCaps").flatContent()
    }

    public func basicConfig() async throws -> [String: String] {
        try await call("queryBasicCfg").flatContent()
    }

    public func timeConfig() async throws -> [String: String] {
        try await call("queryTimeCfg").flatContent()
    }

    /// 頻道清單（`queryNodeList`，nodeType=chls）
    public func channels() async throws -> [DVRChannel] {
        let body = Self.request(
            #"<types><nodeType><enum>chls</enum><enum>sensors</enum><enum>alarmOuts</enum></nodeType></types>"#
                + #"<nodeType type="nodeType">chls</nodeType><condition></condition>"#
                + "<requireField><name/><chlIndex/><chlType/><ip/></requireField>")
        let root = try await call("queryNodeList", body: body)
        return root.elements(forPath: "content/item").enumerated().map { idx, item in
            DVRChannel(
                id: item.attribute("id") ?? "",
                name: item.text("name") ?? "",
                index: Int(item.text("chlIndex") ?? "") ?? idx,
                type: item.text("chlType"))
        }
    }

    /// 目前在線的頻道 ID
    public func onlineChannelIds() async throws -> Set<String> {
        let root = try await call("queryOnlineChlList")
        return Set(root.elements(forPath: "content/item").compactMap { $0.attribute("id") })
    }

    /// 有錄影的頻道 ID
    public func channelsWithRecordings() async throws -> Set<String> {
        let root = try await call("queryChlsExistRec")
        return Set(root.elements(forPath: "content/item").compactMap { $0.attribute("id") })
    }

    /// 有錄影的日期（回傳 DVR 原始字串）
    public func datesWithRecordings(channelIds: [String]) async throws -> [String] {
        let cond = channelIds.map { "<chlId>\($0)</chlId>" }.joined()
        let root = try await call("queryDatesExistRec", body: Self.request("<condition>\(cond)</condition>"))
        return root.elements(forPath: "content/item").compactMap { $0.attribute("date") ?? $0.stringValue }
    }

    /// 指定時間範圍的錄影區段（`queryChlRecLog`）。時間為 DVR 本地時間 "yyyy-MM-dd HH:mm:ss"（網頁 getTimeRangeByDate 不轉 UTC）。
    public func recordLog(channelId: String, start: String, end: String,
                          types: [String] = ["MOTION", "SCHEDULE", "SENSOR", "MANUAL", "INTELLIGENT", "POS"])
        async throws -> [RecordSegment]
    {
        var x = "<types><recType>" + types.map { "<enum>\($0)</enum>" }.joined() + "</recType></types>"
        x += "<requireField><chl/><recList><item><recType/><startTime/><endTime/><size/></item></recList></requireField>"
        x += "<condition><startTime>\(start)</startTime><endTime>\(end)</endTime>"
        x += "<recType type='list'><itemType type='recType'/>" + types.map { "<item>\($0)</item>" }.joined() + "</recType>"
        x += "<chl id='\(channelId)'></chl></condition>"
        let root = try await call("queryChlRecLog", body: Self.request(x))
        return root.elements(forPath: "content/recList/item").map {
            RecordSegment(
                type: $0.text("recType") ?? "",
                subType: $0.text("recSubType"),
                start: $0.text("startTime") ?? "",
                end: $0.text("endTime") ?? "",
                size: Int64($0.text("size") ?? ""))
        }
    }

    /// 系統日誌中的警報（`queryLog`，依據網頁 System/viewLog.js）。時間為 **UTC** "yyyy-MM-dd HH:mm:ss"。
    /// 需要帳號有「日誌」權限，否則回傳 536870953。
    public func alarmLog(start: String, end: String, types: [String] = ["LOG_ALARM_MOTION"],
                         pageIndex: Int = 1, pageSize: Int = 200) async throws -> (items: [AlarmLogItem], total: Int)
    {
        var x = "<pageIndex>\(pageIndex)</pageIndex><pageSize>\(pageSize)</pageSize>"
        x += "<types><logType>" + types.map { "<enum>\($0)</enum>" }.joined() + "</logType></types>"
        x += "<condition><logType type=\"list\"><itemType type=\"logType\"/>"
        x += types.map { "<item>\(Self.cdata($0))</item>" }.joined()
        x += "</logType><startTime>\(Self.cdata(start))</startTime><endTime>\(Self.cdata(end))</endTime></condition>"
        let root = try await call("queryLog", body: Self.request(x))
        let content = root.elements(forName: "content").first
        let total = Int(content?.attribute("total") ?? "") ?? 0
        let items = root.elements(forPath: "content/item").map { e in
            AlarmLogItem(
                type: e.text("logType") ?? "",
                time: e.text("time") ?? "",
                channelId: e.elements(forName: "chl").first?.attribute("id"),
                triggerChannelIds: e.elements(forPath: "triggerRecChls/item").compactMap { $0.attribute("id") })
        }
        return (items, total)
    }

    /// 不解析、直接回傳原始 XML（開發探索用；呼叫端負責遮蔽）
    public func raw(_ command: String, body: String? = nil) async throws -> String {
        try await call(command, body: body).xmlString
    }
}

public struct DVRChannel: Sendable, Hashable, Identifiable {
    public let id: String      // 例如 "{00000001-0000-0000-0000-000000000000}"
    public let name: String
    public let index: Int
    public let type: String?
}

public struct RecordSegment: Sendable, Hashable {
    public let type: String
    public let subType: String?
    public let start: String
    public let end: String
    public let size: Int64?
}

public struct AlarmLogItem: Sendable, Hashable {
    public let type: String          // LOG_ALARM_MOTION …
    public let time: String          // UTC
    public let channelId: String?
    public let triggerChannelIds: [String]
}

public enum NVMSError: Error, CustomStringConvertible {
    case transport(String)
    case http(Int)
    case badXML(String)
    case device(command: String, code: Int)

    public var description: String {
        switch self {
        case .transport(let s): return "連線錯誤：\(s)"
        case .http(let c): return "HTTP 狀態碼 \(c)"
        case .badXML(let s): return "XML 解析失敗：\(s)"
        case .device(let cmd, let code): return "\(cmd) 失敗：\(NVMSError.describe(code))（\(code)）"
        }
    }

    /// 錯誤碼來源：DVR 網頁 login.js / Communication.js / index.js
    public static func describe(_ code: Int) -> String {
        switch code {
        case 536870947, 536870948: return "帳號或密碼錯誤"
        case 536870951: return "帳號已被鎖定"
        case 536870953: return "此帳號沒有權限"
        case 536870942, 513: return "沒有錄影資料"
        case 536870960: return "設備忙碌中"
        case 536871011, 536870934: return "登入逾時／Session 失效"
        case 536870943: return "參數錯誤"
        case 536870913: return "節點已存在"
        case 536870923: return "資源不存在"
        case 536870962: return "無設定資料"
        case 536870961: return "無錄影資料或播放結束"
        default: return "設備錯誤"
        }
    }
}

extension NVMSError: LocalizedError {
    public var errorDescription: String? { description }
}
