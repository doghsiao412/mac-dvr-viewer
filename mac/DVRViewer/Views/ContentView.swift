import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var editor: DeviceEditorTarget?
    @State private var renameText = ""

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView(editor: $editor)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            Group {
                if store.devices.isEmpty {
                    ContentUnavailableView {
                        Label("尚未加入 DVR", systemImage: "video.badge.plus")
                    } description: {
                        Text("加入 DVR 的位址、Port 與帳號後，即可觀看即時影像與錄影。")
                    } actions: {
                        Button("加入 DVR…") { editor = .new }
                            .buttonStyle(.glassProminent)
                    }
                } else {
                    switch store.mode {
                    case .live: LiveGridView()
                    case .playback: PlaybackView()
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let t = store.toast {
                    Text(t)
                        .font(.callout)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: store.toast)
        }
        .toolbar {
            if !store.devices.isEmpty {
                ToolbarItem(placement: .navigation) { DeviceSwitcher() }
            }
            if !store.exports.jobs.isEmpty {
                ToolbarItem(placement: .primaryAction) { ExportToolbarButton() }
            }
            ToolbarItem(placement: .principal) {
                Picker("模式", selection: $store.mode) {
                    ForEach(ViewMode.allCases) { m in
                        Label(m.title, systemImage: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
            }
            if store.mode == .live {
                ToolbarItem(placement: .primaryAction) {
                    Picker("分割", selection: Binding(get: { store.gridLayout }, set: { store.setLayout($0) })) {
                        Label("1", systemImage: "square").tag(1)
                        Label("4", systemImage: "square.grid.2x2").tag(4)
                        Label("9", systemImage: "square.grid.3x3").tag(9)
                        Label("16", systemImage: "square.grid.4x3.fill").tag(16)
                    }
                    .pickerStyle(.segmented)
                    .help("分割畫面（⌘1–⌘4）")
                }
            }
        }
        .onChange(of: store.downloadFlight) { _, _ in
            // 等下載視窗的關閉動畫結束再飛，兩個動畫不要搶同一段時間
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard let win = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible })
                        ?? NSApp.mainWindow else { return }
                DownloadFlight.run(in: win) { store.downloadLanded += 1 }
            }
        }
        .alert("重新命名頻道", isPresented: Binding(get: { store.renaming != nil }, set: { if !$0 { store.renaming = nil } })) {
            TextField("名稱", text: $renameText)
            Button("儲存") { if let r = store.renaming { store.rename(r, to: renameText) }; store.renaming = nil }
            Button("恢復預設名稱") { if let r = store.renaming { store.rename(r, to: "") }; store.renaming = nil }
            Button("取消", role: .cancel) { store.renaming = nil }
        } message: {
            Text("名稱只存在本 App，不會修改 DVR 的設定。")
        }
        .onChange(of: store.renaming) { _, r in
            if let r { renameText = store.name(of: r) }
        }
        .sheet(item: $editor) { target in
            DeviceEditorView(target: target)
        }
    }
}

enum DeviceEditorTarget: Identifiable {
    case new
    case edit(DeviceConfig)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let c): return c.id.uuidString
        }
    }
}

/// 工具列：切換即時畫面要看的 DVR，或自訂畫面
struct DeviceSwitcher: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let current = store.currentDeviceID
        Menu {
            if store.mode == .live {
                Button {
                    store.switchToCustom()
                } label: {
                    if current == nil { Label("自訂畫面", systemImage: "checkmark") } else { Text("自訂畫面") }
                }
                Divider()
            }
            ForEach(store.devices) { dev in
                Button {
                    store.switchTo(dev.id)
                } label: {
                    if dev.id == current { Label(dev.config.name, systemImage: "checkmark") } else { Text(dev.config.name) }
                }
            }
        } label: {
            if let c = current.flatMap({ store.device($0) }) {
                Label(c.config.name, systemImage: "server.rack").labelStyle(.titleAndIcon)
            } else {
                Label("自訂畫面", systemImage: "square.grid.2x2").labelStyle(.titleAndIcon)
            }
        }
        .help("DVR 畫面顯示整台 DVR 的所有頻道；自訂畫面可從左側自選頻道（⌥⌘0 自訂、⌥⌘1–⌥⌘9 DVR、⌥⌘←／→ 上一台／下一台）")
    }
}
