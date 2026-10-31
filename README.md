# DVR Viewer

Apple Silicon 原生 macOS App，直接連線既有的 TVT（及 OEM）DVR／NVR，提供即時影像、聲音、歷史錄影回放與下載，取代 SuperLive Plus 的日常使用。

```
Mac SwiftUI App ─▶ macOS 原生網路層（Network.framework）─▶ DVR／NVR
```

## 下載

[GitHub Releases](https://github.com/doghsiao412/mac-dvr-viewer/releases) 下載最新的 `DVR-Viewer-x.y.dmg`，打開後把 **DVR Viewer.app** 拖到「應用程式」。

* 需求：Apple Silicon Mac、**macOS 26** 以上（0.2 為最後支援 macOS 15 的版本）
* 內建自動更新：開啟 App 時自動檢查，也可從選單「DVR Viewer → 檢查更新…」，設定頁可關閉自動檢查（0.1 沒有自動更新，請手動下載新版一次）
* 此 App 未經 Apple 公證（ad-hoc 簽章）。第一次開啟若出現「無法驗證開發者」：在 App 上按右鍵 →「打開」，或到「系統設定 → 隱私權與安全性」按「強制打開」
* ⚠️ 這類 DVR 以未加密方式傳送登入資訊，經網際網路連線時建議使用 VPN

各版本更新內容見 [RELEASE_NOTES.md](RELEASE_NOTES.md)。

## 功能

* **設備管理**：多台 DVR、可透過 iCloud 雲碟／Google 雲端硬碟資料夾在多台 Mac 同步設定（不含密碼）、密碼存 macOS 鑰匙圈、自動連線與重連、頻道自訂名稱與排序、側邊欄可收合
* **即時影像**：DVR 畫面（一鍵切換整台 DVR，可分頁）與自訂畫面、1／4／9／16 分割（超過 DVR 網頁連線上限時自動改走私有協定）、拖放頻道、雙擊放大、數位縮放、截圖、獨立攝影機視窗（可置頂）、聲音（同時一格出聲）
* **錄影回放**：拖曳式時間軸（可縮放到 1 分鐘）、暫停、0.5–16 倍速、逐格、±10 秒、聲音
* **錄影下載**：可一次選多支攝影機，指定時段存成 MP4（錄影原始畫質、影像不轉碼、聲音轉 AAC），自動略過無錄影空檔，預設存到「下載項目」，完成時發送 macOS 通知
* **傳輸方式自動選擇**：新韌體走網頁 WebSocket（DVR 限制約 6 條，多出的即時畫面改走私有協定）；舊韌體（約 2020 年前）走 TVT 私有協定（Port 6036）
* VideoToolbox 硬體解碼、Liquid Glass 介面

已實測：TVT TD-2716NE-HC（韌體 1.3.8）、TD-2716TE-HC（韌體 1.3.6）。

## 開發

用 Xcode 開啟 `mac/DVRViewer.xcodeproj` 按 ⌘R，或：

```bash
xcodebuild -project mac/DVRViewer.xcodeproj -scheme DVRViewer -derivedDataPath mac/build/DerivedData build
open "mac/build/DerivedData/Build/Products/Debug/DVR Viewer.app"
```

協定與媒體核心在 Swift Package `mac/Packages/DVRKit`，附命令列驗證工具 `dvrcli`：

```bash
cd mac/Packages/DVRKit && swift build && swift test
# 在專案根目錄執行（密碼從 Keychain 讀取，見 tools/dvr-credentials.sh）：
mac/Packages/DVRKit/.build/debug/dvrcli <host> <port> <帳號> survey
mac/Packages/DVRKit/.build/debug/dvrcli <host> <port> <帳號> playertest playback 1 "2026-10-29 12:00:00"
mac/Packages/DVRKit/.build/debug/dvrcli <host> <port> <帳號> export 1 "2026-10-29 12:00:00" 120   # 下載 MP4 並驗證
mac/Packages/DVRKit/.build/debug/dvrcli <host> <port> <帳號> audiotest live 1
```

發佈新版本：`SPARKLE_BIN=<Sparkle>/bin tools/release.sh <版本> <內部版本號>`（編譯 → DMG → 簽章 → appcast）。

| 文件 | 內容 |
|---|---|
| [RELEASE_NOTES.md](RELEASE_NOTES.md) | 各版本更新內容 |
| [docs/protocol-analysis.md](docs/protocol-analysis.md) | TVT 協定研究與封包證據（NVMS-9000 Web API、WebSocket、私有協定、聲音） |
| [docs/architecture.md](docs/architecture.md) | App 架構與模組 |
| [docs/progress.md](docs/progress.md) | 進度、待辦、技術決策 |
| [docs/test-results.md](docs/test-results.md) | 測試紀錄（Mock 與實體 DVR 分開標示） |
| [docs/compatibility.md](docs/compatibility.md) | 環境報告與可行性 |
| [docs/capture-guide.md](docs/capture-guide.md) | 封包分析操作步驟 |

封包分析工具（`tools/`）：`slp-watch.sh`、`capture.sh`、`pcap_analyze.py`、`dvr_probe.py`、`re/tvt_frames.py`。密碼只存在 macOS 鑰匙圈；封包、截圖與影像只留在本機 `captures/`，不會進 Git。

## 致謝

本專案參考或使用了以下專案與資料，感謝作者們的貢獻：

* **[Sparkle](https://github.com/sparkle-project/Sparkle)**（MIT 授權）— App 內建的自動更新框架，以及簽章用的 `generate_keys`、`sign_update` 工具。
* **[2BAD/tvt](https://github.com/2BAD/tvt)**（MIT 授權）— TVT 裝置 SDK 的 TypeScript 包裝。它的 Wireshark 協定解析器（`proto/*.lua`）、原廠 C 標頭與文件，是理解 TVT 私有協定框架（`"1111"`／`head` 封包、登入結構、命令碼、回放控制碼、錄影檔結構）的重要起點。本專案沒有複製其程式碼或原廠檔案，僅作為研究參考。
* **TVT（同為科技）NVMS-9000 網頁用戶端** — DVR 內建網頁的前端程式，是本專案 HTTP XML API 與 WebSocket 影像協定的主要依據（只讀取設備公開提供的網頁檔案，未納入本 repo）。
* **SuperLive Plus**（TVT 官方 App）— 用於比對實際的網路通訊行為（只分析自己設備的網路封包與 App 的公開字串，未解密、修改或重新散布）。
* Apple 平台框架：SwiftUI、Network.framework、VideoToolbox、AVFoundation、Security（Keychain）。

TVT、SuperLive、NVMS 為其各自所有者的商標。本專案為個人開發的非官方用戶端，與 TVT 無任何關聯，亦未獲其認可。
