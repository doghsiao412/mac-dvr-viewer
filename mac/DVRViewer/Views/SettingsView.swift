import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        @Bindable var store = store
        TabView {
            Form {
                Section("進階功能") {
                    Toggle("顯示進階功能", isOn: $store.advancedFeatures)
                    Text("一般不需要開啟，App 會自動使用最佳設定：即時影像用流暢的子串流，回放與下載用錄影原始畫質。開啟後可在畫面右鍵選單與攝影機視窗切換主／子串流。")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.advancedFeatures {
                        Toggle("放大單一畫面時使用主串流", isOn: $store.useMainStreamWhenEnlarged)
                        Text("部分 DVR 經網際網路觀看時主串流幀率很低（約每秒 1 張），若放大後變卡請關閉。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("聲音") {
                    LabeledContent("音量") {
                        Slider(value: $store.volume, in: 0...1)
                    }
                    Text("即時畫面同時只有一個畫面出聲：滑鼠移到畫面上按喇叭圖示。回放只在 1× 播放時輸出聲音。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    if let f = store.sync.folder {
                        LabeledContent("同步資料夾") {
                            Text(f.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        HStack {
                            Button("立即同步") { store.sync.syncNow() }
                            Button("更換資料夾…") { store.sync.chooseFolder() }
                            Spacer()
                            Button("停止同步", role: .destructive) { store.sync.stopSync() }
                        }
                        if let e = store.sync.lastError {
                            Text(e).font(.caption).foregroundStyle(.red)
                        } else if let d = store.sync.lastSync {
                            Text("上次同步：\(d.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("選擇同步資料夾…") { store.sync.chooseFolder() }
                    }
                } header: {
                    Text("多台 Mac 同步")
                } footer: {
                    Text("選一個 iCloud 雲碟、Google 雲端硬碟或 Dropbox 中的資料夾，其他 Mac 選同一個資料夾即可同步 DVR 清單、頻道名稱與順序、自訂畫面。密碼不會同步：在其他 Mac 第一次連線時，於 DVR 名稱上按右鍵 →「編輯…」輸入一次。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("更新") {
                    Toggle("自動檢查更新（開啟 App 時及每天）", isOn: $updater.automaticallyChecks)
                    HStack {
                        Text("目前版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("立即檢查更新") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                    if let d = updater.lastCheck {
                        Text("上次檢查：\(d.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
        .frame(width: 560, height: 560)
    }
}
