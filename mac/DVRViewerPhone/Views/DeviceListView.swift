import DVRKit
import SwiftUI

/// 首頁：已加入的 DVR
struct DeviceListView: View {
    @Environment(PhoneStore.self) private var store
    @State private var editor: EditorTarget?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.devices) { device in
                    NavigationLink(value: device.id) {
                        DeviceRow(device: device)
                    }
                    .swipeActions {
                        Button("刪除", role: .destructive) { store.delete(device) }
                        Button("編輯") { editor = .edit(device.config) }.tint(.blue)
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .overlay {
                if store.devices.isEmpty {
                    ContentUnavailableView {
                        Label("尚未加入 DVR", systemImage: "video.badge.plus")
                    } description: {
                        Text("點右上角的「＋」輸入 DVR 的位址與帳號。")
                    } actions: {
                        Button("加入 DVR") { editor = .new }.buttonStyle(.glassProminent)
                    }
                }
            }
            .navigationTitle("DVR Viewer")
            .navigationDestination(for: UUID.self) { id in
                if let device = store.devices.first(where: { $0.id == id }) {
                    ChannelGridView(device: device)
                }
            }
            .navigationDestination(for: PhoneRoute.self) { route in
                switch route {
                case .live(let ref):
                    if let device = store.devices.first(where: { $0.id == ref.deviceID }) {
                        LiveView(device: device, channelID: ref.channelID)
                    }
                case .playback(let ref):
                    if let device = store.devices.first(where: { $0.id == ref.deviceID }) {
                        PlaybackView(device: device, channelID: ref.channelID)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("加入 DVR", systemImage: "plus") { editor = .new }
                }
                if !store.devices.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
            }
            .sheet(item: $editor) { target in
                DeviceEditorView(target: target)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: DeviceModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.config.name).font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText)
                        .lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if device.status == .online { return "已連線・\(device.channels.count) 個頻道" }
        return device.status.text
    }

    private var statusColor: Color {
        switch device.status {
        case .online: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }
}

enum EditorTarget: Identifiable {
    case new
    case edit(DeviceConfig)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let c): return c.id.uuidString
        }
    }
}
