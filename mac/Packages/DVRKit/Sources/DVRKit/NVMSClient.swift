import CryptoKit
import Foundation

/// NVMS-9000 平台的 HTTP XML API 用戶端（DVR 網頁介面使用的同一套 API）。
///
/// 協定來源：DVR 網頁前端 `js/lib/Communication.js`、`js/app/login.js`（已於實體 DVR 讀取）。
/// - 每個指令都是 `POST /<指令名>`，Body 為 XML：
///   `<request version="1.0" systemType="NVMS-9000" clientType="WEB">…</request>`
/// - 登入有兩種（依 DVR 是否支援 `reqLogin` 自動選擇）：
///   - 部分韌體（例如網頁資源 2020 年版）：先 `POST /reqLogin` 取 `nonce`／`token`／`sessionId`，
///     `doLogin` 的密碼為 SHA1 大寫 hex（MD5 大寫 hex(明文密碼) + nonce），之後每個請求的 XML 都帶 `<token>`
///   - 其他（`reqLogin` 回失敗）：`doLogin` 的 `<password>` 是 Base64(明文密碼)；成功後回傳 `sessionId`
/// - 之後的請求以 Cookie `sessionId=<id>` 維持 Session
public actor NVMSClient {
    public nonisolated let host: String
    public nonisolated let port: Int
    public private(set) var sessionId: String?
    public private(set) var loginInfo: LoginInfo?
    /// reqLogin 取得的 token（有的韌體每個請求都要帶）
    public private(set) var token: String?
    /// nonce 登入時 doLogin 回傳的另一組 sessionId（網頁用 reqLogin 的；被判定失效時改用這組試一次）
    private var altSessionId: String?
    /// nonce 登入後尚未有任何指令成功（第一個指令就失效時附上診斷，不觸發重新登入以免多耗嘗試次數）
    private var nonceSessionUnconfirmed = false
    /// doLogin 回應的欄位名稱（不含內容），診斷用
    private var loginResponseFields = ""

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

    /// 在 `<request …>` 開頭插入 `<token>`（自閉合的空請求會展開）
    static func withToken(_ body: String, _ token: String) -> String {
        guard !body.contains("<token>") else { return body }
        let t = "<token>\(token)</token>"
        if let r = body.range(of: #"<request [^>]*?/>"#, options: .regularExpression) {
            let open = String(body[r].dropLast(2)) + ">"
            return body.replacingCharacters(in: r, with: open + t + "</request>")
        }
        if let r = body.range(of: #"<request [^>]*>"#, options: .regularExpression) {
            return body.replacingCharacters(in: r, with: String(body[r]) + t)
        }
        return body
    }

    /// nonce 登入的密碼：SHA1 大寫 hex（MD5 大寫 hex(明文密碼) + nonce）（DVR 網頁 login.js、spark-md5.js、sha1.js）
    static func hashedPassword(_ password: String, nonce: String) -> String {
        func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02X", $0) }.joined() }
        let md5 = hex(Insecure.MD5.hash(data: Data(password.utf8)))
        return hex(Insecure.SHA1.hash(data: Data((md5 + nonce).utf8)))
    }

    static func cdata(_ s: String) -> String {
        "<![CDATA[" + s.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>") + "]]>"
    }

    // MARK: - 傳送

    /// 傳送指令並回傳 `<response>` 根節點。`status != success` 時丟出 `NVMSError.device`。
    @discardableResult
    public func call(_ command: String, body: String? = nil) async throws -> DVRXMLElement {
        var root = try await post(command, body: body)
        var code = Int(root.text("errorCode") ?? "") ?? -1
        // nonce 登入後第一次被判定 Session 失效：改用 doLogin 回傳的 sessionId 再試一次（不重新送密碼）
        if root.text("status") != "success", [536_870_934, 536_871_011].contains(code), let alt = altSessionId {
            altSessionId = nil
            sessionId = alt
            root = try await post(command, body: body)
            code = Int(root.text("errorCode") ?? "") ?? -1
        }
        if root.text("status") != "success" {
            if nonceSessionUnconfirmed, [536_870_934, 536_871_011].contains(code) {
                nonceSessionUnconfirmed = false
                throw NVMSError.transport("登入成功但 DVR 不接受之後的查詢（\(command) \(code)）。診斷：驗證碼登入，doLogin 回應欄位［\(loginResponseFields)］")
            }
            throw NVMSError.device(command: command, code: code)
        }
        if command != "reqLogin" && command != "doLogin" { altSessionId = nil; nonceSessionUnconfirmed = false }   // 這組已確認可用
        return root
    }

    /// 傳送指令並回傳 `<response>`（不檢查 status）
    private func post(_ command: String, body: String?) async throws -> DVRXMLElement {
        var req = URLRequest(url: baseURL.appending(path: command))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let sid = sessionId {
            req.setValue("sessionId=\(sid)", forHTTPHeaderField: "Cookie")
        }
        var xml = body ?? Self.emptyRequest()
        if let token { xml = Self.withToken(xml, token) }
        req.httpBody = Data(xml.utf8)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw NVMSError.transport("非 HTTP 回應") }
        guard http.statusCode == 200 else { throw NVMSError.http(http.statusCode) }
        return try DVRXMLElement.parse(data)
    }

    // MARK: - Session

    public func login(user: String, password: String) async throws -> LoginInfo {
        sessionId = nil
        token = nil
        altSessionId = nil
        // 1. 支援 reqLogin 的韌體：取 nonce／token／sessionId，密碼送雜湊；不支援（回失敗）就用 Base64
        var pw = Data(password.utf8).base64EncodedString()
        if let r = try? await call("reqLogin", body: Self.request("<token>null</token>")),
           let nonce = r.text("content/nonce"), !nonce.isEmpty,
           let tk = r.text("content/token"), !tk.isEmpty {
            token = tk
            sessionId = r.text("content/sessionId").map(Self.stripBraces)
            pw = Self.hashedPassword(password, nonce: nonce)
        }
        // 2. doLogin（只送一次，不換格式重試，避免帳號被鎖）
        let body = Self.request(
            "<content><userName>\(Self.cdata(user))</userName><password>\(Self.cdata(pw))</password></content>")
        let root = try await post("doLogin", body: body)
        guard root.text("status") == "success" else {
            let code = Int(root.text("errorCode") ?? "") ?? -1
            sessionId = nil
            token = nil
            throw NVMSError.loginFailed(code: code,
                                        remaining: (root.text("ramainingNumber") ?? root.text("content/ramainingNumber")).flatMap { Int($0) },
                                        locked: (root.text("locked") ?? root.text("content/locked")) == "true")
        }
        // 3. sessionId：nonce 登入照網頁沿用 reqLogin 的（doLogin 的另存備用）；Base64 登入用 doLogin 回傳的
        altSessionId = nil
        nonceSessionUnconfirmed = token != nil
        loginResponseFields = (root.elements(forName: "content").first?.children ?? root.children).map(\.name).joined(separator: "、")
        if let s = root.text("content/sessionId").map(Self.stripBraces), !s.isEmpty {
            if token != nil, let current = sessionId {
                if s != current { altSessionId = s }
            } else {
                sessionId = s
            }
        }
        guard sessionId != nil else { throw NVMSError.badXML("doLogin 回應沒有 sessionId") }
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
        token = nil
    }

    static func stripBraces(_ s: String) -> String {
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b { return String(s[s.index(after: a)..<b]) }
        return s
    }

    // MARK: - 查詢

    public func systemCaps() async throws -> [String: String] {
        try await call("querySystemCaps").flatContent()
    }

    public func basicConfig() async throws -> [String: String] {
        try await call("queryBasicCfg").flatContent()
    }

    /// DVR 自己設定的影像服務（SERVICE，私有協定）Port，取自 `queryUPnPCfg`。
    /// UPnP 開啟且對應成功時用路由器對外的 Port，否則用 DVR 本機的 Port（路由器通常同號轉發）。
    public func servicePortSetting() async throws -> Int? {
        let root = try await call("queryUPnPCfg")
        return Self.servicePort(fromUPnP: root)
    }

    static func servicePort(fromUPnP root: DVRXMLElement) -> Int? {
        let upnpOn = root.text("content/switch") == "true"
        guard let item = root.elements(forPath: "content/ports/item").first(where: { $0.text("portType") == "SERVICE" })
        else { return nil }
        let local = item.text("localPort").flatMap { Int($0) }
        let external = item.text("externalPort").flatMap { Int($0) }
        let valid: (Int?) -> Int? = { p in p.flatMap { (1...65535).contains($0) ? $0 : nil } }
        if upnpOn, item.text("status") == "effective", let e = valid(external) { return e }
        return valid(local) ?? valid(external)
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

    // MARK: - 雲台（DVR 網頁 js/lib/PtzCtrl.js、js/app/Live/live.js）

    /// 支援雲台的頻道 ID（queryNodeList 條件 `<supportPtz/>`；網頁排除 factoryName = Recorder）
    public func ptzChannelIds() async throws -> Set<String> {
        let body = Self.request(#"<nodeType type="nodeType">chls</nodeType><condition><supportPtz/></condition>"#
                                + "<requireField><name/><productModel/></requireField>")
        let root = try await call("queryNodeList", body: body)
        return Set(root.elements(forPath: "content/item").compactMap { item -> String? in
            if item.elements(forName: "productModel").first?.attribute("factoryName") == "Recorder" { return nil }
            return item.attribute("id")
        })
    }

    /// 雲台動作：Up／Down／Left／Right／LeftUp／LeftDown／RightUp／RightDown／ZoomIn／ZoomOut／Near／Far／IrisOpen／IrisClose；
    /// 放開時送 StopAction。speed 1–8（網頁預設 4）
    public func ptzMove(channelId: String, action: String, speed: Int) async throws {
        try await call("ptzMoveCall", body: Self.request(
            "<content><chlId>\(channelId)</chlId><actionType>\(action)</actionType><speed>\(min(max(speed, 1), 8))</speed></content>"))
    }

    /// 預置點（index, 名稱）
    public func ptzPresets(channelId: String) async throws -> [(index: Int, name: String)] {
        let root = try await call("queryChlPresetList", body: Self.request("<condition><chlId>\(channelId)</chlId></condition>"))
        return root.elements(forPath: "content/presets/item").enumerated().map { i, item in
            (Int(item.attribute("index") ?? "") ?? i, item.stringValue)
        }
    }

    public func ptzGoToPreset(channelId: String, index: Int, speed: Int) async throws {
        try await call("goToPtzPreset", body: Self.request(
            "<content><chlId>\(channelId)</chlId><index>\(index)</index><speed>\(min(max(speed, 1), 8))</speed></content>"))
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
    /// 登入被拒（remaining：DVR 回報的剩餘嘗試次數）
    case loginFailed(code: Int, remaining: Int?, locked: Bool)

    public var description: String {
        switch self {
        case .transport(let s): return "連線錯誤：\(s)"
        case .http(let c): return "HTTP 狀態碼 \(c)"
        case .badXML(let s): return "XML 解析失敗：\(s)"
        case .device(let cmd, let code): return "\(cmd) 失敗：\(NVMSError.describe(code))（\(code)）"
        case .loginFailed(let code, let remaining, let locked):
            var m = "登入失敗：\(NVMSError.describe(code))（\(code)）"
            if locked { m += "；帳號已被 DVR 暫時鎖定，請稍後再試" }
            else if let remaining { m += "；DVR 剩餘嘗試次數 \(remaining)" }
            return m
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
