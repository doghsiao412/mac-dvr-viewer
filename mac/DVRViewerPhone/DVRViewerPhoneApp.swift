import DVRKit
import Observation
import SwiftUI

@main
struct DVRViewerPhoneApp: App {
    @State private var store = PhoneStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DeviceListView()
                .environment(store)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: store.resumeAll()
                    case .background: store.suspendAll()
                    default: break   // .inactive（控制中心、來電橫幅）不中斷
                    }
                }
        }
    }
}

/// iPhone 版的設備清單：設定存在 App 的 Application Support，密碼存在 iPhone 鑰匙圈。
@Observable
@MainActor
final class PhoneStore {
    private(set) var devices: [DeviceModel] = []

    init() {
        devices = DevicePersistence.load().map { makeModel($0) }
    }

    /// 切到背景時 iOS 會暫停 App、網路連線隨之失效：主動斷線，回到前景再重新登入
    private var suspended = false

    func suspendAll() {
        guard !suspended else { return }
        suspended = true
        devices.forEach { $0.stop() }
    }

    /// 回到前景（或第一次啟動）：背景回來的設備重建連線，其餘啟動尚未連線的設備。
    /// 重建連線後 `DeviceModel.connection` 會換新，畫面以它為鍵的串流會自動重新開始。
    func resumeAll() {
        if suspended {
            suspended = false
            devices.forEach { $0.reconnect() }
        } else {
            devices.forEach { $0.start() }
        }
    }

    func add(_ config: DeviceConfig, password: String) throws {
        try KeychainStore.setPassword(password, for: config.id)
        let m = makeModel(config)
        devices.append(m)
        persist()
        m.start()
    }

    func update(_ config: DeviceConfig, password: String?) throws {
        guard let m = devices.first(where: { $0.id == config.id }) else { return }
        if let password, !password.isEmpty {
            try KeychainStore.setPassword(password, for: config.id)
            m.apply(config)
            m.reconnect()
        } else {
            m.apply(config)
        }
        persist()
    }

    func delete(_ m: DeviceModel) {
        m.stop()
        devices.removeAll { $0.id == m.id }
        let id = m.id
        Task.detached { KeychainStore.deletePassword(for: id) }
        persist()
    }

    func move(from: IndexSet, to: Int) {
        devices.move(fromOffsets: from, toOffset: to)
        persist()
    }

    /// 建立設備模型並接上自動帶入設定的存檔
    private func makeModel(_ c: DeviceConfig) -> DeviceModel {
        let m = DeviceModel(config: c)
        m.onConfigChanged = { [weak self] in self?.persist() }
        return m
    }

    private func persist() {
        DevicePersistence.save(devices.map(\.config))
    }
}
