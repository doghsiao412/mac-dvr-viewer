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
    /// nil = 未知；false = 韌體不支援 WebSocket 影像串流
    private(set) var webStreaming: Bool?
    /// 這台裝置的鑰匙圈沒有此 DVR 的密碼（例如從其他 Mac 同步過來）
    private(set) var needsPassword = false
    private var loop: Task<Void, Never>?
    /// 自動帶入 DVR 設定的影像服務 Port 後呼叫（由 Store 存檔／同步）
    var onConfigChanged: (() -> Void)?

    nonisolated var id: UUID { _id }
    private nonisolated let _id: UUID

    init(config: DeviceConfig) {
        self.config = config
        self._id = config.id
        self.connection = Self.makeConnection(config)
    }

    static func makeConnection(_ c: DeviceConfig) -> DVRConnection {
        let id = c.id
        // 未自訂影像服務 Port 時，登入後改用 DVR 自己設定的 Port
        return DVRConnection(host: c.host, port: c.port, username: c.username, servicePort: c.servicePort ?? 6036,
                             autoDetectServicePort: c.servicePort == nil) {
            try KeychainStore.password(for: id)
        }
    }

    /// 設定變更（主機／帳號）後重建連線
    func apply(_ newConfig: DeviceConfig) {
        let needsReconnect = newConfig.host != config.host || newConfig.port != config.port
            || newConfig.username != config.username || newConfig.servicePort != config.servicePort
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
                await adoptDetectedServicePort(conn)
                // 已知的韌體類型不覆蓋成未知（避免所有畫面停下來）
                if let w = await conn.supportsWebStreaming { webStreaming = w }
                online = (try? await conn.onlineChannelIds()) ?? Set(channels.map(\.id))
                status = .online
                needsPassword = false
                retry = 5
                // 保活與在線狀態：每 30 秒；韌體類型仍未知時每 5 秒再偵測
                while !Task.isCancelled {
                    if webStreaming == nil {
                        try await Task.sleep(for: .seconds(5))
                        if let w = await conn.reprobeWebStreamingIfNeeded() { webStreaming = w }
                        continue
                    }
                    try await Task.sleep(for: .seconds(30))
                    online = try await conn.onlineChannelIds()
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                if let k = error as? KeychainStore.KeychainError, case .notFound = k { needsPassword = true }
                status = .error(Self.describe(error))
                try? await Task.sleep(for: .seconds(retry))
                retry = min(retry * 2, 60)
            }
        }
    }

    /// 未自訂影像服務 Port 時，把 DVR 設定的 Port 存回設定（連線本身已在登入時改用）
    private func adoptDetectedServicePort(_ conn: DVRConnection) async {
        guard config.servicePort == nil, let d = await conn.detectedServicePort, d != 6036, conn === connection else { return }
        config.servicePort = d
        onConfigChanged?()
    }

    static func describe(_ e: Error) -> String {
        if let n = e as? NVMSError { return n.description }
        if let k = e as? KeychainStore.KeychainError {
            if case .notFound = k {
                #if os(macOS)
                return "這台 Mac 尚未輸入密碼"
                #else
                return "這台 iPhone 尚未輸入密碼"
                #endif
            }
            return k.localizedDescription
        }
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

    /// 影像傳輸方式（顯示用）
    var transportText: String {
        switch webStreaming {
        case true: return "影像：WebSocket（Port \(config.port)）"
        case false: return "影像：TVT 私有協定（Port \(config.servicePort ?? 6036)）"
        default: return "影像：偵測中"
        }
    }
}
