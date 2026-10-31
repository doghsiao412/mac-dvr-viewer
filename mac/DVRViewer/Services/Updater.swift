import Combine
import Sparkle
import SwiftUI

/// Sparkle 自動更新（appcast 位於 GitHub repo 的 appcast.xml；更新檔以 EdDSA 簽章）
///
/// 更新視窗由 `DVRUserDriver` 自己顯示，找到新版時三個選項：
/// 「安裝並重新啟動」「關閉後自動安裝」「暫不更新」（略過此版本，不下載）。
@MainActor
final class UpdaterModel: ObservableObject {
    let updater: SPUUpdater
    private let driver = DVRUserDriver()
    @Published var canCheckForUpdates = false
    @Published var automaticallyChecks: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    private var cancellable: AnyCancellable?

    init() {
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do { try updater.start() } catch { NSLog("Sparkle 啟動失敗：\(error)") }
        // 不在背景自動下載：先讓使用者選擇，選「暫不更新」就完全不下載、不安裝
        updater.automaticallyDownloadsUpdates = false
        automaticallyChecks = updater.automaticallyChecksForUpdates
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
        checkOnLaunch()
    }

    /// 每次開啟 App 都在背景檢查一次（Sparkle 預設只依間隔檢查）；
    /// 只有發現新版本才會跳出視窗。設定頁關閉「自動檢查更新」則不檢查。
    private func checkOnLaunch() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            DVRUserDriver.showUpdatedNoticeIfNeeded()
            try? await Task.sleep(for: .seconds(1.5))  // 等 App 啟動完成
            guard let self, self.updater.automaticallyChecksForUpdates, self.updater.canCheckForUpdates else { return }
            self.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() { updater.checkForUpdates() }

    var lastCheck: Date? { updater.lastUpdateCheckDate }
}

/// 選單「檢查更新…」
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        Button("檢查更新…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// 自訂的 Sparkle 更新介面
final class DVRUserDriver: NSObject, SPUUserDriver {
    static let pendingKey = "pendingUpdateNotice"

    private enum Mode { case relaunch, onQuit }
    private var mode: Mode = .relaunch
    /// 使用者從選單按「檢查更新…」（沒有新版或出錯時才需要告知）
    private var userInitiated = false

    // MARK: 找到新版

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        userInitiated = false
        let version = appcastItem.displayVersionString
        let history = appcastItem.itemDescription ?? ""
        let title = "DVR Viewer \(version) 有新版本"
        let subtitle = "目前版本 \(Self.currentVersion)。以下是各版本的更新內容："
        if appcastItem.isInformationOnlyUpdate {
            DispatchQueue.main.async {
                _ = UpdateWindow.run(title: title, subtitle: subtitle, history: history, buttons: ["好"])
                reply(.dismiss)
            }
            return
        }
        DispatchQueue.main.async {
            let choice = UpdateWindow.run(title: title, subtitle: subtitle, history: history,
                                          buttons: ["安裝並重新啟動", "關閉後自動安裝", "暫不更新"])
            switch choice {
            case 0:
                self.mode = .relaunch
                UserDefaults.standard.removeObject(forKey: Self.pendingKey)
                reply(.install)
            case 1:
                self.mode = .onQuit
                UserDefaults.standard.set(["version": version, "notes": history], forKey: Self.pendingKey)
                reply(.install)
            default:
                // 略過此版本：不下載、不安裝，之後也不再自動提示（手動「檢查更新…」仍會看到）
                UserDefaults.standard.removeObject(forKey: Self.pendingKey)
                reply(.skip)
            }
        }
    }

    /// 下載完成：依剛才的選擇立即安裝，或等關閉 App 時安裝
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(mode == .relaunch ? .install : .dismiss)
    }

    // MARK: 手動檢查的結果

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard userInitiated else { acknowledgement(); return }
        userInitiated = false
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "DVR Viewer \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") 是目前最新的版本。"
        alert.addButton(withTitle: "好")
        present(alert) { _ in acknowledgement() }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard userInitiated else { acknowledgement(); return }
        userInitiated = false
        let alert = NSAlert()
        alert.messageText = "無法檢查更新"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        present(alert) { _ in acknowledgement() }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: 進度（不顯示）

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { userInitiated = false }
    func showUpdateInFocus() { NSApp.activate() }

    // MARK: 工具

    private func present(_ alert: NSAlert, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        DispatchQueue.main.async {
            NSApp.activate()
            done(alert.runModal())
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// 從 appcast 的完整更新歷史（Markdown，「vX.Y」為段落標題）取出指定版本的內容
    static func notes(for version: String, in text: String) -> String {
        var out: [String] = []
        var on = false
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.range(of: #"^v\d+(\.\d+)*$"#, options: .regularExpression) != nil {
                if on { break }
                on = (t == "v\(version)")
                continue
            }
            if on, !t.isEmpty { out.append(t) }
        }
        return out.joined(separator: "\n")
    }

    /// App 啟動時：若上次選了「關閉後自動安裝」且已更新到該版本，提示已更新與更新內容
    @MainActor
    static func showUpdatedNoticeIfNeeded() {
        guard let p = UserDefaults.standard.dictionary(forKey: pendingKey),
              let version = p["version"] as? String else { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard current == version else { return }   // 尚未安裝（例如被強制結束）：下次再提示
        UserDefaults.standard.removeObject(forKey: pendingKey)
        let notes = p["notes"] as? String ?? ""
        _ = UpdateWindow.run(title: "已更新到 DVR Viewer \(version)",
                             subtitle: notes.isEmpty ? "更新已完成。" : "以下是各版本的更新內容：",
                             history: notes, buttons: ["好"])
    }
}

/// 更新視窗：一般視窗＋白底的更新內容（不放在系統提示框裡：大量文字配玻璃效果會很卡）
enum UpdateWindow {
    /// 顯示並等待選擇，回傳按下的按鈕索引（buttons[0] 為預設按鈕）
    @MainActor
    static func run(title: String, subtitle: String, history: String, buttons: [String]) -> Int {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "DVR Viewer 更新"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: UpdateWindowView(
            title: title, subtitle: subtitle, history: history, buttons: buttons,
            onChoose: { i in NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: i)) }))
        window.center()
        NSApp.activate()
        let r = NSApp.runModal(for: window)
        window.orderOut(nil)
        return r.rawValue
    }
}

private struct UpdateWindowView: View {
    let title: String
    let subtitle: String
    let history: String
    let buttons: [String]
    let onChoose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
            if !history.isEmpty {
                ScrollView {
                    Text(Self.attributed(history))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.35)))
                .environment(\.colorScheme, .light)   // 白底深色字（深色模式也一樣）
            }
            HStack {
                if buttons.count > 2 {
                    Button(buttons[2]) { onChoose(2) }
                }
                Spacer()
                if buttons.count > 1 {
                    Button(buttons[1]) { onChoose(1) }
                }
                Button(buttons[0]) { onChoose(0) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 560, height: history.isEmpty ? 160 : 500)
    }

    /// 「vX.Y」為版本標題（粗體），「- 」開頭為項目
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        var first = true
        for raw in text.components(separatedBy: .newlines) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if t.range(of: #"^v\d+(\.\d+)*$"#, options: .regularExpression) != nil {
                var h = AttributedString((first ? "" : "\n") + t + "\n")
                h.font = .system(size: 14, weight: .bold)
                h.foregroundColor = .black
                out += h
                first = false
            } else {
                var l = AttributedString((t.hasPrefix("- ") ? "•  " + t.dropFirst(2) : Substring(t)) + "\n")
                l.font = .system(size: 13)
                l.foregroundColor = Color(white: 0.25)
                out += l
            }
        }
        return out
    }
}
