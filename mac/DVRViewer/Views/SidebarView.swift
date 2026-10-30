import DVRKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Binding var editor: DeviceEditorTarget?
    @State private var renaming: CameraRef?
    @State private var renameText = ""
    @State private var removing: DeviceModel?

    var body: some View {
        List {
            ForEach(store.devices) { dev in
                Section(isExpanded: Binding(get: { store.isExpanded(dev.id) },
                                            set: { store.setExpanded(dev.id, $0) })) {
                    if dev.channels.isEmpty {
                        Text(dev.status == .online ? "沒有頻道" : dev.status.text)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(dev.orderedChannels) { ch in
                        channelRow(dev: dev, ch: ch)
                    }
                } header: {
                    deviceHeader(dev)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button { editor = .new } label: { Label("加入 DVR", systemImage: "plus") }
                    .help("加入 DVR")
            }
        }
        .alert("重新命名頻道", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名稱", text: $renameText)
            Button("儲存") { if let r = renaming { store.rename(r, to: renameText) }; renaming = nil }
            Button("恢復預設名稱") { if let r = renaming { store.rename(r, to: "") }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("移除這台 DVR？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { dev in
            Button("移除「\(dev.config.name)」", role: .destructive) { store.remove(dev.id) }
        } message: { _ in
            Text("只會移除本 App 中的設定與 Keychain 密碼，不會影響 DVR 或錄影。")
        }
    }

    private func deviceHeader(_ dev: DeviceModel) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(dev.status))
                .frame(width: 8, height: 8)
            Text(dev.config.name).font(.headline)
            Spacer()
            if dev.status == .online {
                Text("\(dev.online.count)/\(dev.channels.count)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("在線頻道")
            }
        }
        .help(helpText(dev))
        .contextMenu {
            Button("編輯…") { editor = .edit(dev.config) }
            Button("重新連線") { dev.reconnect() }
            Divider()
            Button("全部收合") { store.setAllExpanded(false) }
            Button("全部展開") { store.setAllExpanded(true) }
            Divider()
            Button("全部放入即時畫面") {
                let chs = dev.orderedChannels
                let n = chs.count <= 1 ? 1 : chs.count <= 4 ? 4 : chs.count <= 9 ? 9 : 16
                store.setLayout(n)
                for (i, c) in chs.prefix(n).enumerated() { store.slots[i] = CameraRef(deviceID: dev.id, channelID: c.id) }
                store.mode = .live
            }
            Divider()
            Button("移除…", role: .destructive) { removing = dev }
        }
    }

    private func helpText(_ dev: DeviceModel) -> String {
        var s = "\(dev.config.host):\(dev.config.port) — \(dev.status.text)"
        if let i = dev.info { s += "\n\(i.model)  韌體 \(i.firmware)" }
        s += "\n" + dev.transportText
        return s
    }

    private func statusColor(_ s: DeviceModel.Status) -> Color {
        switch s {
        case .online: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    @ViewBuilder
    private func channelRow(dev: DeviceModel, ch: DVRChannel) -> some View {
        let ref = CameraRef(deviceID: dev.id, channelID: ch.id)
        let online = dev.isOnline(ch.id)
        let selected = store.mode == .playback ? store.playbackRef == ref
            : store.slots.prefix(store.layout).contains(ref)
        Button {
            switch store.mode {
            case .live: store.showInLive(ref)
            case .playback: store.playbackRef = ref
            }
        } label: {
            HStack {
                Image(systemName: online ? "video.fill" : "video.slash")
                    .foregroundStyle(online ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(dev.displayName(ch.id))
                    .foregroundStyle(online ? .primary : .secondary)
                Spacer()
                if selected {
                    Image(systemName: store.mode == .playback ? "checkmark" : "eye")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .listRowBackground(selected ? Color.accentColor.opacity(0.15) : Color.clear)
        .draggable(ref.token) {
            Label(dev.displayName(ch.id), systemImage: "video").padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let t = items.first, let src = CameraRef(token: t), src != ref else { return false }
            store.moveChannel(src, before: ref)
            return true
        }
        .contextMenu {
            Button("在即時畫面顯示") { store.mode = .live; store.showInLive(ref) }
            Button("回放錄影") { store.mode = .playback; store.playbackRef = ref }
            Button("在新視窗開啟") { openWindow(id: "camera", value: ref) }
            Divider()
            Button("重新命名…") { renameText = dev.displayName(ch.id); renaming = ref }
        }
    }
}
