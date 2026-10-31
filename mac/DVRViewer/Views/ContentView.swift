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
        .sheet(isPresented: $store.editingDeviceOrder) { DeviceOrderSheet() }
        .modifier(CustomViewDialogs())
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
                Section("自訂畫面") {
                    ForEach(store.customViews) { v in
                        Button {
                            store.switchToCustom(v.id)
                        } label: {
                            if current == nil && v.id == store.customID { Label(v.name, systemImage: "checkmark") } else { Text(v.name) }
                        }
                    }
                }
                Divider()
            }
            Section("DVR") {
            ForEach(store.devices) { dev in
                Button {
                    store.switchTo(dev.id)
                } label: {
                    if dev.id == current { Label(dev.config.name, systemImage: "checkmark") } else { Text(dev.config.name) }
                }
            }
            }
            Divider()
            if store.mode == .live {
                Button("新增自訂畫面…") { store.customNameEdit = .new }
                if current == nil, let c = store.currentCustom {
                    Button("重新命名「\(c.name)」…") { store.customNameEdit = .rename(c.id) }
                    Button("移除「\(c.name)」…") { store.deletingCustom = c.id }
                        .disabled(store.customViews.count <= 1)
                }
            }
            if store.devices.count > 1 {
                Button("編輯 DVR 順序…") { store.editingDeviceOrder = true }
            }
        } label: {
            // 自己畫標籤：箭頭固定在最右側，寬度依名稱自動調整
            let dev = current.flatMap { store.device($0) }
            HStack(spacing: 6) {
                Image(systemName: dev != nil ? "server.rack" : "square.grid.2x2")
                Text(dev?.config.name ?? store.currentCustom?.name ?? "自訂畫面")
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
        }
        .menuIndicator(.hidden)
        // 依名稱長度顯示完整名稱（工具列預設會把文字截斷）
        .fixedSize()
        .help("DVR 畫面顯示整台 DVR 的所有頻道；自訂畫面可從左側自選頻道（⌥⌘0 自訂、⌥⌘1–⌥⌘9 DVR、⌥⌘←／→ 上一台／下一台）")
    }
}

/// 編輯 DVR 順序：拖曳列調整（側邊欄、切換選單與 ⌥⌘1–9 都依此順序）
struct DeviceOrderSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("編輯 DVR 順序").font(.headline).padding([.horizontal, .top], 16)
            Text("拖曳調整順序，或用右側箭頭移動。").font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 4)
            List {
                ForEach(Array(store.devices.enumerated()), id: \.element.id) { i, dev in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Text(i < 9 ? "⌥⌘\(i + 1)" : "").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .leading)
                        Text(dev.config.name)
                        Spacer()
                        Button { withAnimation(.snappy) { store.moveDevice(dev.id, by: -1) } } label: { Image(systemName: "chevron.up") }
                            .disabled(i == 0)
                        Button { withAnimation(.snappy) { store.moveDevice(dev.id, by: 1) } } label: { Image(systemName: "chevron.down") }
                            .disabled(i == store.devices.count - 1)
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 3)
                }
                .onMove { store.moveDevices(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 380, height: 360)
    }
}

/// 自訂畫面的新增／重新命名／移除對話框
struct CustomViewDialogs: ViewModifier {
    @Environment(AppStore.self) private var store
    @State private var customName = ""

    func body(content: Content) -> some View {
        content
            .alert(store.customNameEdit == .new ? "新增自訂畫面" : "重新命名自訂畫面",
                   isPresented: Binding(get: { store.customNameEdit != nil }, set: { if !$0 { store.customNameEdit = nil } })) {
                TextField("名稱", text: $customName)
                Button(store.customNameEdit == .new ? "新增" : "儲存") {
                    switch store.customNameEdit {
                    case .new: store.addCustomView(named: customName)
                    case .rename(let id): store.renameCustomView(id, to: customName)
                    case nil: break
                    }
                    store.customNameEdit = nil
                }
                Button("取消", role: .cancel) { store.customNameEdit = nil }
            } message: {
                if store.customNameEdit == .new { Text("新增後從左側點選或拖曳頻道到格子中。") }
            }
            .onChange(of: store.customNameEdit) { _, e in
                switch e {
                case .new: customName = "自訂畫面 \(store.customViews.count + 1)"
                case .rename(let id): customName = store.customViews.first { $0.id == id }?.name ?? ""
                case nil: break
                }
            }
            .confirmationDialog("移除這個自訂畫面？",
                                isPresented: Binding(get: { store.deletingCustom != nil }, set: { if !$0 { store.deletingCustom = nil } }),
                                presenting: store.deletingCustom.flatMap { id in store.customViews.first { $0.id == id } }) { v in
                Button("移除「\(v.name)」", role: .destructive) { store.deleteCustomView(v.id); store.deletingCustom = nil }
            } message: { _ in
                Text("只會移除這個畫面的排列，不影響 DVR 或錄影。")
            }
    }
}
