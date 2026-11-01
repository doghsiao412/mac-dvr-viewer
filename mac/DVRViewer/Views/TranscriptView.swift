import AppKit
import DVRKit
import SwiftUI
import UniformTypeIdentifiers

/// 逐字稿的狀態（放在回放頁，關閉面板後保留結果）
@MainActor
@Observable
final class TranscriptModel {
    enum Phase: Equatable {
        case idle
        case running(fraction: Double, lines: Int)
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var ref: CameraRef?
    private(set) var range: ClosedRange<Date>?
    private(set) var lines: [RecordingTranscriber.Line] = []
    private(set) var summary: String?
    private(set) var summarizing = false
    private(set) var summaryError: String?
    /// 潤飾後的文字（與 lines 一一對應；參考用，不取代原始辨識）
    private(set) var polished: [String]?
    private(set) var polishing = false
    private(set) var polishProgress = 0.0
    private(set) var polishError: String?
    /// 顯示潤飾後（預設顯示原始辨識）
    var showPolished = false
    private var task: Task<Void, Never>?

    var isRunning: Bool { if case .running = phase { return true } else { return false } }

    func start(connection: DVRConnection, ref: CameraRef, range: ClosedRange<Date>) {
        task?.cancel()
        self.ref = ref
        self.range = range
        lines = []
        summary = nil
        summaryError = nil
        polished = nil
        polishError = nil
        showPolished = false
        phase = .running(fraction: 0, lines: 0)
        task = Task { [weak self] in
            do {
                let result = try await RecordingTranscriber.transcribe(
                    connection: connection, channelId: ref.channelID,
                    start: range.lowerBound, end: range.upperBound) { p in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning else { return }
                        self.phase = .running(fraction: p.fraction, lines: p.lines)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.lines = result
                self.phase = .done
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func summarize() {
        guard !lines.isEmpty, !summarizing else { return }
        summarizing = true
        summaryError = nil
        let lines = lines
        Task { [weak self] in
            do {
                let s = try await TranscriptSummarizer.summarize(lines)
                self?.summary = s
            } catch {
                self?.summaryError = "摘要失敗：\(error.localizedDescription)"
            }
            self?.summarizing = false
        }
    }

    func polish() {
        guard !lines.isEmpty, !polishing else { return }
        polishing = true
        polishProgress = 0
        polishError = nil
        let lines = lines
        Task { [weak self] in
            do {
                let p = try await TranscriptPolisher.polish(lines) { v in
                    Task { @MainActor [weak self] in self?.polishProgress = v }
                }
                self?.polished = p
                self?.showPolished = true
                if !TranscriptPolisher.lastFailures.isEmpty {
                    self?.polishError = "部分句子無法潤飾，保留原文"
                }
            } catch {
                self?.polishError = "潤飾失敗：\(error.localizedDescription)"
            }
            self?.polishing = false
        }
    }

    /// 某句目前要顯示的文字（潤飾後模式且有潤飾結果時用潤飾文字）
    func displayText(_ line: RecordingTranscriber.Line) -> String {
        guard showPolished, let p = polished, p.indices.contains(line.id) else { return line.text }
        return p[line.id]
    }

    /// 存成文字檔的內容
    func plainText(title: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let d = DateFormatter()
        d.dateFormat = "yyyy/MM/dd HH:mm:ss"
        var out = "\(title)\n"
        if let r = range { out += "\(d.string(from: r.lowerBound)) – \(f.string(from: r.upperBound))\n" }
        out += "（此為Mac語音轉錄及本地Apple Intelligence潤飾或摘要，會受到原始語音品質影響，內容需謹慎核對）\n\n"
        for l in lines { out += "\(f.string(from: l.start))  \(l.text)\n" }
        if let p = polished {
            out += "\n潤飾後（Apple Intelligence 校對，僅供參考，以原始辨識為準）\n"
            for (l, t) in zip(lines, p) { out += "\(f.string(from: l.start))  \(t)\n" }
        }
        if let s = summary { out += "\n摘要（Apple Intelligence）\n\(s)\n" }
        return out
    }

    static func describe(_ e: Error) -> String {
        if let t = e as? RecordingTranscriber.TranscribeError { return t.description }
        if let n = e as? NVMSError { return n.description }
        return e.localizedDescription
    }
}

/// 回放頁右側的逐字稿面板：選範圍 → 轉錄 → 點句子跳到該時間、搜尋、摘要、存檔
struct TranscriptPanel: View {
    @Bindable var model: TranscriptModel
    let ref: CameraRef?
    let name: (CameraRef) -> String
    let markedRange: ClosedRange<Date>?
    let current: Date?
    let connection: DVRConnection?
    let onPick: (CameraRef, Date) -> Void

    @State private var query = ""
    @State private var minutesBefore = 5

    static let maxDuration: TimeInterval = 60 * 60

    private var time: DateFormatter {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }

    /// 要轉錄的範圍：有標記用標記，否則目前時間往前 N 分鐘
    private var chosenRange: ClosedRange<Date>? {
        if let m = markedRange { return m }
        guard let c = current else { return nil }
        return c.addingTimeInterval(-Double(minutesBefore) * 60)...c
    }

    private var shown: [RecordingTranscriber.Line] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? model.lines : model.lines.filter { model.displayText($0).localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(12)
            Divider()
            switch model.phase {
            case .running(let fraction, let n):
                VStack(spacing: 10) {
                    ProgressView(value: fraction)
                    Text("轉錄中… 已轉出 \(n) 句").font(.callout).foregroundStyle(.secondary)
                    Button("取消") { model.cancel() }
                }
                .padding(20)
                Spacer()
            case .done where !model.lines.isEmpty:
                results
            default:
                setup
            }
        }
        .frame(minWidth: 300)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("逐字稿", systemImage: "text.quote").font(.headline)
            if let r = model.ref, model.phase != .idle, let range = model.range {
                Text("\(name(r))　\(time.string(from: range.lowerBound))–\(time.string(from: range.upperBound))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let r = ref {
                Text(name(r)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 選範圍

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            if case .failed(let why) = model.phase {
                Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            if case .done = model.phase, model.lines.isEmpty {
                Label("這段錄影沒有辨識出任何語句（可能沒有人說話，或攝影機沒有收音）", systemImage: "waveform.slash")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if markedRange != nil {
                Label("使用時間軸上標記的範圍", systemImage: "bracket.square.left.fill")
                    .foregroundStyle(RecordTimeline.markColor)
            } else {
                Picker("範圍", selection: $minutesBefore) {
                    Text("目前時間往前 1 分鐘").tag(1)
                    Text("目前時間往前 5 分鐘").tag(5)
                    Text("目前時間往前 10 分鐘").tag(10)
                    Text("目前時間往前 30 分鐘").tag(30)
                }
                Text("也可以先在時間軸標記範圍（I／O，或按住 Shift 拖曳）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let r = chosenRange {
                let secs = Int(r.upperBound.timeIntervalSince(r.lowerBound))
                LabeledContent("時間") {
                    Text("\(time.string(from: r.lowerBound))–\(time.string(from: r.upperBound))（\(EventListView.duration(Double(secs)))）")
                        .monospacedDigit()
                }
                if Double(secs) > Self.maxDuration {
                    Text("一次最多 60 分鐘，請縮短範圍。").font(.caption).foregroundStyle(.red)
                }
            } else {
                Text("請先選擇攝影機並開始播放。").font(.callout).foregroundStyle(.secondary)
            }
            Button {
                if let c = connection, let r = ref, let range = chosenRange { model.start(connection: c, ref: r, range: range) }
            } label: {
                Label("開始轉錄", systemImage: "waveform").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(connection == nil || ref == nil || chosenRange == nil
                      || (chosenRange.map { $0.upperBound.timeIntervalSince($0.lowerBound) > Self.maxDuration } ?? true))
            Text("此為Mac語音轉錄及本地Apple Intelligence潤飾或摘要，會受到原始語音品質影響，內容需謹慎核對。全部在本機處理，不會上傳；只有附麥克風的攝影機才有聲音。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(16)
    }

    // MARK: - 結果

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("搜尋逐字稿", text: $query).textFieldStyle(.roundedBorder)
                Menu {
                    Button("存成文字檔…") { save() }
                    Button("拷貝全部") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.plainText(title: title), forType: .string)
                    }
                    Divider()
                    Button("重新選擇範圍") { model.cancel() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(12)

            summarySection
            polishSection
            Divider()

            ScrollViewReader { proxy in
                List(shown) { line in
                    row(line)
                        .contentShape(Rectangle())
                        .onTapGesture { if let r = model.ref { onPick(r, line.start) } }
                        .listRowBackground(isCurrent(line) ? Color.accentColor.opacity(0.15) : Color.clear)
                        .id(line.id)
                }
                .listStyle(.plain)
                .onChange(of: currentLineID) { _, id in
                    if let id, query.isEmpty { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            HStack {
                Text(query.isEmpty ? "\(model.lines.count) 句" : "符合 \(shown.count) 句")
                Spacer()
                Text("點一下句子跳到該時間")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    @ViewBuilder private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = model.summary {
                Label("摘要", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                ScrollView {
                    Text(s).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            } else if model.summarizing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Apple Intelligence 摘要中…").font(.callout) }
            } else if let why = TranscriptSummarizer.unavailableReason {
                Label(why, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
            } else {
                Button { model.summarize() } label: { Label("用 Apple Intelligence 摘要", systemImage: "sparkles") }
            }
            if let e = model.summaryError { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    /// 潤飾：Apple Intelligence 修正錯字與標點（參考用），可切換原始辨識／潤飾後
    @ViewBuilder private var polishSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.polished != nil {
                Picker("顯示", selection: $model.showPolished) {
                    Text("原始辨識").tag(false)
                    Text("潤飾後（參考）").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.showPolished {
                    Text("Apple Intelligence 依上下文修正錯字與標點，可能改錯，請以原始辨識為準。有修改的句子下方會顯示原文。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if model.polishing {
                HStack(spacing: 8) {
                    ProgressView(value: model.polishProgress).frame(width: 80)
                    Text("Apple Intelligence 潤飾中…").font(.callout)
                }
            } else if TranscriptSummarizer.isAvailable {
                Button { model.polish() } label: { Label("用 Apple Intelligence 潤飾（參考）", systemImage: "wand.and.stars") }
                    .help("修正同音錯字、補標點；不會取代原始辨識")
            }
            if let e = model.polishError { Text(e).font(.caption).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private func row(_ line: RecordingTranscriber.Line) -> some View {
        let shown = model.displayText(line)
        return VStack(alignment: .leading, spacing: 2) {
            Text(time.string(from: line.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(highlighted(shown)).font(.body).textSelection(.enabled)
            if model.showPolished, shown != line.text {
                Text("原文：\(line.text)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    /// 搜尋字詞標成黃色
    private func highlighted(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return a }
        var searchStart = a.startIndex
        while let r = a[searchStart...].range(of: q, options: .caseInsensitive) {
            a[r].backgroundColor = .yellow.opacity(0.5)
            searchStart = r.upperBound
        }
        return a
    }

    private var currentLineID: Int? {
        guard let c = current, model.ref == ref else { return nil }
        return model.lines.last(where: { $0.start <= c })?.id
    }

    private func isCurrent(_ line: RecordingTranscriber.Line) -> Bool {
        guard let c = current, model.ref == ref else { return false }
        return line.start <= c && c <= max(line.end, line.start.addingTimeInterval(1))
    }

    private var title: String {
        "逐字稿：\(model.ref.map(name) ?? "攝影機")"
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "\(title.replacingOccurrences(of: "：", with: "-"))-\(model.range.map { f.string(from: $0.lowerBound) } ?? "").txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.plainText(title: title).write(to: url, atomically: true, encoding: .utf8)
    }
}
