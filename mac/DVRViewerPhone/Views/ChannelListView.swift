import DVRKit
import SwiftUI

/// 一台 DVR 的頻道清單
struct ChannelListView: View {
    let device: DeviceModel

    var body: some View {
        List {
            Section {
                ForEach(device.orderedChannels, id: \.id) { ch in
                    NavigationLink {
                        LiveView(device: device, channelID: ch.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: device.isOnline(ch.id) ? "video.fill" : "video.slash")
                                .foregroundStyle(device.isOnline(ch.id) ? Color.accentColor : .secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName(ch.id))
                                Text(device.isOnline(ch.id) ? "頻道 \(ch.index + 1)" : "頻道 \(ch.index + 1)・離線")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!device.isOnline(ch.id))
                }
            } footer: {
                if device.status == .online { Text(device.transportText) }
            }
        }
        .overlay {
            if device.channels.isEmpty {
                switch device.status {
                case .online:
                    ContentUnavailableView("沒有頻道", systemImage: "video.slash")
                case .error(let e):
                    ContentUnavailableView {
                        Label("無法連線", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(e)
                    } actions: {
                        Button("重新連線") { device.reconnect() }
                    }
                default:
                    ProgressView("連線中…")
                }
            }
        }
        .navigationTitle(device.config.name)
        .refreshable { device.reconnect() }
    }
}
