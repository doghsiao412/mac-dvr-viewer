# DVR Viewer

Apple Silicon 原生 macOS App，直接連線既有的 TVT（及 OEM）DVR／NVR，提供即時影像、歷史錄影回放與下載，取代 SuperLive Plus 的日常使用。

```
Mac SwiftUI App ─▶ macOS 原生網路層（Network.framework）─▶ DVR／NVR
```


## 下載

[GitHub Releases](https://github.com/doghsiao412/mac-dvr-viewer/releases) 下載最新的 `DVR-Viewer-x.y.dmg`，打開後把 **DVR Viewer.app** 拖到「應用程式」。

* 0.2 起內建自動更新（Sparkle）：選單「DVR Viewer → 檢查更新…」，設定頁可關閉自動檢查。0.1 沒有自動更新，請手動下載一次 0.2

* 需求：Apple Silicon Mac、macOS 15 以上
* 此版本未經 Apple 公證（ad-hoc 簽章）。第一次開啟若出現「無法驗證開發者」：在 App 上按右鍵 →「打開」，或到「系統設定 → 隱私權與安全性」按「強制打開」
* 支援 TVT（及 OEM）NVMS-9000 系列 DVR／NVR：新韌體走網頁 WebSocket，舊韌體自動改用 TVT 私有協定（Port 6036）
* ⚠️ 這類 DVR 以未加密方式傳送登入資訊，經網際網路連線時建議使用 VPN

## 目前狀態

**v0.2**（見 [docs/progress.md](docs/progress.md)）

已在實體 DVR（TVT TD-2716NE-HC，NVMS-9000）驗證：登入、設備資訊、頻道、即時 H.265 串流、錄影查詢、錄影回放串流、VideoToolbox 硬體解碼（截圖）。
macOS App（DVR Viewer）已在實體 DVR 確認可用（即時畫面與錄影回放）：設備管理、1/4/9/16 分割即時畫面、24 小時時間軸回放。錄影下載：回放畫面按 ⌘D，存成 MP4（不轉碼）。證據見 [docs/test-results.md](docs/test-results.md)（Mock 與實體分開標示）。

### 執行 App

用 Xcode 開啟 `mac/DVRViewer.xcodeproj` 按 ⌘R，或：

```bash
xcodebuild -project mac/DVRViewer.xcodeproj -scheme DVRViewer -derivedDataPath mac/build/DerivedData build
open "mac/build/DerivedData/Build/Products/Debug/DVR Viewer.app"
```

### 開發工具

```bash
cd mac/Packages/DVRKit && swift build && swift test
# 在專案根目錄執行（密碼從 Keychain 讀取）：
mac/Packages/DVRKit/.build/debug/dvrcli <host> <port> <帳號> survey
mac/Packages/DVRKit/.build/debug/dvrcli <host> <port> <帳號> records 1 2026-10-29
mac/Packages/DVRKit/.build/debug/dvrcli <host> <port> <帳號> live 1 --seconds 5
mac/Packages/DVRKit/.build/debug/dvrcli <host> <port> <帳號> playback 1 "2026-10-29 12:00:00" --seconds 8
mac/Packages/DVRKit/.build/debug/dvrcli <host> <port> <帳號> snapshot 1 [--main]   # 解碼並存截圖到 captures/
mac/Packages/DVRKit/.build/debug/dvrcli decode captures/<檔>.bin                  # 離線解碼
```

## 文件

| 文件 | 內容 |
|---|---|
| [docs/progress.md](docs/progress.md) | 進度、待辦、技術決策 |
| [docs/protocol-analysis.md](docs/protocol-analysis.md) | TVT 協定研究與封包證據 |
| [docs/compatibility.md](docs/compatibility.md) | 環境報告、SDK A/B/C/D 分類、可行性 |
| [docs/architecture.md](docs/architecture.md) | App 架構與模組 |
| [docs/capture-guide.md](docs/capture-guide.md) | SuperLive Plus 封包分析操作步驟 |
| [docs/test-results.md](docs/test-results.md) | 測試紀錄 |

## 分析工具（Phase 1）

```bash
tools/slp-watch.sh find-dvr                          # 找出 SuperLive Plus 連到哪（不需 sudo）
tools/dvr-credentials.sh set <IP> <帳號>             # 密碼存 Keychain
python3 -I tools/dvr_probe.py <IP> --user <帳號>     # 非破壞性 RTSP/HTTP/ONVIF 探測
sudo tools/capture.sh <IP> testA-login               # 抓封包（需 sudo）
python3 -I tools/pcap_analyze.py captures/<檔>.pcap --dvr <IP> --user <帳號>
python3 -I tools/tests/test_pcap_analyze.py          # 分析器自我測試（Mock）
```

## 安全

密碼只存在 macOS Keychain。`captures/`（pcap、報告、影像）只留在本機，並被 `.gitignore` 排除。
