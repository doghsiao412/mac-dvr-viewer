import SwiftUI

@main
struct DVRViewerApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("DVR Viewer", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands { DVRCommands(store: store) }

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
            SettingsView()
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
        }
    }
}
