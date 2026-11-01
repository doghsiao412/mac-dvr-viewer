import AVFoundation
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
//   swift run dvrcli <host> <port> <user> chcheck <yyyy-MM-dd>     # 逐頻道驗證回放頻道正確
//   swift run dvrcli <host> <port> <user> export <頻道> "<yyyy-MM-dd HH:mm:ss>" <秒數> [--main]   # 下載錄影成 MP4
//   swift run dvrcli decode <captures/*.bin>              # 離線解碼，不連 DVR
//   swift run dvrcli <host> <port> <user> raw <指令> [xml-inner]
//
// 密碼：開發階段從 Keychain（service=DVRViewer.dev, account=<user>@<host>）讀取，
//      透過 /usr/bin/security 取得（避免 CLI 每次觸發 Keychain 授權視窗）。
// 每次執行只登入一次，結束時登出。輸出不會顯示密碼與 sessionId。
// 影像資料只寫入 ./captures（已被 .gitignore 排除）。

setvbuf(stdout, nil, _IOLBF, 0)

/// 埠號（供 Keychain 項目 "user@host:port" 格式查找）
nonisolated(unsafe) var devPort: Int?

func devPassword(user: String, host: String) throws -> String {
    // 依序嘗試 "user@host" 與 "user@host:port"
    var accounts = ["\(user)@\(host)"]
    if let devPort { accounts.append("\(user)@\(host):\(devPort)") }
    for account in accounts {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "DVRViewer.dev", "-a", account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { continue }
        var s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if s.hasSuffix("\n") { s.removeLast() }
        return s
    }
    throw NVMSError.transport("Keychain 找不到 \(accounts.joined(separator: " 或 "))，請先執行 tools/dvr-credentials.sh set \(host) \(user)")
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
    let stream = NVMSStream(host: client.host, port: client.port, sessionId: sid)
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
            let hold = args.int("seconds", 4)
            try await Task.sleep(for: .seconds(hold)); var m = c.snap(); report("子串流 \(hold) 秒", (0, nil))
            p.setMainStream(true)
            try await Task.sleep(for: .seconds(hold)); report("切主串流 \(hold) 秒", m); m = c.snap()
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

/// 逐一頻道驗證回放是否播放「正確的頻道」：比對 SHFL offset 8（頻道編號，1 起）
func runChannelCheck(host: String, port: Int, user: String, day: String) async -> Int32 {
    let conn = DVRConnection(host: host, port: port, username: user) { try devPassword(user: user, host: host) }
    var bad = 0
    do {
        let chls = try await conn.connect()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { print("日期格式錯誤"); return 1 }
        print("■ 傳輸：\(await conn.usesPrivateProtocol ? "TVT 私有協定" : "WebSocket")；日期 \(day)")
        for ch in chls {
            let ranges = (try? await conn.recordRanges(channelId: ch.id, day: d)) ?? []
            guard let r = ranges.first else { print("   #\(ch.index + 1) \(ch.name)：當天無錄影"); continue }
            let ms = try await conn.openPlayback(channelId: ch.id, start: r.start, end: r.end, mainStream: false, typeMask: ["manual", "schedule", "motion", "sensor"])
            var got: UInt32?
            let t = Task { try? await Task.sleep(for: .seconds(8)); await ms.close() }
            for try await p in ms.frames { if p.count > 12, p.prefix(4) == Data("SHFL".utf8) { got = p.u32le(at: 8); break } }
            t.cancel()
            await ms.close()
            let ok = got == UInt32(ch.index + 1)
            if !ok { bad += 1 }
            print("   #\(ch.index + 1) \(ch.name)：回傳頻道 \(got.map(String.init) ?? "無資料") \(ok ? "✅" : "❌")")
        }
    } catch {
        print("❌ \(error)"); bad += 1
    }
    await conn.disconnect()
    print("■ 結果：\(bad == 0 ? "全部正確" : "\(bad) 個頻道不符")")
    return bad == 0 ? 0 : 5
}

// MARK: - 錄影下載（MP4）與驗證

func verifyMP4(_ url: URL) async {
    let asset = AVURLAsset(url: url)
    do {
        let dur = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { print("   ❌ MP4 沒有影像軌"); return }
        let size = try await track.load(.naturalSize)
        let fmts = try await track.load(.formatDescriptions)
        var fourcc = "?"
        if let fd = fmts.first {
            let v: UInt32 = CMFormatDescriptionGetMediaSubType(fd)
            let bytes: [UInt8] = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
            fourcc = String(bytes: bytes, encoding: .ascii) ?? "?"
        }
        let fps = try await track.load(.nominalFrameRate)
        print(String(format: "   MP4 驗證：時長 %.1f 秒、%@ %.0fx%.0f、約 %.1f fps", dur, fourcc, size.width, size.height, fps))
        // 讀回所有樣本數
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        reader.startReading()
        var n = 0
        while out.copyNextSampleBuffer() != nil { n += 1 }
        print("   MP4 讀回樣本數：\(n)（狀態 \(reader.status == .completed ? "完成" : "異常")）")
        if let at = try await asset.loadTracks(withMediaType: .audio).first {
            let afd = try await at.load(.formatDescriptions).first
            let sub: UInt32 = afd.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            let asbd = afd.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let tr = try await at.load(.timeRange)
            let ar = try AVAssetReader(asset: asset)
            let ao = AVAssetReaderTrackOutput(track: at, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            ar.add(ao); ar.startReading()
            var pcmBytes = 0, nonSilent = 0
            while let sb = ao.copyNextSampleBuffer() {
                if let bb = CMSampleBufferGetDataBuffer(sb) {
                    var len = 0; var ptr: UnsafeMutablePointer<CChar>?
                    CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
                    pcmBytes += len
                    if let ptr { ptr.withMemoryRebound(to: Int16.self, capacity: len / 2) { p in for k in stride(from: 0, to: len / 2, by: 50) where abs(Int(p[k])) > 300 { nonSilent += 1 } } }
                }
            }
            print(String(format: "   聲音軌：%@ %.0f Hz %d 聲道、時長 %.1f 秒（影像軌 %.1f 秒）；解碼回 PCM %d bytes，非靜音取樣點 %d",
                         sub == kAudioFormatMPEG4AAC ? "AAC" : String(format: "0x%08X", sub), asbd?.mSampleRate ?? 0, asbd?.mChannelsPerFrame ?? 0,
                         tr.duration.seconds, dur, pcmBytes, nonSilent))
        } else {
            print("   聲音軌：無")
        }
        // 解出頭尾畫面（不輸出內容，只檢查亮度分佈）
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .positiveInfinity
        for t in [0.0, max(dur - 0.5, 0)] {
            let (img, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
            print("   畫面 @\(String(format: "%.1f", t))s：\(imageStats(img))")
        }
    } catch {
        print("   ❌ MP4 驗證失敗：\(error.localizedDescription)")
    }
}

func imageStats(_ img: CGImage) -> String {
    let w = 160, h = 90
    var px = [UInt8](repeating: 0, count: w * h)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return "無法分析" }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var sum = 0.0, sq = 0.0
    for v in px { let d = Double(v); sum += d; sq += d * d }
    let m = sum / Double(px.count)
    let sd = max(sq / Double(px.count) - m * m, 0).squareRoot()
    return String(format: "%dx%d 亮度平均 %.1f 標準差 %.1f %@", img.width, img.height, m, sd, sd > 4 ? "✅" : "⚠️ 可能異常")
}

func runExport(host: String, port: Int, user: String, rest: [String], args: Args) async -> Int32 {
    let conn = DVRConnection(host: host, port: port, username: user) { try devPassword(user: user, host: host) }
    do {
        let chls = try await conn.connect()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard rest.count >= 3, let n = Int(rest[0]), n >= 1, n <= chls.count, let start = f.date(from: rest[1]),
              let secs = Double(rest[2]) else {
            print("用法：export <頻道> \"yyyy-MM-dd HH:mm:ss\" <秒數> [--main]"); return 1
        }
        let ch = chls[n - 1]
        let end = start.addingTimeInterval(secs)
        let tf = DateFormatter(); tf.dateFormat = "yyyyMMdd-HHmmss"
        let url = captureDir().appending(path: "export-ch\(n)-\(tf.string(from: start))-\(Int(secs))s.mp4")
        print("■ 下載 #\(n) \(ch.name)：\(rest[1]) 起 \(Int(secs)) 秒（\(await conn.usesPrivateProtocol ? "私有協定" : "WebSocket")，\(args.bool("main") ? "主串流" : "子串流")）")
        let t0 = ContinuousClock.now
        let lastPrint = Counter()
        if let after = args.flags["cancel-after"].flatMap(Double.init) {
            // 測試取消：指定秒數後取消，確認不留下檔案
            let job = Task {
                try await RecordingExporter.export(connection: conn, channelId: ch.id, start: start, end: end,
                                                   mainStream: args.bool("main"), to: url) { _ in }
            }
            try await Task.sleep(for: .seconds(after))
            job.cancel()
            let outcome: String
            do { _ = try await job.value; outcome = "❌ 未被取消（已完成）" }
            catch is CancellationError { outcome = "✅ 已取消（CancellationError）" }
            catch { outcome = "已中止：\(error)" }
            print("   \(outcome)；檔案\(FileManager.default.fileExists(atPath: url.path) ? "❌ 仍存在" : "✅ 已刪除")")
            await conn.disconnect()
            return 0
        }
        let r = try await RecordingExporter.export(connection: conn, channelId: ch.id, start: start, end: end,
                                                   mainStream: args.bool("main"), includeAudio: !args.bool("no-audio"), to: url) { p in
            lastPrint.lock.withLock {
                if p.frames - lastPrint.frames >= 200 || p.fraction >= 1 {
                    lastPrint.frames = p.frames
                    print(String(format: "   進度 %3.0f%%  %d 幀  %.1f MB", p.fraction * 100, p.frames, Double(p.bytes) / 1e6))
                }
            }
        }
        let el = Double((ContinuousClock.now - t0).components.seconds) + Double((ContinuousClock.now - t0).components.attoseconds) / 1e18
        let media = r.lastFrameTime.timeIntervalSince(r.firstFrameTime)
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"
        print(String(format: "■ 完成：%d 幀（關鍵幀 %d）、%.1f MB、%@ %dx%d、錄影 %@ → %@（%.1f 秒）、壓縮空檔 %d 處",
                     r.frames, r.keyframes, Double(r.bytes) / 1e6, r.codec.rawValue, r.width, r.height,
                     df.string(from: r.firstFrameTime), df.string(from: r.lastFrameTime), media, r.gapsRemoved))
        print(String(format: "   耗時 %.1f 秒（約即時 %.1f 倍）；聲音訊框 %d 個", el, media / max(el, 0.001), r.audioFrames))
        print("   檔案（僅本機）：\(url.path)")
        await verifyMP4(url)
    } catch {
        print("❌ \(error)")
        await conn.disconnect()
        return 3
    }
    await conn.disconnect()
    print("■ 已登出")
    return 0
}

// MARK: - 聲音探測（只輸出標頭與統計，不輸出聲音內容）

func runAudioProbe(client: NVMSClient, channel: DVRChannel, seconds: Int) async throws {
    guard let sid = await client.sessionId else { return }
    let stream = NVMSStream(host: client.host, port: client.port, sessionId: sid)
    try await stream.connect()
    try await stream.openPreview(channelId: channel.id, streamIndex: 2, audio: true)
    try? await Task.sleep(for: .milliseconds(500))
    if let tid = await stream.taskId { try await stream.send(url: "/device/preview/audio/open", data: ["task_id": tid]) }
    let watchdog = Task { try? await Task.sleep(for: .seconds(seconds + 3)); await stream.cancelSocket() }
    defer { watchdog.cancel() }
    var types: [String: (count: Int, bytes: Int, sample: Data)] = [:]
    var audioHist: [UInt8: Int] = [:]
    let t0 = ContinuousClock.now
    loop: while ContinuousClock.now - t0 < .seconds(seconds) {
        switch try await stream.receive() {
        case .frame(let f):
            let p = f.payload
            let key = p.count >= 8 ? AnnexB.hexRow(p.subdata(in: (p.startIndex + 4)..<(p.startIndex + 8)), count: 4) : "短 \(p.count)"
            if p.count > 80, p[p.startIndex + 6] == 6 {
                let ext = Int(p[p.startIndex + 45]), len = Int(p.u32le(at: 48))
                let st = 68 + ext
                if st + len <= p.count { for x in p.subdata(in: (p.startIndex + st)..<(p.startIndex + st + len)) { audioHist[x, default: 0] += 1 } }
            }
            var e = types[key] ?? (0, 0, p.prefix(96))
            e.count += 1; e.bytes += p.count
            types[key] = e
        case .message(let url, let code, let raw):
            print("   ◆ \(url) code=\(code.map(String.init) ?? "-") \(raw.prefix(200))")
        case .closed(let why):
            print("   ✖ \(why)"); break loop
        }
    }
    await stream.close(kind: .live)
    if let a = types.first(where: { $0.key.hasPrefix("03 01 06") })?.value.sample, a.count >= 96 {
        print("   聲音訊框 offset 40..96：\(AnnexB.hexRow(a.subdata(in: (a.startIndex + 40)..<(a.startIndex + 96)), count: 56))")
    }
    print("   聲音資料位元組分佈（前 5 名）：\(audioHist.sorted { $0.value > $1.value }.prefix(5).map { String(format: "0x%02X×%d", $0.key, $0.value) })")
    print("■ 訊框分類（SHFL offset 4..8）：")
    for (k, v) in types.sorted(by: { $0.value.count > $1.value.count }) {
        print("   [\(k)] \(v.count) 個、平均 \(v.bytes / max(v.count, 1)) bytes")
        print("     標頭：\(AnnexB.hexRow(v.sample, count: 72))")
    }
}

// MARK: - 聲音整合測試（音量 0，不從喇叭輸出）

func runAudioTest(host: String, port: Int, user: String, rest: [String], args: Args) async -> Int32 {
    let conn = DVRConnection(host: host, port: port, username: user) { try devPassword(user: user, host: host) }
    do {
        let chls = try await conn.connect()
        let n = Int(rest.dropFirst().first ?? "1") ?? 1
        guard n >= 1, n <= chls.count else { print("頻道錯誤"); return 1 }
        let ch = chls[n - 1]
        print("■ 聲音測試 #\(n) \(ch.name)（\(await conn.usesPrivateProtocol ? "私有協定" : "WebSocket")）")
        let c = Counter()
        if rest.first == "live" {
            let p = LiveStreamPlayer(connection: conn, channelId: ch.id, mainStream: false)
            p.audioPlayer.volume = 0
            p.onFrame = { _, t in c.frame(t) }
            p.onAudioUnsupported = { print("   ◆ DVR 回報此頻道不支援聲音") }
            p.start()
            try await Task.sleep(for: .seconds(3))
            print("   聲音關閉 3 秒：影像 \(c.snap().0) 幀、聲音 \(p.audioPlayer.fedFrames) 個")
            p.setAudio(true)
            try await Task.sleep(for: .seconds(6))
            let a1 = p.audioPlayer.fedFrames
            print("   聲音開啟 6 秒：影像累計 \(c.snap().0) 幀、聲音 \(a1) 個（\(p.audioPlayer.detectedMuLaw.map { $0 ? "μ-law" : "A-law" } ?? "未判定")）")
            p.setAudio(false)
            try await Task.sleep(for: .seconds(3))
            print("   聲音再關閉 3 秒：聲音增加 \(max(p.audioPlayer.fedFrames - a1, 0)) 個（應為 0）")
            p.stop()
        } else {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            guard rest.count >= 3, let start = f.date(from: rest[2]) else { print("用法：audiotest playback <頻道> \"時間\""); return 1 }
            let p = PlaybackStreamPlayer(connection: conn, channelId: ch.id)
            p.audioPlayer.volume = 0
            p.onFrame = { _, t in c.frame(t) }
            p.setAudio(true)
            p.play(from: start)
            try await Task.sleep(for: .seconds(6))
            print("   回放 1× 6 秒：影像 \(c.snap().0) 幀、聲音 \(p.audioPlayer.fedFrames) 個（\(p.audioPlayer.detectedMuLaw.map { $0 ? "μ-law" : "A-law" } ?? "未判定")）")
            let a1 = p.audioPlayer.fedFrames
            p.setSpeed(2)
            try await Task.sleep(for: .seconds(3))
            print("   2× 3 秒：聲音增加 \(p.audioPlayer.fedFrames - a1) 個（非 1× 不輸出，應為 0）")
            p.stop()
        }
        try await Task.sleep(for: .seconds(1))
    } catch {
        print("❌ \(error)"); await conn.disconnect(); return 3
    }
    await conn.disconnect()
    print("■ 已登出")
    return 0
}

/// 回放串流中聲音／影像訊框的序號與時間（不輸出內容）
func runPlaybackAudioProbe(client: NVMSClient, channel: DVRChannel, start: Date, seconds: Int) async throws {
    guard let sid = await client.sessionId else { return }
    let stream = NVMSStream(host: client.host, port: client.port, sessionId: sid)
    try await stream.connect()
    let s0 = Int(start.timeIntervalSince1970)
    try await stream.openPlayback(channelId: channel.id, start: s0, end: s0 + 600, streamIndex: 1)
    if let tid = await stream.taskId { try await stream.send(url: "/device/playback/audio/open", data: ["task_id": tid]) }
    let watchdog = Task { try? await Task.sleep(for: .seconds(seconds + 3)); await stream.cancelSocket() }
    defer { watchdog.cancel() }
    let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss.SSS"
    var rows: [String] = []
    var audio = 0, video = 0
    var lastVideoSeq = 0
    let t0 = ContinuousClock.now
    loop: while ContinuousClock.now - t0 < .seconds(seconds) {
        switch try await stream.receive() {
        case .frame(let fr):
            guard let f = SHFLFrame.parse(fr.payload) else { continue }
            if f.isAudio { audio += 1 } else { video += 1; lastVideoSeq = Int(f.sequence) }
            if rows.count < 40 { rows.append("\(f.isAudio ? "聲" : "影")\(f.isKeyframe && !f.isAudio ? "K" : " ") seq=\(f.sequence) \(tf.string(from: f.captureTime)) \(f.videoData.count)B") }
            // 同 App：只對影像訊框、序號 %8 回報
            if !f.isAudio, f.sequence % 8 == 0 { try? await stream.refreshPlayIndex(Int(f.sequence)) }
        case .message(let url, let code, _):
            if url.contains("audio") || (code ?? 0) != 0 { print("   ◆ \(url) code=\(code.map(String.init) ?? "-")") }
        case .closed: break loop
        }
    }
    await stream.close(kind: .playback)
    rows.forEach { print("   " + $0) }
    print("■ \(seconds) 秒：影像 \(video)、聲音 \(audio)、最後影像序號 \(lastVideoSeq)")
}

/// 逐頻道開啟即時（audio=1），統計聲音訊框（不輸出內容）
func runAudioScan(host: String, port: Int, user: String, args: Args) async -> Int32 {
    // --private：強制私有協定；--service-port：私有協定 Port（預設 6036）
    let conn = DVRConnection(host: host, port: port, username: user, servicePort: args.int("service-port", 6036), autoDetectServicePort: args.flags["service-port"] == nil) { try devPassword(user: user, host: host) }
    if args.bool("private") { await conn.setForcePrivateProtocol(true) }
    do {
        var chls = try await conn.connect()
        if let only = args.flags["channels"].flatMap(Int.init) { chls = Array(chls.prefix(only)) }
        print("■ 聲音掃描（\(await conn.usesPrivateProtocol ? "私有協定" : "WebSocket")）")
        for ch in chls {
            let ms = try await conn.openLive(channelId: ch.id, mainStream: false, audio: true)
            if let f = ms.setAudio { await f(true) }
            var a = 0, v = 0
            let t = Task { try? await Task.sleep(for: .seconds(3)); await ms.close() }
            for try await p in ms.frames { if let f = SHFLFrame.parse(p) { if f.isAudio { a += 1 } else { v += 1 } } }
            t.cancel()
            print("   #\(ch.index + 1) \(ch.name)：影像 \(v)、聲音 \(a)\(ms.audioUnsupported() ? "（DVR 回報不支援）" : "")")
        }
    } catch { print("❌ \(error)") }
    await conn.disconnect()
    return 0
}

/// 同一條 WebSocket 同時開 N 個頻道的即時影像，依 task_id 統計（驗證 DVR 是否支援多工）
func runMuxTest(client: NVMSClient, channels: [DVRChannel], seconds: Int) async throws {
    guard let sid = await client.sessionId else { return }
    let stream = NVMSStream(host: client.host, port: client.port, sessionId: sid)
    try await stream.connect()
    var taskToCh: [String: Int] = [:]
    for ch in channels {
        let tid = NVMSStream.newTaskId()
        taskToCh[tid.uppercased()] = ch.index + 1
        try await stream.send(url: "/device/preview/open", data: ["task_id": tid, "channel_id": ch.id, "stream_index": 2, "audio": false])
    }
    let watchdog = Task { try? await Task.sleep(for: .seconds(seconds + 3)); await stream.cancelSocket() }
    defer { watchdog.cancel() }
    var counts: [Int: Int] = [:]
    var errors: [String] = []
    let t0 = ContinuousClock.now
    loop: while ContinuousClock.now - t0 < .seconds(seconds) {
        switch try await stream.receive() {
        case .frame(let f):
            let tid = (f.json["task_id"] as? String ?? "").uppercased()
            counts[taskToCh[tid] ?? -1, default: 0] += 1
        case .message(let url, let code, let raw):
            if let code, code != 0 { errors.append("\(url) code=\(code) \(raw.prefix(120))") }
        case .closed(let why): print("   ✖ \(why)"); break loop
        }
    }
    for tid in taskToCh.keys {
        try? await stream.send(url: "/device/preview/close", data: ["task_id": tid])
    }
    await stream.close(kind: .live)
    print("■ 單一 WebSocket、\(channels.count) 個頻道、\(seconds) 秒：")
    for ch in channels.map({ $0.index + 1 }) { print("   頻道 \(ch)：\(counts[ch] ?? 0) 幀") }
    if let u = counts[-1] { print("   無法對應 task_id：\(u)") }
    errors.prefix(5).forEach { print("   ◆ " + $0) }
}

/// 同時開 N 個即時串流（經 DVRConnection，與 App 相同路徑），統計每個頻道的幀數
func runMultiLive(conn: DVRConnection, channels: [DVRChannel], seconds: Int) async {
    let results = await withTaskGroup(of: (Int, Int, String?).self) { g in
        for ch in channels {
            g.addTask {
                do {
                    let ms = try await conn.openLive(channelId: ch.id, mainStream: false)
                    var n = 0
                    let t0 = ContinuousClock.now
                    let reader = Task { () -> Int in
                        var c = 0
                        do { for try await _ in ms.frames { c += 1; if ContinuousClock.now - t0 > .seconds(seconds) { break } } } catch {}
                        return c
                    }
                    try? await Task.sleep(for: .seconds(seconds + 1))
                    await ms.close()
                    reader.cancel()
                    n = await reader.value
                    return (ch.index + 1, n, nil)
                } catch { return (ch.index + 1, 0, error.localizedDescription) }
            }
        }
        var r: [(Int, Int, String?)] = []
        for await x in g { r.append(x) }
        return r.sorted { $0.0 < $1.0 }
    }
    print("■ 同時 \(channels.count) 個即時串流（\(await conn.usesPrivateProtocol ? "私有協定" : "WebSocket")）、\(seconds) 秒：")
    for (ch, n, e) in results { print("   頻道 \(ch)：\(n) 幀" + (e.map { "  ✖ \($0)" } ?? "")) }
}

/// 與 App 相同：N 個 LiveStreamPlayer 同時播放，定期列出每個頻道的解碼幀數與狀態
func runPageSwitch(conn: DVRConnection, all: [DVRChannel], per: Int, rounds: Int, hold: Int) async {
    // 模擬 App 換頁：關掉目前一頁的播放器（不等待關閉完成），立刻開下一頁
    final class Stat: @unchecked Sendable { let lock = NSLock(); var frames: [Int: Int] = [:] }
    var players: [LiveStreamPlayer] = []
    let pages = stride(from: 0, to: all.count, by: per).map { Array(all[$0..<min($0 + per, all.count)]) }
    for r in 0..<rounds {
        players.forEach { $0.stop() }
        let page = pages[r % pages.count]
        let st = Stat()
        players = page.map { ch in
            let n = ch.index + 1
            let p = LiveStreamPlayer(connection: conn, channelId: ch.id, mainStream: false)
            p.onFrame = { _, _ in st.lock.withLock { st.frames[n, default: 0] += 1 } }
            p.start(); return p
        }
        try? await Task.sleep(for: .seconds(hold))
        let f = st.lock.withLock { st.frames }
        let dead = page.filter { (f[$0.index + 1] ?? 0) == 0 }.map { "\($0.index + 1)" }
        print("第 \(r + 1) 次（頁 \(r % pages.count + 1)）：" + page.map { "\($0.index + 1):\(f[$0.index + 1] ?? 0)" }.joined(separator: " ")
              + (dead.isEmpty ? "" : "  ✖ 無畫面：" + dead.joined(separator: ",")))
    }
    players.forEach { $0.stop() }
    try? await Task.sleep(for: .seconds(1))
}

func runMultiPlayer(conn: DVRConnection, channels: [DVRChannel], seconds: Int) async {
    final class Stat: @unchecked Sendable {
        let lock = NSLock(); var frames: [Int: Int] = [:]; var state: [Int: String] = [:]
    }
    let st = Stat()
    var players: [LiveStreamPlayer] = []
    for ch in channels {
        let n = ch.index + 1
        let p = LiveStreamPlayer(connection: conn, channelId: ch.id, mainStream: false)
        p.onFrame = { _, _ in st.lock.withLock { st.frames[n, default: 0] += 1 } }
        p.onState = { s in st.lock.withLock { st.state[n] = "\(s)" } }
        p.start(); players.append(p)
    }
    var last: [Int: Int] = [:]
    for t in stride(from: 5, through: seconds, by: 5) {
        try? await Task.sleep(for: .seconds(5))
        let (f, s) = st.lock.withLock { (st.frames, st.state) }
        let row = channels.map { c -> String in
            let n = c.index + 1; let d = (f[n] ?? 0) - (last[n] ?? 0)
            return "\(n):\(d)" + ((s[n] ?? "").contains("playing") ? "" : "[\(s[n] ?? "-")]")
        }
        last = f
        print("t=\(t)s " + row.joined(separator: " "))
    }
    players.forEach { $0.stop() }
    try? await Task.sleep(for: .seconds(1))
}

/// 多路同步回放：N 個 PlaybackStreamPlayer 共用時鐘，統計各路幀數與播放時間差
func runMultiPlayback(conn: DVRConnection, channels: [DVRChannel], start: Date, seconds: Int, speed: Double) async {
    final class Stat: @unchecked Sendable { let lock = NSLock(); var frames: [Int: Int] = [:] }
    let st = Stat()
    let clock = PlaybackClock()
    clock.setSpeed(speed)
    let players = channels.map { ch -> PlaybackStreamPlayer in
        let n = ch.index + 1
        let p = PlaybackStreamPlayer(connection: conn, channelId: ch.id, mainStream: true)
        p.clock = clock
        p.setSpeed(speed)
        p.onFrame = { _, _ in st.lock.withLock { st.frames[n, default: 0] += 1 } }
        return p
    }
    players.forEach { $0.play(from: start) }
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.S"
    var last: [Int: Int] = [:]
    for t in stride(from: 5, through: seconds, by: 5) {
        try? await Task.sleep(for: .seconds(5))
        let fr = st.lock.withLock { st.frames }
        let times = players.compactMap(\.time)
        let spread = (times.max().map { mx in times.min().map { mx.timeIntervalSince($0) } ?? 0 }) ?? 0
        let row = channels.map { c -> String in let n = c.index + 1; return "\(n):\((fr[n] ?? 0) - (last[n] ?? 0))" }.joined(separator: " ")
        last = fr
        print("t=\(t)s 時鐘 \(clock.now.map { f.string(from: $0) } ?? "-")  各路時間差 \(String(format: "%.2f", spread)) 秒  幀數 " + row)
        if t == 10 { clock.pause(); players.forEach { $0.pause() }; print("   （暫停 3 秒）"); try? await Task.sleep(for: .seconds(3)); clock.resume(); players.forEach { $0.resume() } }
    }
    players.forEach { $0.stop() }
    try? await Task.sleep(for: .seconds(1))
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
    devPort = port
    let rest = Array(args.positional.dropFirst(4))
    if cmd == "multiplayback" {
        // multiplayback <N> "yyyy-MM-dd HH:mm:ss" [--seconds S --speed X]
        let conn = DVRConnection(host: host, port: port, username: user, servicePort: args.int("service-port", 6036), autoDetectServicePort: args.flags["service-port"] == nil) { try devPassword(user: user, host: host) }
        do {
            let chls = try await conn.connect()
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            guard rest.count >= 2, let start = df.date(from: rest[1]) else { print("用法：multiplayback <N> \"yyyy-MM-dd HH:mm:ss\""); return 1 }
            await runMultiPlayback(conn: conn, channels: Array(chls.prefix(Int(rest[0]) ?? 4)), start: start,
                                   seconds: args.int("seconds", 20), speed: Double(args.flags["speed"] ?? "1") ?? 1)
        } catch { print("✖ \(error.localizedDescription)"); return 1 }
        await conn.disconnect()
        return 0
    }
    if cmd == "multiplayer" {
        let conn = DVRConnection(host: host, port: port, username: user, servicePort: args.int("service-port", 6036), autoDetectServicePort: args.flags["service-port"] == nil) { try devPassword(user: user, host: host) }
        do {
            let chls = try await conn.connect()
            if args.flags["pages"] != nil {
                await runPageSwitch(conn: conn, all: chls, per: Int(rest.first ?? "9") ?? 9, rounds: args.int("pages", 8), hold: args.int("hold", 8))
            } else {
                await runMultiPlayer(conn: conn, channels: Array(chls.prefix(Int(rest.first ?? "16") ?? 16)), seconds: args.int("seconds", 30))
            }
        } catch { print("✖ \(error.localizedDescription)"); return 1 }
        await conn.disconnect()
        return 0
    }
    if cmd == "multilive" {
        // multilive <N> [--private --service-port P --seconds S]
        let conn = DVRConnection(host: host, port: port, username: user, servicePort: args.int("service-port", 6036), autoDetectServicePort: args.flags["service-port"] == nil) { try devPassword(user: user, host: host) }
        if args.bool("private") { await conn.setForcePrivateProtocol(true) }
        do {
            let chls = try await conn.connect()
            await runMultiLive(conn: conn, channels: Array(chls.prefix(Int(rest.first ?? "9") ?? 9)), seconds: args.int("seconds", 5))
        } catch { print("✖ \(error.localizedDescription)"); return 1 }
        await conn.disconnect()
        return 0
    }
    if cmd == "overlap" {
        // overlap [頻道序號] [--service-port P]：模擬放大畫面——同一頻道開新任務後再關閉舊任務，新任務須持續有影像
        let sp = args.int("service-port", 6036)
        let chNo = (Int(rest.first ?? "") ?? 1) - 1
        let guid = String(format: "{%08X-0000-0000-0000-000000000000}", chNo + 1)
        let c = TVTPrivateClient(host: host, port: sp)
        func count(_ s: AsyncThrowingStream<Data, Error>, seconds: Double) async -> (Int, String) {
            let box = Task { () -> (Int, String) in
                var n = 0
                do { for try await _ in s { n += 1 } } catch { return (n, "\(error)") }
                return (n, Task.isCancelled ? "到時" : "串流已結束")
            }
            try? await Task.sleep(for: .seconds(seconds))
            box.cancel()
            return await box.value
        }
        do {
            try await c.connect(user: user, password: try devPassword(user: user, host: host))
            let a = try await c.openLive(channelGUID: guid, chNo: chNo, streamType: 2)
            let (na, _) = await count(a.frames, seconds: 3)
            print("■ 舊任務 3 秒：\(na) 個訊框")
            let b = try await c.openLive(channelGUID: guid, chNo: chNo, streamType: 2)
            await c.closeLive(channelGUID: guid, chNo: chNo, task: a.task)
            let (nb, why) = await count(b.frames, seconds: 6)
            print("■ 關閉舊任務後，新任務 6 秒：\(nb) 個訊框（\(nb > 0 && why != "串流已結束" ? "✅ 持續" : "❌ " + why)）")
            await c.closeLive(channelGUID: guid, chNo: chNo, task: b.task)
            await c.disconnect()
        } catch { print("✖ \(error.localizedDescription)"); return 1 }
        return 0
    }
    if cmd == "privid" {
        // privid [--service-port P]：私有協定登入，列出設備 GUID 與回應中的可讀文字（辨識是哪一台設備）
        let sp = args.int("service-port", 6036)
        let c = TVTPrivateClient(host: host, port: sp)
        do {
            try await c.connect(user: user, password: try devPassword(user: user, host: host))
            let r = await c.loginReply
            print("■ \(host):\(sp) 設備 GUID：\(TVTGUID.string(await c.deviceGUID))，回應 \(r.count) bytes")
            var run = "", runs: [String] = []
            for b in r { if b >= 0x20 && b < 0x7F { run.append(Character(UnicodeScalar(b))) } else { if run.count >= 4 { runs.append(run) }; run = "" } }
            if run.count >= 4 { runs.append(run) }
            print("   可讀文字：\(runs)")
            await c.disconnect()
        } catch { print("✖ \(error.localizedDescription)"); return 1 }
        return 0
    }
    if cmd == "audioscan" { return await runAudioScan(host: host, port: port, user: user, args: args) }
    if cmd == "audiotest" {
        return await runAudioTest(host: host, port: port, user: user, rest: rest, args: args)
    }
    if cmd == "export" {
        return await runExport(host: host, port: port, user: user, rest: rest, args: args)
    }
    if cmd == "events" {
        // events <yyyy-MM-dd> [頻道序號…]：列出移動偵測等事件（錄影區段＋系統日誌）
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: rest.first ?? "") else { print("用法：events <yyyy-MM-dd> [頻道序號…]"); return 1 }
        let conn = DVRConnection(host: host, port: port, username: user) { try devPassword(user: user, host: host) }
        do {
            let chls = try await conn.connect()
            let pick = rest.dropFirst().compactMap { Int($0) }.filter { $0 >= 1 && $0 <= chls.count }.map { chls[$0 - 1] }
            let use = pick.isEmpty ? chls : pick
            let t0 = Date()
            let ev = await conn.events(channelIds: use.map(\.id), day: d)
            let denied = await conn.alarmLogDenied
            print("■ \(rest[0]) 事件 \(ev.count) 筆（\(use.count) 個頻道，\(String(format: "%.1f", Date().timeIntervalSince(t0))) 秒）；系統日誌：\(denied ? "帳號無權限，未使用" : "已查詢")")
            let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
            for c in use {
                let e = ev.filter { $0.channelId == c.id }
                guard !e.isEmpty else { continue }
                let byType = Dictionary(grouping: e, by: \.type).map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: " ")
                let samples = e.prefix(3).map { x -> String in
                    let dur = x.end.map { "（\(Int($0.timeIntervalSince(x.start))) 秒）" } ?? "（日誌）"
                    return tf.string(from: x.start) + dur
                }
                print("   #\(c.index + 1) \(e.count) 筆 [\(byType)] 例：" + samples.joined(separator: " "))
            }
        } catch { print("✖ \(error.localizedDescription)"); return 1 }
        await conn.disconnect()
        return 0
    }
    if cmd == "chcheck" {
        return await runChannelCheck(host: host, port: port, user: user, day: rest.first ?? "")
    }
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

        case "pbaudioprobe":
            guard let c = channel(rest.first), rest.count >= 2 else { print("用法：pbaudioprobe <頻道> \"時間\""); exitCode = 1; break }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            guard let st = f.date(from: rest[1]) else { exitCode = 1; break }
            try await runPlaybackAudioProbe(client: client, channel: c, start: st, seconds: args.int("seconds", 4))

        case "muxtest":
            let n = Int(rest.first ?? "9") ?? 9
            try await runMuxTest(client: client, channels: Array(chls.prefix(n)), seconds: args.int("seconds", 5))

        case "audioprobe":
            guard let c = channel(rest.first) else { print("找不到頻道"); exitCode = 1; break }
            print("■ 聲音探測：頻道 #\(c.index + 1) \(c.name)")
            try await runAudioProbe(client: client, channel: c, seconds: args.int("seconds", 6))

        case "snapshot":
            guard let c = channel(rest.first) else { print("找不到頻道"); exitCode = 1; break }
            print("■ 即時截圖：頻道 #\(c.index + 1) \(c.name) \(args.bool("main") ? "主串流" : "子串流")")
            try await runSnapshot(client: client, channel: c, main: args.bool("main"), frames: args.int("frames", 30))

        case "serviceport":
            let conn = DVRConnection(host: host, port: port, username: user, autoDetectServicePort: true) { try devPassword(user: user, host: host) }
            try await conn.connect()
            print("■ DVR 設定的影像服務 Port：\(await conn.detectedServicePort.map(String.init) ?? "查不到")；連線將使用 \(await conn.servicePort)")
            await conn.disconnect()

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
