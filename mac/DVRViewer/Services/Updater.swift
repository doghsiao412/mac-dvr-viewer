import Combine
import Sparkle
import SwiftUI

/// Sparkle 自動更新（appcast 位於 GitHub Releases；更新檔以 EdDSA 簽章）
///
/// 使用 Sparkle 內建的標準更新介面（`SPUStandardUpdaterController`）。
/// 開啟 App 時與每天在背景檢查；發現新版時不直接跳出視窗，而是用 Sparkle 的「溫和提醒」
/// 在側邊欄左下角顯示提示，點一下才打開標準更新視窗。
@MainActor
final class UpdaterModel: NSObject, ObservableObject {
    private var controller: SPUStandardUpdaterController!
    var updater: SPUUpdater { controller.updater }
    @Published var canCheckForUpdates = false
    @Published var automaticallyChecks = false {
        didSet { if updater.automaticallyChecksForUpdates != automaticallyChecks { updater.automaticallyChecksForUpdates = automaticallyChecks } }
    }
    /// 背景檢查發現的新版本（左下角提示用）；nil 表示沒有
    @Published private(set) var availableVersion: String?
    private var cancellable: AnyCancellable?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
        checkOnLaunch()
    }

    /// 開啟 App 時在背景檢查一次（Sparkle 預設只依每天的間隔檢查）；設定關閉「自動檢查更新」則不檢查
    private func checkOnLaunch() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))   // 等 App 啟動完成
            guard let self, self.updater.automaticallyChecksForUpdates, self.updater.canCheckForUpdates else { return }
            self.updater.checkForUpdatesInBackground()
        }
    }

    /// 選單「檢查更新…」或點左下角提示：打開 Sparkle 標準更新視窗
    func checkForUpdates() { controller.checkForUpdates(nil) }

    var lastCheck: Date? { updater.lastUpdateCheckDate }
}

// MARK: - 溫和提醒（背景檢查發現新版時，由 App 自己顯示提示）

extension UpdaterModel: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 背景檢查發現新版：不讓 Sparkle 直接跳出視窗，改顯示左下角提示
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate {
            availableVersion = update.displayVersionString
            #if DEBUG
            print("[更新提示] 發現新版 \(update.displayVersionString)，顯示左下角提示")
            #endif
        }
    }

    /// 使用者已看到更新視窗：收起提示
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}

/// 選單「檢查更新…」
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        Button("檢查更新…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// 側邊欄左下角的新版提示：點一下打開更新視窗
struct UpdateAvailableBanner: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        if let v = updater.availableVersion {
            Button { updater.checkForUpdates() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("有新版本 \(v)").font(.callout.weight(.semibold))
                        Text("點這裡查看並更新").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .padding(10)
            .help("DVR Viewer \(v) 已推出")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
