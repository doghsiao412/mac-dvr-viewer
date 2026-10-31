import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var editor: DeviceEditorTarget?

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
                    Picker("分割", selection: Binding(get: { store.layout }, set: { store.setLayout($0) })) {
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
