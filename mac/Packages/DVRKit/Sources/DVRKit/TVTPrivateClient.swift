import Foundation
import Network

/// TVT NVMS-9000 私有協定用戶端（SERVICE Port，預設 6036）。
///
/// 給「不支援 WebSocket 串流」的較舊韌體使用。格式由 SuperLive Plus 封包分析而得，
/// 詳見 docs/protocol-analysis.md §0.4。
///
/// ```
/// 訊息：  "1111" | u32 len | u32 cmd | u32 sub | u32 id | u32 dataLen | [route 72] | data
///   cmd 0x01000003 直接請求；0x01020003 路由請求（多 72 bytes 路由區塊）；回覆把 …003 換成 …006、sub |= 0x10000000
///   0x00000006 sub 0x00010001 → 即時 SHFL；0x00020006 sub 0x00020001 → 回放 SHFL（含路由區塊）
///   "1111" + len 0 → 心跳
/// 路由區塊： GUID 請求 | GUID session | GUID 目標（頻道或設備）| u32 2 | GUID 任務 | u32 op
/// ```
/// 安全性：登入密碼以明文傳送（設備宣告 loginEncrypt=0）。
public actor TVTPrivateClient {
    public nonisolated let host: String
    public nonisolated let port: Int

    public enum ClientError: Error, CustomStringConvertible {
        case loginFailed(UInt32)
        case timeout(String)
        case disconnected
        case badReply(String)

        public var description: String {
            switch self {
            case .loginFailed(let c): return "私有協定登入失敗（\(String(format: "0x%08X", c))）：帳號或密碼錯誤、或帳號無遠端權限"
            case .timeout(let s): return "私有協定逾時：\(s)"
            case .disconnected: return "私有協定連線已中斷"
            case .badReply(let s): return "私有協定回覆無法解析：\(s)"
            }
        }
    }

    struct Reply: Sendable {
        let cmd: UInt32
        let sub: UInt32
        let data: Data
    }

    private var link: TCPLink?
    private var buffer = Data()
    private var fragments: [UInt32: Data] = [:]
    private var nextId: UInt32 = 0
    private var pending: [UInt32: CheckedContinuation<Reply, Error>] = [:]
    /// 即時影像接收端，以頻道序號（SHFL offset 8，1 起）區分；同一頻道只送給最新開啟的任務。
    /// 記下任務 GUID：舊任務關閉時（例如放大畫面時分割畫面那格關閉）不可把新任務的接收端一起關掉。
    private var liveSinks: [UInt32: (task: Data, cont: AsyncThrowingStream<Data, Error>.Continuation)] = [:]
    private var taskSinks: [Data: AsyncThrowingStream<Data, Error>.Continuation] = [:]    // 回放任務 GUID
    private var readerTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var username = ""
    public private(set) var sessionGUID = Data(count: 16)
    public private(set) var deviceGUID = Data(count: 16)
    public private(set) var isConnected = false
    /// 登入回應原始資料（含設備 GUID 等；用來辨識連到的是哪一台設備）
    public private(set) var loginReply = Data()

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    // MARK: - 連線與登入

    public func connect(user: String, password: String) async throws {
        disconnect()
        let l = TCPLink(host: host, port: port)
        try await l.start()
        link = l
        buffer = Data()
        fragments = [:]
        nextId = 0
        username = user
        readerTask = Task { [weak self] in await self?.readLoop(l) }

        var p = Data(count: 236)
        p.putU32(3, at: 0)
        p.putString(user, at: 36, max: 63)
        p.putString(password, at: 100, max: 63)
        p.putU32(0xCD, at: 200)
        let reply = try await request(cmd: 0x0100_0003, sub: 0x101, payload: p, timeout: .seconds(10))
        guard reply.sub == 0x1000_0101, reply.data.count >= 100 else {
            let code = reply.data.count >= 4 ? reply.data.u32le(at: 0) : reply.sub
            disconnect()
            throw ClientError.loginFailed(code)
        }
        loginReply = reply.data
        deviceGUID = reply.data.subdata(in: reply.data.startIndex..<(reply.data.startIndex + 16))
        sessionGUID = reply.data.subdata(in: (reply.data.startIndex + 84)..<(reply.data.startIndex + 100))
        isConnected = true
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.sendHeartbeat()
            }
        }
    }

    public func disconnect() {
        isConnected = false
        readerTask?.cancel(); readerTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        link?.cancel(); link = nil
        for (_, c) in pending { c.resume(throwing: ClientError.disconnected) }
        pending = [:]
        for (_, s) in liveSinks { s.cont.finish(throwing: ClientError.disconnected) }
        for (_, s) in taskSinks { s.finish(throwing: ClientError.disconnected) }
        liveSinks = [:]; taskSinks = [:]
    }

    // MARK: - XML 查詢（與 HTTP API 相同的 NVMS-9000 指令）

    public func xmlQuery(_ url: String, inner: String = "") async throws -> String {
        let xml = "<?xml version='1.0' encoding='utf-8'?><request version='1.0' systemType='NVMS-9000' clientType='MOBILE' url='\(url)'>\(inner)</request>"
        var p = Data(count: 128)
        p.putString(username, at: 0, max: 63)
        p.putString(url, at: 64, max: 63)
        p.append(Data(xml.utf8))
        let r = try await request(cmd: 0x0100_0003, sub: 0x91B, payload: p, timeout: .seconds(15))
        let text = String(decoding: r.data, as: UTF8.self)
        guard let range = text.range(of: "\r\n\r\n") else { throw ClientError.badReply("無 HTTP 標頭") }
        return String(text[range.upperBound...])
    }

    // MARK: - 即時影像

    /// 開啟即時串流。channelGUID 例："{00000001-0000-0000-0000-000000000000}"；chNo 從 0 起；streamType 1 主 / 2 子
    public func openLive(channelGUID: String, chNo: Int, streamType: Int, audio: Bool = false) async throws -> (task: Data, frames: AsyncThrowingStream<Data, Error>) {
        guard isConnected, let dest = TVTGUID.bytes(channelGUID) else { throw ClientError.disconnected }
        let task = TVTGUID.random()
        let (stream, cont) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(240))
        let key = UInt32(chNo + 1)
        liveSinks[key]?.cont.finish()
        liveSinks[key] = (task, cont)
        let xml = "<?xml version='1.0' encoding='utf-8'?><request version='1.0' systemType='NVMS-9000' clientType='SYS'>"
            + "<destId>\(channelGUID)</destId><taskId>\(TVTGUID.string(task))</taskId><chNo>\(chNo)</chNo>"
            + "<audio>\(audio ? 1 : 0)</audio><streamType>\(streamType)</streamType></request>"
        do {
            _ = try await routed(sub: 0x505, dest: dest, task: task, op: 1, payload: Data(xml.utf8))
        } catch {
            if liveSinks[key]?.task == task { liveSinks[key] = nil }
            cont.finish(throwing: error)
            throw error
        }
        return (task, stream)
    }

    public func closeLive(channelGUID: String, chNo: Int, task: Data) async {
        let key = UInt32(chNo + 1)
        if let s = liveSinks[key], s.task == task {
            s.cont.finish(); liveSinks[key] = nil
        }
        guard isConnected, let dest = TVTGUID.bytes(channelGUID) else { return }
        var p = Data(count: 76)
        p.putU32(UInt32(chNo + 1), at: 0)  // 頻道編號（1 起）
        _ = try? await routed(sub: 0x502, dest: dest, task: task, op: 2, payload: p)
    }

    // MARK: - 即時聲音（2026-10-31 由 SuperLive Plus 封包分析）
    // 開：0x501 op=1（獨立的聲音任務 GUID）；關：0x502 op=2（同一任務）
    // 內容 76 bytes：u32 頻道編號(1 起) @0、u32 6 @68、u32 3 @72
    // 聲音訊框與即時影像同樣以 0x6/0x10001 送達（SHFL offset 8 = 頻道），由既有 liveSinks 接收

    private func liveAudioPayload(chNo: Int) -> Data {
        var p = Data(count: 76)
        p.putU32(UInt32(chNo + 1), at: 0)
        p.putU32(6, at: 68)
        p.putU32(3, at: 72)
        return p
    }

    /// 開啟即時聲音，回傳聲音任務 GUID
    public func openLiveAudio(channelGUID: String, chNo: Int) async throws -> Data {
        guard isConnected, let dest = TVTGUID.bytes(channelGUID) else { throw ClientError.disconnected }
        let task = TVTGUID.random()
        _ = try await routed(sub: 0x501, dest: dest, task: task, op: 1, payload: liveAudioPayload(chNo: chNo))
        return task
    }

    public func closeLiveAudio(channelGUID: String, chNo: Int, task: Data) async {
        guard isConnected, let dest = TVTGUID.bytes(channelGUID) else { return }
        _ = try? await routed(sub: 0x502, dest: dest, task: task, op: 2, payload: liveAudioPayload(chNo: chNo))
    }

    // MARK: - 回放

    public func openPlayback(chNo: Int, start: Date, end: Date) async throws -> (task: Data, frames: AsyncThrowingStream<Data, Error>) {
        guard isConnected else { throw ClientError.disconnected }
        let task = TVTGUID.random()
        let (stream, cont) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .unbounded)
        taskSinks[task] = cont
        do {
            _ = try await routed(sub: 0x803, dest: deviceGUID, task: task, op: 1,
                                 payload: playbackPayload(chNo: chNo, start: start, end: end, open: true))
        } catch {
            taskSinks[task] = nil
            cont.finish(throwing: error)
            throw error
        }
        return (task, stream)
    }

    /// 流量控制：回報已播放到的訊框序號（同 WebSocket refresh_play_index）
    public func acknowledge(task: Data, index: Int) async {
        guard isConnected else { return }
        var p = Data(count: 4)
        p.putU32(UInt32(truncatingIfNeeded: index), at: 0)
        _ = try? await routed(sub: 0x808, dest: deviceGUID, task: task, op: 5, payload: p, waitReply: false)
    }

    public func closePlayback(task: Data, chNo: Int, start: Date, end: Date) async {
        taskSinks[task]?.finish(); taskSinks[task] = nil
        guard isConnected else { return }
        _ = try? await routed(sub: 0x807, dest: deviceGUID, task: task, op: 2,
                              payload: playbackPayload(chNo: chNo, start: start, end: end, open: false))
    }

    private func playbackPayload(chNo: Int, start: Date, end: Date, open: Bool) -> Data {
        var p = Data(count: 88)
        p.putU32(UInt32(start.timeIntervalSince1970), at: 0)
        p.putU32(UInt32(end.timeIntervalSince1970), at: 4)
        p.putU16(0xFFFF, at: 8)       // 錄影類型：全部
        p.putU16(1, at: 10)           // 頻道數量
        p.putU32(UInt32(chNo + 1), at: 12)  // 頻道編號清單（1 起）。注意：不是位元遮罩（2026-10-31 實測修正）
        p.putU32(7, at: 80)
        // @84：3 = 含聲音（SuperLive 開聲音時送 3；聲音訊框混在回放串流，延伸區第 3 byte = 1）
        if open { p.putU16(3, at: 84); p.putU16(1, at: 86) }
        return p
    }

    // MARK: - 傳送

    private func sendHeartbeat() async {
        guard let link else { return }
        var d = Data("1111".utf8)
        d.putU32Append(0)
        try? await link.send(d)
    }

    private func routed(sub: UInt32, dest: Data, task: Data, op: UInt32, payload: Data, waitReply: Bool = true) async throws -> Reply? {
        var route = Data()
        route.append(TVTGUID.random())
        route.append(sessionGUID)
        route.append(dest)
        route.putU32Append(2)
        route.append(task)
        route.putU32Append(op)
        if waitReply {
            return try await request(cmd: 0x0102_0003, sub: sub, route: route, payload: payload, timeout: .seconds(10))
        }
        try await send(cmd: 0x0102_0003, sub: sub, id: allocId(), route: route, payload: payload)
        return nil
    }

    private func allocId() -> UInt32 {
        defer { nextId &+= 1 }
        return nextId
    }

    private func send(cmd: UInt32, sub: UInt32, id: UInt32, route: Data = Data(), payload: Data) async throws {
        guard let link else { throw ClientError.disconnected }
        var body = Data()
        body.putU32Append(cmd)
        body.putU32Append(sub)
        body.putU32Append(id)
        body.putU32Append(UInt32(payload.count))
        body.append(route)
        body.append(payload)
        var msg = Data("1111".utf8)
        msg.putU32Append(UInt32(body.count))
        msg.append(body)
        try await link.send(msg)
    }

    private func request(cmd: UInt32, sub: UInt32, route: Data = Data(), payload: Data, timeout: Duration) async throws -> Reply {
        let id = allocId()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.fail(id: id, ClientError.timeout(String(format: "命令 0x%X", sub)))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task { [weak self] in
                do { try await self?.send(cmd: cmd, sub: sub, id: id, route: route, payload: payload) } catch { await self?.fail(id: id, error) }
            }
        }
    }

    private func fail(id: UInt32, _ e: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: e)
    }

    // MARK: - 接收

    private func readLoop(_ l: TCPLink) async {
        while !Task.isCancelled {
            do {
                guard let chunk = try await l.receive() else { break }
                if !chunk.isEmpty { ingest(chunk) }
            } catch {
                break
            }
        }
        if link === l { disconnect() }
    }

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        let magic = Data("1111".utf8), head = Data("head".utf8)
        var o = buffer.startIndex
        while buffer.endIndex - o >= 8 {
            let tag = buffer[o..<(o + 4)]
            if tag == head {
                guard buffer.endIndex - o >= 64 else { break }
                o += 64
                continue
            }
            guard tag == magic else {
                // 失去同步：找下一個 "1111"
                if let r = buffer.range(of: magic, in: (o + 1)..<buffer.endIndex) { o = r.lowerBound; continue }
                o = buffer.endIndex - 3
                break
            }
            let rawLen = buffer.u32le(at: o - buffer.startIndex + 4)
            if rawLen == 0xFFFF_FFFF {
                // 分段訊息（> 約 64 KB，例如大的關鍵幀）：
                // "1111" | FFFFFFFF | u32 id | u32 分段數 | u32 總長 | u32 第幾段(1 起) | u32 本段長度 | u32 0 | 資料
                guard buffer.endIndex - o >= 32 else { break }
                let base = o - buffer.startIndex
                let id = buffer.u32le(at: base + 8), count = buffer.u32le(at: base + 12)
                let total = Int(buffer.u32le(at: base + 16)), index = buffer.u32le(at: base + 20)
                let fragLen = Int(buffer.u32le(at: base + 24))
                guard buffer.endIndex - o >= 32 + fragLen else { break }
                var acc = fragments[id] ?? Data()
                if index == 1 { acc = Data() }
                acc.append(buffer.subdata(in: (o + 32)..<(o + 32 + fragLen)))
                if index >= count {
                    fragments[id] = nil
                    if acc.count == total, total >= 16 { handle(acc) }
                } else if acc.count <= total {
                    fragments[id] = acc
                } else {
                    fragments[id] = nil  // 異常：丟棄
                }
                o += 32 + fragLen
                continue
            }
            let len = Int(rawLen)
            guard buffer.endIndex - o >= 8 + len else { break }
            if len >= 16 {
                handle(buffer.subdata(in: (o + 8)..<(o + 8 + len)))
            }
            o += 8 + len
        }
        buffer = buffer.subdata(in: o..<buffer.endIndex)
    }

    static let debug = ProcessInfo.processInfo.environment["DVRKIT_DEBUG"] == "1"

    private func handle(_ body: Data) {
        let cmd = body.u32le(at: 0), sub = body.u32le(at: 4), id = body.u32le(at: 8)
        let data = body.subdata(in: (body.startIndex + 16)..<body.endIndex)
        switch cmd {
        case 0x0100_0006, 0x0102_0006:
            pending.removeValue(forKey: id)?.resume(returning: Reply(cmd: cmd, sub: sub, data: data))
        case 0x0000_0006 where sub == 0x0001_0001:
            guard data.count >= 12 else { return }
            let ch = data.u32le(at: 8)
            liveSinks[ch]?.cont.yield(data)
        case 0x0002_0006:
            guard data.count >= 72 else { return }
            let task = data.subdata(in: (data.startIndex + 52)..<(data.startIndex + 68))
            if sub & 0xFFFF == 0x0001 {
                taskSinks[task]?.yield(data.subdata(in: (data.startIndex + 72)..<data.endIndex))
            } else if sub & 0xFFFF == 0x0002 {
                taskSinks.removeValue(forKey: task)?.finish()  // 回放結束
            }
        default:
            // 0x6 / a01 / a02 / a03 等狀態通知；DVRKIT_DEBUG=1 時列出未處理的訊息類型
            if Self.debug { print(String(format: "[TVT] 未處理 cmd=0x%X sub=0x%X len=%d", cmd, sub, data.count)) }
        }
    }
}

// MARK: - GUID（Windows 位元組排列）

public enum TVTGUID {
    /// "{B9748EC7-0C1A-6A46-A647-BF55FABEAEC3}" → c7 8e 74 b9 | 1a 0c | 46 6a | a6 47 bf 55 fa be ae c3
    public static func bytes(_ s: String) -> Data? {
        let hex = s.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).split(separator: "-").map(String.init)
        guard hex.count == 5, hex[0].count == 8, hex[1].count == 4, hex[2].count == 4, hex[3].count == 4, hex[4].count == 12,
              let a = UInt32(hex[0], radix: 16), let b = UInt16(hex[1], radix: 16), let c = UInt16(hex[2], radix: 16)
        else { return nil }
        var d = Data()
        d.putU32Append(a)
        withUnsafeBytes(of: b.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: c.littleEndian) { d.append(contentsOf: $0) }
        let tail = hex[3] + hex[4]
        var i = tail.startIndex
        while i < tail.endIndex {
            let j = tail.index(i, offsetBy: 2)
            guard let v = UInt8(tail[i..<j], radix: 16) else { return nil }
            d.append(v)
            i = j
        }
        return d
    }

    public static func string(_ d: Data) -> String {
        guard d.count == 16 else { return "" }
        let b = [UInt8](d)
        let a = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        let x = UInt16(b[4]) | UInt16(b[5]) << 8
        let y = UInt16(b[6]) | UInt16(b[7]) << 8
        let rest = b[8...].map { String(format: "%02X", $0) }.joined()
        return String(format: "{%08X-%04X-%04X-", a, x, y) + rest.prefix(4) + "-" + rest.dropFirst(4) + "}"
    }

    public static func random() -> Data {
        withUnsafeBytes(of: UUID().uuid) { Data($0) }
    }
}

// MARK: - TCP（Network.framework）

final class TCPLink: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "dvrkit.tvt.tcp")

    init(host: String, port: Int) {
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port)), using: .tcp)
    }

    func start(timeout: TimeInterval = 10) async throws {
        let once = Once()
        let c = conn
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.stateUpdateHandler = { st in
                switch st {
                case .ready: if once.take() { cont.resume() }
                case .failed(let e), .waiting(let e): if once.take() { c.cancel(); cont.resume(throwing: e) }
                case .cancelled: if once.take() { cont.resume(throwing: TVTPrivateClient.ClientError.disconnected) }
                default: break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.take() { c.cancel(); cont.resume(throwing: TVTPrivateClient.ClientError.timeout("TCP 連線")) }
            }
        }
    }

    func send(_ d: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: d, completion: .contentProcessed { e in
                if let e { cont.resume(throwing: e) } else { cont.resume() }
            })
        }
    }

    /// nil = 對方關閉
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, err in
                if let err { cont.resume(throwing: err) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if done { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    func cancel() { conn.cancel() }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
}

// MARK: - Data 小工具

extension Data {
    mutating func putU32(_ v: UInt32, at o: Int) {
        let i = startIndex + o
        self[i] = UInt8(v & 0xFF); self[i + 1] = UInt8((v >> 8) & 0xFF)
        self[i + 2] = UInt8((v >> 16) & 0xFF); self[i + 3] = UInt8(v >> 24)
    }

    mutating func putU16(_ v: UInt16, at o: Int) {
        let i = startIndex + o
        self[i] = UInt8(v & 0xFF); self[i + 1] = UInt8(v >> 8)
    }

    mutating func putU32Append(_ v: UInt32) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    mutating func putString(_ s: String, at o: Int, max: Int) {
        let b = Array(s.utf8.prefix(max))
        for (k, x) in b.enumerated() { self[startIndex + o + k] = x }
    }
}
