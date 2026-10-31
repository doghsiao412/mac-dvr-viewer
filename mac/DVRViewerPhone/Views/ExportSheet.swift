import DVRKit
import Photos
import SwiftUI

/// 下載一段錄影成 MP4（不轉碼），完成後可存到「照片」或分享／存到「檔案」。
/// 檔案先放在 App 的暫存資料夾，關閉此畫面時刪除。
struct ExportSheet: View {
    let device: DeviceModel
    let channelID: String
    let initialStart: Date
    let mainStream: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var seconds: Int = 60
    @State private var highQuality = false
    @State private var includeAudio = true
    @State private var phase: Phase = .setup
    @State private var task: Task<Void, Never>?
    @State private var saveMessage: String?

    private let lengths = [30, 60, 120, 300, 600, 1800]

    enum Phase: Equatable {
        case setup
        case running(fraction: Double, bytes: Int64)
        case done(url: URL, summary: String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .setup:
                    setupForm
                case .running(let f, let bytes):
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: f)
                            Text("\(Int(f * 100))%・\(Self.mb(bytes))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("切到其他 App 時，下載約可再繼續 30 秒；較長的下載請保持 App 在前景。")
                    }
                case .done(let url, let summary):
                    Section {
                        Label(summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Section {
                        Button { Task { await saveToPhotos(url) } } label: {
                            Label("儲存到照片", systemImage: "photo.on.rectangle")
                        }
                        ShareLink(item: url) { Label("分享或存到檔案", systemImage: "square.and.arrow.up") }
                    } footer: {
                        if let saveMessage { Text(saveMessage) }
                    }
                case .failed(let e):
                    Section {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Button("重新設定") { phase = .setup }
                    }
                }
            }
            .navigationTitle("下載錄影")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isRunning ? "取消下載" : "關閉", role: .cancel) {
                        task?.cancel()
                        dismiss()
                    }
                }
                if phase == .setup {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("開始下載") { begin() }
                    }
                }
            }
            .interactiveDismissDisabled(isRunning)
        }
        .onAppear {
            start = initialStart
            highQuality = mainStream
        }
        .onDisappear {
            task?.cancel()
            if case .done(let url, _) = phase { try? FileManager.default.removeItem(at: url) }
        }
    }

    private var isRunning: Bool { if case .running = phase { return true } else { return false } }

    @ViewBuilder private var setupForm: some View {
        Section {
            LabeledContent("攝影機", value: device.displayName(channelID))
            DatePicker("開始時間", selection: $start, displayedComponents: [.date, .hourAndMinute])
            Picker("長度", selection: $seconds) {
                ForEach(lengths, id: \.self) { Text(Self.lengthText($0)).tag($0) }
            }
        } footer: {
            Text("\(start, format: .dateTime.hour().minute().second()) – \(start.addingTimeInterval(TimeInterval(seconds)), format: .dateTime.hour().minute().second())")
        }
        Section {
            Picker("畫質", selection: $highQuality) {
                Text("流暢（檔案較小）").tag(false)
                Text("高畫質").tag(true)
            }
            Toggle("包含聲音", isOn: $includeAudio)
        } footer: {
            Text("直接儲存 DVR 原始影像，不重新壓縮；沒有錄影的空檔會自動略過。")
        }
    }

    private func begin() {
        let name = device.displayName(channelID).replacingOccurrences(of: "/", with: "-")
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        let dir = FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(name)_\(f.string(from: start)).mp4")
        // 用獨立連線下載：切到背景時 App 會中斷設備的主要連線，不影響這裡
        let cfg = device.config
        let id = device.id
        let conn = DVRConnection(host: cfg.host, port: cfg.port, username: cfg.username,
                                 servicePort: cfg.servicePort ?? 6036) { try KeychainStore.password(for: id) }
        let (s, e, hq, audio, ch) = (start, start.addingTimeInterval(TimeInterval(seconds)), highQuality, includeAudio, channelID)
        phase = .running(fraction: 0, bytes: 0)
        task = Task { @MainActor in
            // 向 iOS 申請背景執行時間（通常約 30 秒），短暫切到其他 App 時下載不中斷
            var bg = UIBackgroundTaskIdentifier.invalid
            bg = UIApplication.shared.beginBackgroundTask(withName: "DVRExport") {
                UIApplication.shared.endBackgroundTask(bg)
                bg = .invalid
            }
            defer {
                if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
                Task { await conn.disconnect() }
            }
            do {
                _ = try await conn.connect()
                let r = try await RecordingExporter.export(
                    connection: conn, channelId: ch, start: s, end: e,
                    mainStream: hq, includeAudio: audio, to: url) { [gate = UpdateGate(interval: 0.25)] p in
                    guard gate.pass() else { return }
                    Task { @MainActor in
                        if case .running = phase { phase = .running(fraction: p.fraction, bytes: p.bytes) }
                    }
                }
                let secs = Int(r.lastFrameTime.timeIntervalSince(r.firstFrameTime))
                var text = "\(Self.mb(r.bytes))，\(r.width)×\(r.height)，約 \(secs / 60) 分 \(secs % 60) 秒"
                text += r.audioFrames > 0 ? "，含聲音" : (audio ? "，此段無聲音" : "")
                phase = .done(url: url, summary: text)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                if Task.isCancelled { return }
                if let x = error as? RecordingExporter.ExportError {
                    phase = .failed(x.description)
                } else {
                    phase = .failed(DeviceModel.describe(error))
                }
            }
        }
    }

    private func saveToPhotos(_ url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveMessage = "沒有「照片」的加入權限，請到「設定 → DVR Viewer → 照片」開啟。"
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            saveMessage = "已儲存到「照片」。"
        } catch {
            saveMessage = "儲存失敗：\(error.localizedDescription)"
        }
    }

    private static func lengthText(_ s: Int) -> String { s < 60 ? "\(s) 秒" : "\(s / 60) 分鐘" }
    private static func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1e6) }
}
