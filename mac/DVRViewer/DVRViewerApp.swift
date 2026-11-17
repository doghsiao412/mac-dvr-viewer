import AppKit
import SwiftUI

@main
struct DVRViewerApp: App {
    @State private var store = AppStore()
    @StateObject private var updater = UpdaterModel()

    var body: some Scene {
        WindowGroup("DVR Viewer", id: "main") {
            ContentView()
                .environment(store)
                .environmentObject(updater)
                .frame(minWidth: 900, minHeight: 600)
                // 全螢幕時工具列自動隱藏，滑鼠移到螢幕頂端才出現（影像延伸到頂端）
                .windowToolbarFullScreenVisibility(.onHover)
        }
        .commands {
            // 「檔案」：⌘N 改為加入 DVR（多個畫面請用「在新視窗開啟」攝影機視窗）
            CommandGroup(replacing: .newItem) { AddDeviceCommand(store: store) }
            SidebarCommands()   // 「顯示方式」：隱藏／顯示側邊欄（⌃⌘S）
            DVRCommands(store: store)
            PlaybackCommands()
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: updater) }
            CommandGroup(replacing: .help) {
                Link("DVR Viewer 使用說明", destination: URL(string: "https://github.com/doghsiao412/mac-dvr-viewer#readme")!)
            }
        }

        // 獨立攝影機視窗（可放到第二螢幕、可置頂）
        WindowGroup("攝影機", id: "camera", for: CameraRef.self) { $ref in
            if let ref {
                CameraWindowView(ref: ref)
                    .environment(store)
                    .frame(minWidth: 320, minHeight: 180)
            }
        }
        .defaultSize(width: 640, height: 400)

        Settings {
            SettingsView(updater: updater)
                .environment(store)
        }
    }
}

struct DVRCommands: Commands {
    let store: AppStore

    private var selectedSupportsPTZ: Bool {
        guard let r = store.selectedLiveRef, let d = store.device(r.deviceID) else { return false }
        return d.ptzChannels.contains(r.channelID)
    }

    var body: some Commands {
        CommandMenu("畫面") {
            Button("即時影像") { store.mode = .live }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("錄影回放") { store.mode = .playback }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("單一畫面") { store.setLayout(1) }.keyboardShortcut("1")
            Button("4 分割") { store.setLayout(4) }.keyboardShortcut("2")
            Button("9 分割") { store.setLayout(9) }.keyboardShortcut("3")
            Button("16 分割") { store.setLayout(16) }.keyboardShortcut("4")
            Divider()
            Button("放大／還原選取的畫面") { store.toggleEnlarge(store.focusedSlot) }
                .keyboardShortcut(.return, modifiers: [.command])
            Group {
                Button(store.audioRef != nil && store.audioRef == store.selectedLiveRef ? "關閉選取畫面的聲音" : "開啟選取畫面的聲音") {
                    store.toggleAudioForSelected()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                Button("截圖選取的畫面") { store.sendTileCommand(.snapshot) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("雲台控制") { store.sendTileCommand(.togglePTZ) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    .disabled(!selectedSupportsPTZ)
            }
            .disabled(store.mode != .live || store.selectedLiveRef == nil)
            Button(store.immersive ? "離開全螢幕" : "全螢幕（隱藏介面）") { store.immersive.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.devices.isEmpty)
            Divider()
            Button("上一頁") { store.changePage(by: -1) }
                .keyboardShortcut("[", modifiers: [.command])
            Button("下一頁") { store.changePage(by: 1) }
                .keyboardShortcut("]", modifiers: [.command])
            Divider()
            Button("自訂畫面") { store.switchToCustom() }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button("上一台 DVR") { store.switchDevice(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("下一台 DVR") { store.switchDevice(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            ForEach(Array(store.devices.prefix(9).enumerated()), id: \.element.id) { i, dev in
                Button("切到「\(dev.config.name)」") { store.switchTo(dev.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
            }
        }
    }
}

/// 「檔案 → 加入 DVR…」：主視窗關著時先打開，再顯示新增視窗
struct AddDeviceCommand: View {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("加入 DVR…") {
            let hasMain = NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
            if !hasMain { openWindow(id: "main") }
            Task { @MainActor in
                if !hasMain { try? await Task.sleep(for: .milliseconds(400)) }
                store.addDeviceRequested += 1
            }
        }
        .keyboardShortcut("n")
    }
}

// MARK: - 「播放」選單（錄影回放）

/// 回放畫面提供給選單列的操作；回放畫面不在前景時為 nil，選單項目會停用
struct PlaybackActions {
    var isPlaying: Bool
    var speed: Double
    var speeds: [Double]
    var audioOn: Bool
    var togglePlay: () -> Void
    var skip: (Double) -> Void
    var step: () -> Void
    var setSpeed: (Double) -> Void
    var toggleAudio: () -> Void
    var toggleEvents: () -> Void
    var toggleTranscript: () -> Void
    var markIn: () -> Void
    var markOut: () -> Void
    var clearMarks: () -> Void
    var snapshot: () -> Void
    var download: () -> Void
}

extension FocusedValues {
    @Entry var playbackActions: PlaybackActions?
}

/// 回放畫面裡的單鍵快捷鍵（空白鍵、方向鍵、E、T、I、O、.）只在回放畫面有效，
/// 選單項目把它們寫在名稱裡，方便查找；⌘ 組合鍵則直接設在選單上。
struct PlaybackCommands: Commands {
    @FocusedValue(\.playbackActions) private var actions

    var body: some Commands {
        CommandMenu("播放") {
            Group {
            Button(actions?.isPlaying == true ? "暫停（空白鍵）" : "播放（空白鍵）") { actions?.togglePlay() }
            Button("倒退 10 秒（←）") { actions?.skip(-10) }
            Button("前進 10 秒（→）") { actions?.skip(10) }
            Button("逐格（.）") { actions?.step() }
            Menu("播放速度") {
                ForEach(actions?.speeds ?? [], id: \.self) { s in
                    Toggle(s == 0.5 ? "0.5×" : "\(Int(s))×", isOn: Binding(get: { actions?.speed == s }, set: { _ in actions?.setSpeed(s) }))
                }
            }
            Toggle("聲音", isOn: Binding(get: { actions?.audioOn ?? false }, set: { _ in actions?.toggleAudio() }))
            Divider()
            Button("事件清單（E）") { actions?.toggleEvents() }
            Button("逐字稿（T）") { actions?.toggleTranscript() }
            Divider()
            Button("設為下載起點（I）") { actions?.markIn() }
            Button("設為下載終點（O）") { actions?.markOut() }
            Button("清除標記") { actions?.clearMarks() }
            Divider()
            Button("截圖") { actions?.snapshot() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("下載錄影…") { actions?.download() }
                .keyboardShortcut("d")
            }
            .disabled(actions == nil)
        }
    }
}
