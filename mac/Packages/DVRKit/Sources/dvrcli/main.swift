import CoreMedia
import DVRKit
import Foundation

extension Data {
    func u32le(at o: Int) -> UInt32 {
        let i = startIndex + o
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}

// dvrcli — Phase 2 命令列原型（只做唯讀操作）
//
// 用法：
//   swift run dvrcli <host> <port> <user> survey [--live-seconds 5] [--channel 1] [--main]
//   swift run dvrcli <host> <port> <user> channels
//   swift run dvrcli <host> <port> <user> records <頻道序號> <yyyy-MM-dd>
//   swift run dvrcli <host> <port> <user> live <頻道序號> [--seconds 5] [--main]
//   swift run dvrcli <host> <port> <user> playback <頻道序號> "<yyyy-MM-dd HH:mm:ss>" [--seconds 5] [--main]
//   swift run dvrcli <host> <port> <user> snapshot <頻道序號> [--main] [--frames 30]
//   swift run dvrcli <host> <port> <user> playertest live <頻道>
//   swift run dvrcli <host> <port> <user> playertest playback <頻道> "<yyyy-MM-dd HH:mm:ss>"
//   swift run dvrcli decode <captures/*.bin>              # 離線解碼，不連 DVR
//   swift run dvrcli <host> <port> <user> raw <指令> [xml-inner]
//
// 密碼：開發階段從 Keychain（service=DVRViewer.dev, account=<user>@<host>）讀取，
//      透過 /usr/bin/security 取得（避免 CLI 每次觸發 Keychain 授權視窗）。
// 每次執行只登入一次，結束時登出。輸出不會顯示密碼與 sessionId。
// 影像資料只寫入 ./captures（已被 .gitignore 排除）。

setvbuf(stdout, nil, _IOLBF, 0)

func devPassword(user: String, host: String) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "DVRViewer.dev", "-a", "\(user)@\(host)", "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw NVMSError.transport("Keychain 找不到 \(user)@\(host)，請先執行 tools/dvr-credentials.sh set \(host) \(user)")
    }
    var s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    if s.hasSuffix("\n") { s.removeLast() }
    return s
}

func printDict(_ title: String, _ d: [String: String], filter: ((String) -> Bool)? = nil) {
    print("■ \(title)（\(d.count) 項）")
    for (k, v) in d.sorted(by: { $0.key < $1.key }) where filter?(k) ?? true {
        let shown = k.range(of: "(?i)(pass|pwd|token|secret|key|nonce|session|sn$|serial|mac)", options: .regularExpression) != nil ? "[已遮蔽]" : v
        print("   \(k) = \(shown)")
    }
}

struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]
    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    flags[key] = argv[i + 1]; i += 2
                } else {
                    flags[key] = "true"; i += 1
                }
            } else {
                positional.append(a); i += 1
            }
        }
    }
    func int(_ k: String, _ def: Int) -> Int { flags[k].flatMap(Int.init) ?? def }
    func bool(_ k: String) -> Bool { flags[k] == "true" }
}

func captureDir() -> URL {
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "captures")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return dir
}

let tsFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f
}()

/// 收串流 N 秒，存原始 payload 並印出格式分析（不輸出影像內容）
func runStream(client: NVMSClient, channel: DVRChannel, kind: NVMSStream.Kind, seconds: Int,
               main: Bool, playbackStart: Date? = nil) async throws {
    guard let sid = await client.sessionId else { return }
    let stream = NVMSStream(host: await client.host, port: await client.port, sessionId: sid)
    try await stream.connect()
    print("   WebSocket 已連線（create_connection code=0）")
    switch kind {
    case .live:
        try await stream.openPreview(channelId: channel.id, streamIndex: main ? 1 : 2)
    case .playback:
        let s = Int((playbackStart ?? Date().addingTimeInterval(-3600)).timeIntervalSince1970)
        try await stream.openPlayback(channelId: channel.id, start: s, end: s + 3600, streamIndex: main ? 0 : 1)
    }
    let label = kind == .live ? "live" : "playback"
    let file = captureDir().appending(path: "\(label)-ch\(channel.index)-\(main ? "main" : "sub")-\(tsFormatter.string(from: Date())).bin")
    FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let fh = try FileHandle(forWritingTo: file)
    defer { try? fh.close() }

    let t0 = ContinuousClock.now
    var frames = 0, bytes = 0, shownFrames = 0
    var sizes: [Int] = []
    var urls: [String: Int] = [:]
    var jsonKeys = Set<String>()
    var combined = AnnexBReport()
    var firstOffsets: [Int: Int] = [:]
    var headerSamples: [String: Int] = [:]
    var lastIndex: Int?

    // 監看計時器：時間到（或設備不送資料）就中斷 socket，讓 receive() 返回
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(seconds + 5))
        await stream.cancelSocket()
    }
    defer { watchdog.cancel() }
    loop: while ContinuousClock.now - t0 < .seconds(seconds) {
        let ev = try await stream.receive()
        switch ev {
        case .message(let url, let code, let raw):
            print("   ◆ 文字訊息 \(url) code=\(code.map(String.init) ?? "-") \(raw.prefix(300))")
        case .closed(let why):
            print("   ✖ 連線關閉：\(why)"); break loop
        case .frame(let f):
            frames += 1
            bytes += f.payload.count
            sizes.append(f.payload.count)
            urls[f.url, default: 0] += 1
            jsonKeys.formUnion(f.json.keys)
            // 長度前綴寫檔：u32 jsonLen | json | u32 payloadLen | payload
            let jsonStr = f.json.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&")
            var lenJ = UInt32(jsonStr.utf8.count).littleEndian
            var lenP = UInt32(f.payload.count).littleEndian
            fh.write(Data(bytes: &lenJ, count: 4)); fh.write(Data(jsonStr.utf8))
            fh.write(Data(bytes: &lenP, count: 4)); fh.write(f.payload)

            let rep = AnnexB.analyze(f.payload)
            if let o = rep.firstStartCodeOffset { firstOffsets[o, default: 0] += 1 }
            if combined.codec == nil { combined.codec = rep.codec }
            for (k, v) in rep.nalTypes { combined.nalTypes[k, default: 0] += v }
            headerSamples[AnnexB.hexRow(f.payload.prefix(4), count: 4), default: 0] += 1
            if shownFrames < 4 {
                shownFrames += 1
                print("   ▶ 訊框#\(frames) \(f.url) 外層標頭=\(AnnexB.hexRow(f.header, count: 16))")
                print("     JSON：\(jsonStr.prefix(400))")
                print("     payload \(f.payload.count) bytes：\(AnnexB.hexRow(f.payload, count: 48))")
                print("     Annex-B：\(rep)")
            }
            // 回放流量控制（同網頁 wasm-player）：SHFL offset 36 = 訊框序號，每 8 個回報一次
            if kind == .playback, f.payload.count >= 40, f.payload.prefix(4) == Data("SHFL".utf8) {
                let idx = Int(f.payload.u32le(at: 36))
                lastIndex = idx
                if idx > 0, idx % 8 == 0 { try? await stream.refreshPlayIndex(idx) }
            }
        }
    }
    await stream.close(kind: kind)
    let secs = Double((ContinuousClock.now - t0).components.seconds)
    print("■ 串流結果：\(frames) 個訊框、\(bytes) bytes、約 \(Int(Double(bytes) * 8 / max(secs, 1) / 1000)) kbps")
    print("   訊息 url：\(urls)")
    print("   JSON 欄位：\(jsonKeys.sorted())")
    print("   payload 開頭 4 bytes 分佈：\(headerSamples.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)×\($0.value)" })")
    print("   首個 start code 偏移分佈：\(firstOffsets.sorted { $0.value > $1.value }.prefix(5))")
    print("   彙總 Annex-B：\(combined)")
    if let s = sizes.max() { print("   payload 大小：最小 \(sizes.min()!) / 最大 \(s)") }
    if let lastIndex { print("   最後 frame index：\(lastIndex)") }
    print("   原始資料（僅本機）：\(file.path)")
}

// MARK: - 解碼（離線 / 即時截圖）

struct DecodeSummary {
    var frames = 0, decoded = 0, waiting = 0, errors = 0, keyframes = 0
    var firstError: String?
    var totalDecodeTime: Duration = .zero
    var stats: [Snapshot.LumaStats] = []
    var saved: [String] = []
}

func ptsFor(_ f: SHFLFrame, base: UInt64) -> CMTime {
    CMTime(value: Int64(f.fileTime &- base) / 10, timescale: 1_000_000)
}

/// 解碼一個 SHFL payload；需要時存 JPEG
func decodeOne(_ payload: Data, decoder: VideoDecoder, base: inout UInt64?, summary: inout DecodeSummary,
               saveTo: URL?) {
    guard let f = SHFLFrame.parse(payload) else { summary.errors += 1; return }
    summary.frames += 1
    if f.isKeyframe { summary.keyframes += 1 }
    if base == nil { base = f.fileTime }
    let clock = ContinuousClock()
    let t0 = clock.now
    do {
        if let out = try decoder.decode(annexB: f.videoData, pts: ptsFor(f, base: base!)) {
            summary.totalDecodeTime += clock.now - t0
            summary.decoded += 1
            if let saveTo, let st = Snapshot.lumaStats(out.pixelBuffer) {
                summary.stats.append(st)
                try Snapshot.writeJPEG(out.pixelBuffer, to: saveTo)
                summary.saved.append(saveTo.path)
            }
        } else {
            summary.waiting += 1
        }
    } catch {
        summary.errors += 1
        if summary.firstError == nil { summary.firstError = "\(error)" }
    }
}

func printSummary(_ s: DecodeSummary, decoder: VideoDecoder) {
    let avg = s.decoded > 0 ? Double(Double(s.totalDecodeTime.components.attoseconds) / 1e15 + Double(s.totalDecodeTime.components.seconds) * 1000) / Double(s.decoded) : 0
    print("■ 解碼結果：訊框 \(s.frames)、成功 \(s.decoded)、等待關鍵幀 \(s.waiting)、錯誤 \(s.errors)、關鍵幀 \(s.keyframes)")
    if let e = s.firstError { print("   第一個錯誤：\(e)") }
    print("   編碼 \(decoder.codec?.rawValue ?? "-")、解析度 \(decoder.dimensions.map { "\($0.width)x\($0.height)" } ?? "-")、硬體解碼 \(decoder.usingHardware.map { $0 ? "是" : "否" } ?? "未知")")
    print(String(format: "   平均解碼時間 %.2f ms/幀", avg))
    for (st, path) in zip(s.stats, s.saved) {
        print("   截圖 \(st.looksValid ? "✅" : "⚠️ 可能異常") \(st)  → \(path)")
    }
}

/// 讀 dvrcli 存的 .bin（u32 jsonLen | json | u32 payloadLen | payload）
func readCapture(_ url: URL) throws -> [Data] {
    let d = try Data(contentsOf: url)
    var out: [Data] = []
    var o = 0
    while o + 8 <= d.count {
        let jl = Int(d.u32le(at: o)); o += 4 + jl
        guard o + 4 <= d.count else { break }
        let pl = Int(d.u32le(at: o)); o += 4
        guard o + pl <= d.count else { break }
        out.append(d.subdata(in: o..<(o + pl))); o += pl
    }
    return out
}

func runOfflineDecode(_ path: String) -> Int32 {
    let url = URL(fileURLWithPath: path)
    guard let payloads = try? readCapture(url) else { print("無法讀取 \(path)"); return 1 }
    print("■ 離線解碼 \(url.lastPathComponent)：\(payloads.count) 個 payload")
    let decoder = VideoDecoder()
    var base: UInt64?
    var s = DecodeSummary()
    let stem = url.deletingPathExtension().lastPathComponent
    let picks: Set<Int> = [0, payloads.count / 2, payloads.count - 1]
    var decodedIndex = 0
    for (i, p) in payloads.enumerated() {
        let before = s.decoded
        // 只在指定位置附近存截圖（第一張成功、中間、最後）
        let want = picks.contains(i) || (s.decoded == 0)
        decodeOne(p, decoder: decoder, base: &base, summary: &s,
                  saveTo: want ? captureDir().appending(path: "\(stem)-frame\(i).jpg") : nil)
        if s.decoded > before { decodedIndex += 1 }
    }
    printSummary(s, decoder: decoder)
    return s.decoded > 0 && s.errors == 0 ? 0 : 4
}

/// 即時截圖：開串流、解碼到指定張數，存第一張與最後一張
func runSnapshot(client: NVMSClient, channel: DVRChannel, main: Bool, frames want: Int) async throws {
    guard let sid = await client.sessionId else { return }
    let stream = NVMSStream(host: client.host, port: client.port, sessionId: sid)
    try await stream.connect()
    try await stream.openPreview(channelId: channel.id, streamIndex: main ? 1 : 2)
    let watchdog = Task { try? await Task.sleep(for: .seconds(20)); await stream.cancelSocket() }
    defer { watchdog.cancel() }
    let decoder = VideoDecoder()
    var base: UInt64?
    var s = DecodeSummary()
    let stem = "snapshot-ch\(channel.index + 1)-\(main ? "main" : "sub")-\(tsFormatter.string(from: Date()))"
    loop: while s.decoded < want {
        switch try await stream.receive() {
        case .frame(let f):
            let isFirst = s.decoded == 0
            let isLast = s.decoded == want - 1
            decodeOne(f.payload, decoder: decoder, base: &base, summary: &s,
                      saveTo: (isFirst || isLast) ? captureDir().appending(path: "\(stem)-\(isFirst ? "first" : "last").jpg") : nil)
        case .closed(let why):
            print("   ✖ 連線關閉：\(why)"); break loop
        case .message(let url, let code, _):
            if let code, code != 0 { print("   ◆ \(url) code=\(code)") }
        }
    }
    await stream.close(kind: .live)
    printSummary(s, decoder: decoder)
}

// MARK: - 播放器整合測試（與 App 使用相同的 DVRKit 類別）

final class Counter: @unchecked Sendable {
    let lock = NSLock()
    var frames = 0
    var last: Date?
    var states: [String] = []
    func frame(_ t: Date) { lock.withLock { frames += 1; last = t } }
    func state(_ s: String) { lock.withLock { states.append(s) } }
    func snap() -> (Int, Date?) { lock.withLock { (frames, last) } }
}

func runPlayerTest(host: String, port: Int, user: String, rest: [String], args: Args) async -> Int32 {
    let conn = DVRConnection(host: host, port: port, username: user) { try devPassword(user: user, host: host) }
    do {
        let chls = try await conn.connect()
        let info = await conn.info
        print("■ DVRConnection 已連線：\(info?.model ?? "-") 韌體 \(info?.firmware ?? "-")，頻道 \(chls.count)")
        let n = Int(rest.dropFirst().first ?? "1") ?? 1
        guard n >= 1, n <= chls.count else { print("頻道錯誤"); return 1 }
        let ch = chls[n - 1]
        let c = Counter()
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss.SSS"
        func report(_ label: String, _ since: (Int, Date?)) {
            let now = c.snap()
            let adv = (now.1?.timeIntervalSince1970 ?? 0) - (since.1?.timeIntervalSince1970 ?? 0)
            print(String(format: "   %@：顯示 %d 幀，錄影時間前進 %.1f 秒，目前 %@", label, now.0 - since.0, since.1 == nil ? 0 : adv,
                         now.1.map { tf.string(from: $0) } ?? "-"))
        }
        if rest.first == "live" {
            let p = LiveStreamPlayer(connection: conn, channelId: ch.id, mainStream: false)
            p.onFrame = { _, t in c.frame(t) }
            p.onState = { s in print("   狀態：\(s)") }
            p.start()
            try await Task.sleep(for: .seconds(4)); var m = c.snap(); report("子串流 4 秒", (0, nil))
            p.setMainStream(true)
            try await Task.sleep(for: .seconds(4)); report("切主串流 4 秒", m); m = c.snap()
            p.stop()
            try await Task.sleep(for: .seconds(1))
        } else {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            guard rest.count >= 3, let start = f.date(from: rest[2]) else { print("用法：playertest playback <頻道> \"yyyy-MM-dd HH:mm:ss\""); return 1 }
            let p = PlaybackStreamPlayer(connection: conn, channelId: ch.id)
            p.onFrame = { _, t in c.frame(t) }
            p.onState = { s in print("   狀態：\(s)") }
            p.play(from: start)
            try await Task.sleep(for: .seconds(4)); var m = c.snap(); report("1x 播放 4 秒", (0, nil))
            p.pause(); try await Task.sleep(for: .seconds(2)); report("暫停 2 秒", m); m = c.snap()
            p.resume(); try await Task.sleep(for: .seconds(3)); report("繼續 1x 3 秒", m); m = c.snap()
            p.setSpeed(2); try await Task.sleep(for: .seconds(3)); report("2x 3 秒", m); m = c.snap()
            p.setSpeed(8); try await Task.sleep(for: .seconds(3)); report("8x（只送關鍵幀）3 秒", m); m = c.snap()
            p.setSpeed(1)
            let target = start.addingTimeInterval(3600)
            p.play(from: target); try await Task.sleep(for: .seconds(3)); report("跳轉到 \(f.string(from: target)) 後 3 秒", m); m = c.snap()
            p.pause(); try await Task.sleep(for: .milliseconds(500)); m = c.snap()
            for _ in 0..<5 { p.stepFrame(); try await Task.sleep(for: .milliseconds(300)) }
            report("逐格 ×5", m)
            p.stop()
            try await Task.sleep(for: .seconds(1))
        }
    } catch {
        print("❌ \(error)")
        await conn.disconnect()
        return 3
    }
    await conn.disconnect()
    print("■ 已登出")
    return 0
}

func dayRange(_ day: String) -> (String, String, Date)? {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = .current
    guard let start = f.date(from: day) else { return nil }
    let end = start.addingTimeInterval(86399)
    let out = DateFormatter()
    out.dateFormat = "yyyy-MM-dd HH:mm:ss"
    out.timeZone = .current
    return (out.string(from: start), out.string(from: end), start)
}

@MainActor
func run() async -> Int32 {
    let args = Args(Array(CommandLine.arguments.dropFirst()))
    if args.positional.first == "decode" {
        guard args.positional.count >= 2 else { print("用法：dvrcli decode <captures/*.bin>"); return 1 }
        return runOfflineDecode(args.positional[1])
    }
    guard args.positional.count >= 4, let port = Int(args.positional[1]) else {
        print("用法：dvrcli <host> <port> <user> <survey|channels|records|live|playback|raw> …")
        return 1
    }
    let host = args.positional[0], user = args.positional[2], cmd = args.positional[3]
    let rest = Array(args.positional.dropFirst(4))
    if cmd == "playertest" {
        return await runPlayerTest(host: host, port: port, user: user, rest: rest, args: args)
    }

    let client = NVMSClient(host: host, port: port)
    do {
        let pw = try devPassword(user: user, host: host)
        print("■ 登入 \(host):\(port)（帳號 \(user)，只嘗試一次）")
        let info = try await client.login(user: user, password: pw)
        print("   ✅ 登入成功 userId=\(info.userId.isEmpty ? "-" : "已取得") authGroup=\(info.authGroupId.isEmpty ? "-" : "已取得")")
    } catch {
        print("   ❌ 登入失敗：\(error)")
        return 2
    }

    var exitCode: Int32 = 0
    do {
        let chls = try await client.channels()
        func channel(_ s: String?) -> DVRChannel? {
            // 使用者看到的頻道編號從 1 開始；DVR 的 chlIndex 從 0 開始
            let n = Int(s ?? "1") ?? 1
            return n >= 1 && n <= chls.count ? chls[n - 1] : nil
        }

        switch cmd {
        case "survey":
            printDict("querySystemCaps", try await client.systemCaps())
            if let basic = try? await client.basicConfig() { printDict("queryBasicCfg", basic) }
            if let tc = try? await client.timeConfig() { printDict("queryTimeCfg", tc) }
            let online = (try? await client.onlineChannelIds()) ?? []
            let withRec = (try? await client.channelsWithRecordings()) ?? []
            print("■ 頻道（queryNodeList）：\(chls.count) 個，在線 \(online.count)，有錄影 \(withRec.count)")
            for c in chls {
                print("   #\(c.index + 1) \(c.name)  type=\(c.type ?? "-")  \(online.contains(c.id) ? "在線" : "離線")  \(withRec.contains(c.id) ? "有錄影" : "")  id=\(c.id)")
            }
            if let c = channel(args.flags["channel"]) {
                let dates = try await client.datesWithRecordings(channelIds: [c.id])
                print("■ 頻道 #\(c.index) 有錄影的日期：\(dates.count) 天 \(dates.suffix(10))")
                let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
                let today = fmt.string(from: Date())
                if let (s, e, _) = dayRange(today) {
                    do {
                        let recs = try await client.recordLog(channelId: c.id, start: s, end: e)
                        print("■ 今天（\(today)，查詢 \(s) ~ \(e)）錄影區段：\(recs.count) 筆")
                        for r in recs.prefix(8) { print("   \(r.type) \(r.start) → \(r.end) size=\(r.size.map(String.init) ?? "-")") }
                    } catch { print("   queryChlRecLog：\(error)") }
                }
                print("■ 即時串流測試：頻道 #\(c.index) \(args.bool("main") ? "主串流" : "子串流")，\(args.int("live-seconds", 5)) 秒")
                try await runStream(client: client, channel: c, kind: .live, seconds: args.int("live-seconds", 5), main: args.bool("main"))
            }

        case "channels":
            for c in chls { print("#\(c.index + 1) \(c.name) id=\(c.id)") }

        case "records":
            guard let c = channel(rest.first), rest.count >= 2, let (s, e, _) = dayRange(rest[1]) else {
                print("用法：records <頻道序號> <yyyy-MM-dd>"); exitCode = 1; break
            }
            let recs = try await client.recordLog(channelId: c.id, start: s, end: e)
            print("■ #\(c.index + 1) \(rest[1])（\(s) ~ \(e)）：\(recs.count) 筆")
            for r in recs { print("   \(r.type)\(r.subType.map { "/\($0)" } ?? "") \(r.start) → \(r.end) size=\(r.size.map(String.init) ?? "-")") }

        case "live":
            guard let c = channel(rest.first) else { print("找不到頻道"); exitCode = 1; break }
            try await runStream(client: client, channel: c, kind: .live, seconds: args.int("seconds", 5), main: args.bool("main"))

        case "playback":
            guard let c = channel(rest.first), rest.count >= 2 else { print("用法：playback <頻道序號> \"yyyy-MM-dd HH:mm:ss\""); exitCode = 1; break }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.timeZone = .current
            guard let start = f.date(from: rest[1]) else { print("時間格式錯誤"); exitCode = 1; break }
            try await runStream(client: client, channel: c, kind: .playback, seconds: args.int("seconds", 5),
                                main: args.bool("main"), playbackStart: start)

        case "snapshot":
            guard let c = channel(rest.first) else { print("找不到頻道"); exitCode = 1; break }
            print("■ 即時截圖：頻道 #\(c.index + 1) \(c.name) \(args.bool("main") ? "主串流" : "子串流")")
            try await runSnapshot(client: client, channel: c, main: args.bool("main"), frames: args.int("frames", 30))

        case "raw":
            guard let command = rest.first else { print("用法：raw <指令> [xml-inner]"); exitCode = 1; break }
            let body = rest.count > 1 ? NVMSClientXML.request(rest[1]) : nil
            var xml = try await client.raw(command, body: body)
            xml = xml.replacing(try! Regex("(?i)<(password|pwd|token|sessionId|nonce|key)>[^<]*</"), with: { m in
                "<\(m.output[1].substring ?? "")>[已遮蔽]</"
            })
            print(xml)

        default:
            print("未知指令：\(cmd)"); exitCode = 1
        }
    } catch {
        print("❌ \(error)")
        exitCode = 3
    }
    await client.logout()
    print("■ 已登出")
    return exitCode
}

enum NVMSClientXML {
    static func request(_ inner: String) -> String {
        #"<?xml version="1.0" encoding="utf-8" ?><request version="1.0" systemType="NVMS-9000" clientType="WEB">"# + inner + "</request>"
    }
}

exit(await run())
