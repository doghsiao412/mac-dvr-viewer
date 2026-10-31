import AppKit
import DVRKit
import SwiftUI

/// 下載錄影：選擇攝影機（可多選）、時間範圍與儲存位置
struct ExportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let ref: CameraRef
    let suggestedStart: Date
    let ranges: [DVRConnection.RecordRange]

    @State private var start = Date()
    @State private var end = Date()
    @State private var minutes = 5
    @State private var custom = false
    @State private var includeAudio = true
    @State private var folder = ExportManager.defaultFolder
    /// 要下載的頻道（同一台 DVR，可多選；預設為目前回放的頻道）
    @State private var selected: Set<String> = []

    private let presets = [1, 5, 10, 30, 60]

    private var device: DeviceModel? { store.device(ref.deviceID) }
    private var effectiveEnd: Date { custom ? end : start.addingTimeInterval(TimeInterval(minutes * 60)) }

    /// 範圍內實際有錄影的秒數（依時間軸資料）
    private var recordedSeconds: TimeInterval {
        let a = start, b = effectiveEnd
        return ranges.reduce(0) { acc, r in
            let s = max(r.start, a), e = min(r.end, b)
            return acc + max(e.timeIntervalSince(s), 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(device?.orderedChannels ?? []) { ch in
                                Toggle(device?.displayName(ch.id) ?? ch.name, isOn: Binding(
                                    get: { selected.contains(ch.id) },
                                    set: { if $0 { selected.insert(ch.id) } else { selected.remove(ch.id) } }))
                                    .toggleStyle(.checkbox)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 130)
                    HStack {
                        Button("全選") { selected = Set(device?.orderedChannels.map(\.id) ?? []) }
                        Button("只選目前頻道") { selected = [ref.channelID] }
                        Spacer()
                        Text("已選 \(selected.count) 支").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.link)
                } header: {
                    Text("攝影機（\(device?.config.name ?? "")）")
                } footer: {
                    if selected.count > ExportManager.perDeviceLimit {
                        Text("同一台 DVR 同時下載 \(ExportManager.perDeviceLimit) 支，其餘會排隊依序下載，每支存成一個 MP4。")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    DatePicker("開始", selection: $start, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field)
                    Picker("長度", selection: Binding(get: { custom ? -1 : minutes },
                                                    set: { if $0 < 0 { custom = true; end = effectiveEnd } else { custom = false; minutes = $0 } })) {
                        ForEach(presets, id: \.self) { Text("\($0) 分鐘").tag($0) }
                        Text("自訂結束時間").tag(-1)
                    }
                    if custom {
                        DatePicker("結束", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.field)
                    }
                    LabeledContent("範圍內有錄影（\(store.name(of: ref))）") {
                        Text(recordedText).foregroundStyle(recordedSeconds > 0 ? Color.secondary : Color.orange)
                    }
                } header: { Text("時間範圍") } footer: {
                    Text("無錄影的空檔會自動略過；影像不轉碼（H.265/H.264），聲音轉為 AAC，存成 MP4。")
                        .foregroundStyle(.secondary)
                }
                Section("輸出") {
                    Toggle("包含聲音（轉為 AAC）", isOn: $includeAudio)
                    LabeledContent("儲存位置") {
                        HStack {
                            Text(folder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                            Button("選擇…") { chooseFolder() }
                        }
                    }
                }
            }
            .formStyle(.grouped)


            HStack {
                Spacer()
                Button("關閉") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("開始下載") { startExport() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(device == nil || effectiveEnd <= start || selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520)
        .onAppear {
            selected = [ref.channelID]
            start = Calendar.current.date(bySetting: .second, value: 0, of: suggestedStart) ?? suggestedStart
            end = start.addingTimeInterval(300)
        }
    }

    private var recordedText: String {
        let s = Int(recordedSeconds)
        if ranges.isEmpty { return "（未載入時間軸，無法預估）" }
        if s == 0 { return "這段時間沒有錄影" }
        return s >= 60 ? "約 \(s / 60) 分 \(s % 60) 秒" : "約 \(s) 秒"
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = folder
        p.prompt = "選擇"
        if p.runModal() == .OK, let u = p.url { folder = u }
    }

    private func startExport() {
        guard let dev = device else { return }
        let e = effectiveEnd
        Notifier.shared.requestAuthorizationIfNeeded()
        // 依頻道順序建立下載工作（每支一個 MP4；超過上限的會排隊）
        for ch in dev.orderedChannels where selected.contains(ch.id) {
            let r = CameraRef(deviceID: dev.id, channelID: ch.id)
            let name = ExportManager.suggestedName(device: dev.config.name, channel: store.name(of: r), start: start, end: e)
            var url = folder.appending(path: name)
            // 避免覆蓋既有檔案
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appending(path: name.replacingOccurrences(of: ".mp4", with: "-\(n).mp4"))
                n += 1
            }
            store.exports.start(connection: dev.connection, channelID: ch.id,
                                title: "\(dev.config.name) · \(store.name(of: r))", start: start, end: e,
                                mainStream: true, includeAudio: includeAudio, to: url) { job in
                switch job.state {
                case .done(let detail):
                    store.showToast("下載完成：\(job.url.lastPathComponent)")
                    Notifier.shared.downloadFinished(file: job.url, detail: detail)
                case .failed(let m):
                    store.showToast("下載失敗：\(m)")
                    Notifier.shared.downloadFailed(title: job.title, reason: m)
                default: break
                }
            }
        }
        // 像 Safari：關閉視窗，下載圖示飛到右上角的下載按鈕
        store.downloadFlight += 1
        dismiss()
    }
}

/// 下載工作清單（下載視窗與工具列彈出視窗共用）
struct ExportJobsList: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("下載").font(.headline)
                Spacer()
                if store.exports.jobs.contains(where: { !$0.isRunning }) {
                    Button("清除已完成") { store.exports.clearFinished() }
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.exports.jobs) { job in
                        ExportJobRow(job: job)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }
}

struct ExportJobRow: View {
    @Environment(AppStore.self) private var store
    let job: ExportManager.Job

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.callout.weight(.medium))
                Text("\(job.start, format: .dateTime.month().day().hour().minute()) – \(job.end, format: .dateTime.hour().minute())")
                    .font(.caption).foregroundStyle(.secondary)
                switch job.state {
                case .queued:
                    Text("排隊中（同一台 DVR 同時最多下載 \(ExportManager.perDeviceLimit) 路）")
                        .font(.caption2).foregroundStyle(.secondary)
                case .running:
                    ProgressView(value: job.fraction)
                    Text(progressText).font(.caption2).foregroundStyle(.secondary)
                case .done(let t):
                    Text(t).font(.caption).foregroundStyle(.secondary)
                case .failed(let m):
                    Text(m).font(.caption).foregroundStyle(.red)
                case .cancelled:
                    Text("已取消").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch job.state {
            case .running, .queued:
                Button { store.exports.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("取消下載")
            case .done:
                Button { store.exports.open(job) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless).help("開啟")
                Button { store.exports.reveal(job) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless).help("在 Finder 中顯示")
            default:
                EmptyView()
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch job.state {
        case .queued: return "clock"
        case .running: return "arrow.down.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private var color: Color {
        switch job.state {
        case .queued: return .secondary
        case .running: return .accentColor
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private var progressText: String {
        var s = String(format: "%.0f%%", job.fraction * 100)
        if let t = job.mediaTime {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            s += " · 已到 \(f.string(from: t))"
        }
        if job.bytes > 0 { s += String(format: " · %.1f MB", Double(job.bytes) / 1e6) }
        return s
    }
}

/// 工具列上的下載狀態按鈕（有下載工作時顯示）
struct ExportToolbarButton: View {
    @Environment(AppStore.self) private var store
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            if store.exports.runningCount > 0 {
                ZStack {
                    ProgressView(value: store.exports.overallFraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold))
                }
            } else {
                Image(systemName: "arrow.down.circle")
            }
        }
        .symbolEffect(.bounce, value: store.downloadLanded)
        .help("下載")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ExportJobsList()
                .frame(width: 380, height: 300)
        }
    }
}
