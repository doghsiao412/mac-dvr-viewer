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
                    // 回到前景時，啟動尚未連線的設備（已在連線中的不受影響）
                    if phase == .active { store.startAll() }
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
        devices = DevicePersistence.load().map(DeviceModel.init)
    }

    func startAll() { devices.forEach { $0.start() } }

    func add(_ config: DeviceConfig, password: String) throws {
        try KeychainStore.setPassword(password, for: config.id)
        let m = DeviceModel(config: config)
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

    private func persist() {
        DevicePersistence.save(devices.map(\.config))
    }
}
