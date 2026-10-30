import DVRKit
import Foundation
import Observation

/// 一台 DVR 的執行期狀態：連線、頻道、在線狀態、自動重連與 Session 保活。
@Observable
@MainActor
final class DeviceModel: Identifiable {
    enum Status: Equatable {
        case disconnected
        case connecting
        case online
        case error(String)

        var text: String {
            switch self {
            case .disconnected: return "未連線"
            case .connecting: return "連線中…"
            case .online: return "已連線"
            case .error(let e): return e
            }
        }
    }

    var config: DeviceConfig
    private(set) var connection: DVRConnection
    private(set) var status: Status = .disconnected
    private(set) var channels: [DVRChannel] = []
    private(set) var online: Set<String> = []
    private(set) var info: DVRConnection.DeviceInfo?
    private var loop: Task<Void, Never>?

    nonisolated var id: UUID { _id }
    private nonisolated let _id: UUID

    init(config: DeviceConfig) {
        self.config = config
        self._id = config.id
        self.connection = Self.makeConnection(config)
    }

    static func makeConnection(_ c: DeviceConfig) -> DVRConnection {
        let id = c.id
        return DVRConnection(host: c.host, port: c.port, username: c.username) {
            try KeychainStore.password(for: id)
        }
    }

    /// 設定變更（主機／帳號）後重建連線
    func apply(_ newConfig: DeviceConfig) {
        let needsReconnect = newConfig.host != config.host || newConfig.port != config.port
            || newConfig.username != config.username
        config = newConfig
        if needsReconnect { reconnect() }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        let c = connection
        Task { await c.disconnect() }
        status = .disconnected
    }

    func reconnect() {
        loop?.cancel()
        loop = nil
        let old = connection
        Task { await old.disconnect() }
        connection = Self.makeConnection(config)
        start()
    }

    private func run() async {
        var retry: Double = 5
        while !Task.isCancelled {
            status = .connecting
            do {
                let conn = connection
                channels = try await conn.connect()
                info = await conn.info
                online = (try? await conn.onlineChannelIds()) ?? Set(channels.map(\.id))
                status = .online
                retry = 5
                // 保活與在線狀態：每 30 秒
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(30))
                    online = try await conn.onlineChannelIds()
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                status = .error(Self.describe(error))
                try? await Task.sleep(for: .seconds(retry))
                retry = min(retry * 2, 60)
            }
        }
    }

    static func describe(_ e: Error) -> String {
        if let n = e as? NVMSError { return n.description }
        if let k = e as? KeychainStore.KeychainError { return k.localizedDescription }
        return e.localizedDescription
    }

    // MARK: - 頻道顯示

    var orderedChannels: [DVRChannel] {
        let order = config.channelOrder
        guard !order.isEmpty else { return channels }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return channels.sorted { (rank[$0.id] ?? Int.max, $0.index) < (rank[$1.id] ?? Int.max, $1.index) }
    }

    func displayName(_ channelID: String) -> String {
        if let a = config.channelAliases[channelID], !a.isEmpty { return a }
        return channels.first { $0.id == channelID }?.name ?? "頻道"
    }

    func isOnline(_ channelID: String) -> Bool { online.contains(channelID) }
}
