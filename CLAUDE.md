# CLAUDE.md — DVR Viewer

給接手的 AI 工作階段：先讀 `docs/progress.md`（目前狀態與下一步），再讀 `docs/protocol-analysis.md`。

## 專案

原生 macOS（Apple Silicon）DVR 用戶端，直接連 TVT 系列 DVR/NVR。取代 SuperLive Plus。
驗收標準：不開 SuperLive Plus、不用 Docker，就能用自己的 App 看即時影像並回放 DVR 硬碟中的錄影。

## 溝通

* 所有進度、文件、App UI 使用**繁體中文**。
* 不宣稱未經實體 DVR 驗證的功能已完成；Mock 成功與實體成功要分開寫在 `docs/test-results.md`。

## 安全規則（必須遵守）

* 絕不要求使用者在聊天中貼 DVR 密碼；用 `tools/dvr-credentials.sh`（Keychain，service `DVRViewer.dev`，account `<user>@<host>`）。
* 不讀取原始 pcap 內容到上下文；只讀 `tools/pcap_analyze.py` 產生的遮蔽報告（`captures/*.report.md`）。
* `captures/`、pcap、影像、截圖永不提交 Git。
* 不掃描網段、不暴力破解、不修改 DVR 設定、不刪錄影、不解密或注入 SuperLive Plus。
* sudo / 安裝需要管理員權限的軟體 / 改系統設定 → 先說明並取得同意（`tcpdump` 由使用者自己 sudo 執行）。

## 技術方向

* Swift 6、SwiftUI（+AppKit）、Network.framework、VideoToolbox、AVFoundation、Swift Concurrency、Keychain。
* 不用 Electron；不載入 Linux `.so`；Linux VM 跑原廠 SDK 只是最後手段（見 `docs/compatibility.md`）。
* **通訊協定**：NVMS-9000 Web API — HTTP XML（`POST /<指令>`）＋ WebSocket（`/requestWebsocketConnection`），使用 DVR 網頁 Port。較舊韌體（2020 前，無 `js/lib/websocket.cmd.js`）的影像改走 **TVT 私有協定（SERVICE Port 6036）**，由 `DVRConnection` 自動選擇。細節見 `docs/protocol-analysis.md` §0、§0.4。RTSP/ONVIF 外網不可用。
* 協定原始依據是 DVR 網頁前端 JS（`http://DVR:port/js/lib/websocket.cmd.js` 等），有疑問時重新讀取，不要猜。
* 模組分離見 `docs/architecture.md`；協定與媒體核心放在 Swift Package `mac/Packages/DVRKit`。

## 參考資料

* 2BAD/tvt（MIT）：`git clone --depth 1 https://github.com/2BAD/tvt` 到 scratchpad；重點 `proto/*.lua`、`docs/vendor/include/DVR_NET_SDK.h`、`source/lib/sdk.ts`。不要把 vendor 檔案複製進本 repo。
* SuperLive Plus：`/Applications/SuperLivePlus.app/Wrapper/SuperLivePlus.app/SuperLivePlus`（只用 `strings` 讀取）。

## 常用指令

```bash
cd mac/Packages/DVRKit && swift build && swift test
mac/Packages/DVRKit/.build/debug/dvrcli <host> <port> <user> survey   # 在 repo 根目錄執行，輸出到 captures/
mac/Packages/DVRKit/.build/debug/dvrcli <host> <port> <user> export <頻道> "yyyy-MM-dd HH:mm:ss" <秒數>   # 下載 MP4 並驗證
mac/Packages/DVRKit/.build/debug/dvrcli <host> <port> <user> chcheck <yyyy-MM-dd>   # 逐頻道驗證回放頻道
SPARKLE_BIN=<Sparkle 發行包>/bin tools/release.sh <版本> <內部版本號>   # 發佈：編譯→DMG→Sparkle 簽章→appcast 項目
python3 -I tools/tests/test_pcap_analyze.py
python3 -I tools/pcap_analyze.py captures/<f>.pcap --dvr <IP> --user <帳號>
python3 -I tools/dvr_probe.py <IP> --user <帳號>
```
