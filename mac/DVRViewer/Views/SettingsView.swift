import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView {
            Form {
                Section("即時影像") {
                    Toggle("放大單一畫面時使用主串流", isOn: $store.useMainStreamWhenEnlarged)
                    Text("實測此類 DVR 經網際網路觀看時，主串流幀率很低（約每秒 1 張）。預設在所有畫面使用子串流（流暢），可在畫面右鍵選單個別切換。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("截圖") {
                    LabeledContent("儲存位置") {
                        Text(AppStore.snapshotFolder.path(percentEncoded: false))
                            .textSelection(.enabled)
                    }
                    Button("在 Finder 中顯示") { NSWorkspace.shared.open(AppStore.snapshotFolder) }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("一般", systemImage: "gearshape") }

            Form {
                Section("安全性") {
                    Text("DVR 密碼只儲存在 macOS 鑰匙圈，不會寫入任何檔案。")
                    Text("NVMS-9000 類 DVR 以未加密的 HTTP 傳送登入資訊與影像。經網際網路連線時，建議透過 VPN。")
                        .foregroundStyle(.secondary)
                }
                Section("通訊方式") {
                    Text("直接連線 DVR 的網頁連接埠：HTTP XML（登入、頻道、錄影查詢）＋ WebSocket（即時與回放 H.265/H.264），以 VideoToolbox 硬體解碼。不經雲端、不需 SuperLive Plus。")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("關於", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 340)
    }
}
