import AppKit
import DVRKit
import Foundation
import Observation

/// 錄影下載工作管理：背景執行、進度、取消、完成後在 Finder 顯示。
/// 關閉下載視窗不會中斷下載。
@Observable
@MainActor
final class ExportManager {
    @Observable
    @MainActor
    final class Job: Identifiable {
        enum State: Equatable {
            case running
            case done(String)
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let title: String
        let url: URL
        let start: Date
        let end: Date
        var fraction: Double = 0
        var mediaTime: Date?
        var bytes: Int64 = 0
        var state: State = .running
        fileprivate var task: Task<Void, Never>?

        init(title: String, url: URL, start: Date, end: Date) {
            self.title = title
            self.url = url
            self.start = start
            self.end = end
        }

        var isRunning: Bool { state == .running }
    }

    private(set) var jobs: [Job] = []

    var runningCount: Int { jobs.filter(\.isRunning).count }

    /// 整體進度（所有進行中的工作平均）
    var overallFraction: Double {
        let r = jobs.filter(\.isRunning)
        guard !r.isEmpty else { return 1 }
        return r.map(\.fraction).reduce(0, +) / Double(r.count)
    }

    /// 預設存到「下載項目」
    static var defaultFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static func suggestedName(device: String, channel: String, start: Date, end: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let mins = max(Int((end.timeIntervalSince(start) / 60).rounded()), 1)
        let safe = { (s: String) in s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }
        return "\(safe(device))-\(safe(channel))-\(f.string(from: start))-\(mins)分.mp4"
    }

    @discardableResult
    func start(connection: DVRConnection, channelID: String, title: String, start: Date, end: Date,
               mainStream: Bool, includeAudio: Bool = true, to url: URL, onFinish: @escaping @MainActor (Job) -> Void) -> Job {
        let job = Job(title: title, url: url, start: start, end: end)
        jobs.insert(job, at: 0)
        job.task = Task { @MainActor in
            do {
                let r = try await RecordingExporter.export(
                    connection: connection, channelId: channelID, start: start, end: end,
                    mainStream: mainStream, includeAudio: includeAudio, to: url) { [gate = UpdateGate(interval: 0.25)] p in
                    // 下載比即時快很多（每秒數百幀）：進度每秒更新 4 次即可，避免主執行緒忙碌造成動畫掉幀
                    guard gate.pass() else { return }
                    Task { @MainActor in
                        guard job.isRunning else { return }
                        job.fraction = p.fraction
                        job.mediaTime = p.mediaTime
                        job.bytes = p.bytes
                    }
                }
                job.fraction = 1
                job.bytes = r.bytes
                let secs = Int(r.lastFrameTime.timeIntervalSince(r.firstFrameTime))
                var text = String(format: "%.1f MB，%d×%d，錄影約 %d 分 %d 秒", Double(r.bytes) / 1e6, r.width, r.height, secs / 60, secs % 60)
                text += r.audioFrames > 0 ? "，含聲音" : (includeAudio ? "，此段無聲音" : "")
                if r.gapsRemoved > 0 { text += "（已略過 \(r.gapsRemoved) 段無錄影空檔）" }
                job.state = .done(text)
                onFinish(job)
            } catch is CancellationError {
                job.state = .cancelled
            } catch {
                guard job.isRunning else { return }  // 已被使用者取消
                job.state = .failed(Self.describe(error))
                onFinish(job)
            }
        }
        return job
    }

    func cancel(_ job: Job) {
        job.task?.cancel()
        job.state = .cancelled
    }

    func reveal(_ job: Job) {
        NSWorkspace.shared.activateFileViewerSelecting([job.url])
    }

    func open(_ job: Job) {
        NSWorkspace.shared.open(job.url)
    }

    func clearFinished() {
        jobs.removeAll { !$0.isRunning }
    }

    static func describe(_ e: Error) -> String {
        if let x = e as? RecordingExporter.ExportError { return x.description }
        return DeviceModel.describe(e)
    }
}
