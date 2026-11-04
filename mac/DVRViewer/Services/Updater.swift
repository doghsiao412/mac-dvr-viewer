import Combine
import Sparkle
import SwiftUI

/// Sparkle 自動更新（appcast 位於 GitHub Releases；更新檔以 EdDSA 簽章）
///
/// 使用 Sparkle 內建的標準更新介面（`SPUStandardUpdaterController`）：
/// 檢查時機、更新視窗、更新內容顯示與「略過此版本／稍後提醒」都依 Sparkle 預設行為。
@MainActor
final class UpdaterModel: ObservableObject {
    private let controller: SPUStandardUpdaterController
    var updater: SPUUpdater { controller.updater }
    @Published var canCheckForUpdates = false
    @Published var automaticallyChecks: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    private var cancellable: AnyCancellable?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

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
