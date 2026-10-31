import Combine
import Sparkle
import SwiftUI

/// Sparkle 自動更新（appcast 位於 GitHub repo 的 appcast.xml；更新檔以 EdDSA 簽章）
@MainActor
final class UpdaterModel: ObservableObject {
    let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false
    @Published var automaticallyChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    private var cancellable: AnyCancellable?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
        checkOnLaunch()
    }

    /// 每次開啟 App 都在背景檢查一次（Sparkle 預設只依間隔檢查）；
    /// 只有發現新版本才會跳出視窗。設定頁關閉「自動檢查更新」則不檢查。
    private func checkOnLaunch() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))  // 等 App 啟動完成
            guard let self, self.controller.updater.automaticallyChecksForUpdates,
                  self.controller.updater.canCheckForUpdates else { return }
            self.controller.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }
}

/// 選單「檢查更新…」
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        Button("檢查更新…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
