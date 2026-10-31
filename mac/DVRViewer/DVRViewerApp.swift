import SwiftUI

@main
struct DVRViewerApp: App {
    @State private var store = AppStore()
    @StateObject private var updater = UpdaterModel()

    var body: some Scene {
        WindowGroup("DVR Viewer", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            DVRCommands(store: store)
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: updater) }
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
