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
                            .buttonStyle(.borderedProminent)
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
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
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
