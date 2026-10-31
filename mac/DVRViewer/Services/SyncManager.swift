import AppKit
import Foundation
import Observation

/// 透過同步資料夾（iCloud 雲碟、Google 雲端硬碟、Dropbox…）在多台 Mac 之間同步設定。
///
/// 同步內容：DVR 清單（名稱、位址、Port、帳號、頻道名稱與順序、DVR 順序）與自訂畫面。
/// **不同步密碼**：密碼只在各台 Mac 的鑰匙圈，另一台第一次連線時需輸入一次。
/// 衝突處理：以最後寫入的為準。
@Observable
@MainActor
final class SyncManager {
    static let fileName = "DVR Viewer 設定.json"

    struct SyncFile: Codable {
        var format = 1
        var modifiedAt: Date
        var writer: String
        var devices: [DeviceConfig]
        var customViews: [AppStore.CustomView]
    }

    private(set) var folder: URL? = UserDefaults.standard.string(forKey: "syncFolderPath").map { URL(fileURLWithPath: $0) }
    private(set) var lastSync: Date?
    private(set) var lastError: String?

    var fileURL: URL? { folder?.appending(path: Self.fileName) }

    private weak var store: AppStore?
    private var applying = false
    private var writeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastWrittenContent: Data?

    /// 這台 Mac 的識別碼（判斷同步檔是不是自己寫的）
    private let machineID: String = {
        if let s = UserDefaults.standard.string(forKey: "syncMachineID") { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: "syncMachineID")
        return s
    }()

    /// 已套用（或自己寫入）的同步檔時間
    private var lastApplied: Date? {
        get { UserDefaults.standard.object(forKey: "syncLastApplied") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "syncLastApplied") }
    }

    func attach(_ store: AppStore) {
        self.store = store
        startPolling()
    }

    // MARK: - 開始／停止

    /// 預設建議的資料夾：iCloud 雲碟
    static var suggestedFolder: URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// 選擇資料夾；資料夾已有同步檔時詢問要用哪一邊的設定
    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "使用此資料夾"
        p.message = "選擇用來同步設定的資料夾（例如 iCloud 雲碟或 Google 雲端硬碟中的資料夾）。其他 Mac 選同一個資料夾即可同步。"
        p.directoryURL = folder ?? Self.suggestedFolder
        guard p.runModal() == .OK, let url = p.url else { return }

        let file = url.appending(path: Self.fileName)
        var useRemote = false
        if let remote = Self.read(file) {
            let alert = NSAlert()
            alert.messageText = "這個資料夾已有同步的設定"
            alert.informativeText = "裡面有 \(remote.devices.count) 台 DVR、\(remote.customViews.count) 個自訂畫面（\(remote.modifiedAt.formatted(date: .abbreviated, time: .shortened)) 更新）。要使用哪一邊的設定？"
            alert.addButton(withTitle: "使用同步資料夾的設定")
            alert.addButton(withTitle: "以這台 Mac 的設定覆蓋")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn: useRemote = true
            case .alertSecondButtonReturn: useRemote = false
            default: return
            }
        }
        folder = url
        UserDefaults.standard.set(url.path, forKey: "syncFolderPath")
        lastApplied = nil
        lastWrittenContent = nil
        lastError = nil
        if useRemote, let remote = Self.read(file) {
            apply(remote)
        } else {
            write(force: true)
        }
    }

    func stopSync() {
        folder = nil
        UserDefaults.standard.removeObject(forKey: "syncFolderPath")
        lastApplied = nil
        lastSync = nil
        lastError = nil
    }

    // MARK: - 寫入

    /// 本機設定變更：1 秒後寫入同步檔（連續變更只寫一次）
    func localChanged() {
        guard folder != nil, !applying else { return }
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.write(force: false)
        }
    }

    func syncNow() {
        checkRemote()
        write(force: false)
    }

    private func write(force: Bool) {
        guard let store, let file = fileURL else { return }
        let content = try? JSONEncoder().encode(Content(devices: store.devices.map(\.config), customViews: store.customViews))
        if !force, content != nil, content == lastWrittenContent { return }   // 沒有變更
        let now = Date()
        let f = SyncFile(modifiedAt: now, writer: machineID, devices: store.devices.map(\.config), customViews: store.customViews)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            let data = try enc.encode(f)
            var coordError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordError) { u in
                do { try data.write(to: u, options: .atomic) } catch { writeError = error }
            }
            if let e = coordError ?? writeError { throw e }
            lastWrittenContent = content
            lastApplied = now
            lastSync = now
            lastError = nil
        } catch {
            lastError = "無法寫入同步檔：\(error.localizedDescription)"
        }
    }

    private struct Content: Encodable {
        let devices: [DeviceConfig]
        let customViews: [AppStore.CustomView]
    }

    // MARK: - 讀取與套用

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                self?.checkRemote()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// 其他 Mac 寫入了較新的同步檔 → 套用
    private func checkRemote() {
        guard let file = fileURL, !applying else { return }
        guard let remote = Self.read(file) else { return }
        if remote.modifiedAt > (lastApplied ?? .distantPast), remote.writer != machineID {
            apply(remote)
        }
    }

    private func apply(_ remote: SyncFile) {
        guard let store else { return }
        applying = true
        store.applySynced(devices: remote.devices, customViews: remote.customViews)
        applying = false
        lastApplied = remote.modifiedAt
        lastWrittenContent = try? JSONEncoder().encode(Content(devices: store.devices.map(\.config), customViews: store.customViews))
        lastSync = Date()
        lastError = nil
    }

    /// 以檔案協調讀取（iCloud 雲碟中尚未下載的檔案會先下載）
    nonisolated static func read(_ file: URL) -> SyncFile? {
        var data: Data?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &err) { u in
            data = try? Data(contentsOf: u)
        }
        guard let data else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SyncFile.self, from: data)
    }
}
