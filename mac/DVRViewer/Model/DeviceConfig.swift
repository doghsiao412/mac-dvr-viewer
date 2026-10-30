import Foundation

/// 已儲存的 DVR 設定（不含密碼；密碼在 Keychain）
struct DeviceConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int
    var username: String
    /// 頻道 ID → 自訂名稱
    var channelAliases: [String: String] = [:]
    /// 自訂頻道順序（頻道 ID）；未列出的頻道排在後面
    var channelOrder: [String] = []
}

/// 指向某台設備的某個頻道
struct CameraRef: Codable, Hashable {
    var deviceID: UUID
    var channelID: String

    /// 拖放用的字串表示
    var token: String { "dvrcam:\(deviceID.uuidString)|\(channelID)" }

    init(deviceID: UUID, channelID: String) {
        self.deviceID = deviceID
        self.channelID = channelID
    }

    init?(token: String) {
        guard token.hasPrefix("dvrcam:") else { return nil }
        let parts = token.dropFirst(7).split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { return nil }
        self.init(deviceID: id, channelID: parts[1])
    }
}

enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case live, playback
    var id: String { rawValue }
    var title: String { self == .live ? "即時影像" : "錄影回放" }
    var symbol: String { self == .live ? "video" : "clock.arrow.circlepath" }
}

enum VideoAspect: String, Codable, CaseIterable, Identifiable {
    case fit, fill, stretch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: return "符合畫面"
        case .fill: return "填滿畫面"
        case .stretch: return "延展"
        }
    }
}

/// 設定檔儲存位置：~/Library/Application Support/DVR Viewer/devices.json
enum DevicePersistence {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DVR Viewer", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "devices.json")
    }

    static func load() -> [DeviceConfig] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DeviceConfig].self, from: d)) ?? []
    }

    static func save(_ devices: [DeviceConfig]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(devices) { try? d.write(to: url, options: .atomic) }
    }
}
