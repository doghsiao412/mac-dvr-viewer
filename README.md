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
* **錄影回放**：4 分割同步回放、拖曳式時間軸（可縮放到 1 分鐘）、移動偵測事件清單、暫停、0.5–16 倍速、逐格、±10 秒、聲音
* **錄影下載**：可一次選多支攝影機，指定時段（或在時間軸標記範圍，精確到秒）存成 MP4（錄影原始畫質、影像不轉碼、聲音轉 AAC），自動略過無錄影空檔，預設存到「下載項目」，完成時發送 macOS 通知
* **傳輸方式自動選擇**：新韌體走網頁 WebSocket（DVR 限制約 6 條，多出的即時畫面改走私有協定）；舊韌體（約 2020 年前）走 TVT 私有協定（Port 6036）
* VideoToolbox 硬體解碼、Liquid Glass 介面

已實測：TVT TD-2716NE-HC（韌體 1.3.8）、TD-2716TE-HC（韌體 1.3.6）。

## 使用教學

### 1. 加入 DVR

1. 按左上角的 **＋**（或選單「加入 DVR…」）。
2. 填入：
   * **名稱**：自己好認的名字，例如「公司 DVR」
   * **IP 或主機名稱**：例如 `192.168.1.100` 或 `mydvr.ddns.net`
   * **Port（網頁連接埠）**：平常用瀏覽器連 DVR 網頁的那個 Port
   * **影像服務 Port**：保持 6036 即可，連線成功後會自動帶入 DVR 自己設定的 Port（DVR「網路 → 連接埠」中的伺服器 Port）。只有路由器把它轉發成不同號碼時才需要手動填外部 Port（較舊韌體的 DVR，或同時看超過 6 路即時影像時會用到）
   * **帳號、密碼**：DVR 的登入帳號。密碼只存在這台 Mac 的鑰匙圈
3. 按「登入」，連線成功後左側會列出所有頻道。

> 更新 App 後第一次開啟，macOS 可能會詢問鑰匙圈權限，請按 **「永遠允許」**，之後就不會再問。

### 2. 即時影像

* **整台 DVR**：點左上角的畫面選單，選一台 DVR，就會依序顯示它的所有頻道。用右上角的分割按鈕切換 1／4／9／16 分割（⌘1–⌘4）；頻道比格子多時，下方會出現換頁按鈕（⌘[／⌘]）。
* **自訂畫面**：想把不同 DVR 的攝影機排在一起時，在畫面選單選「新增自訂畫面…」。之後點一下格子選取，再點左側的頻道放進去，或直接把頻道拖到格子裡；選取格子後按 Delete 可以清空。自訂畫面可在同一個選單重新命名或移除。
* **放大**：雙擊任一格放大，按左上角的返回按鈕（或再雙擊）回到分割畫面。
* **右鍵選單**：截圖、在新視窗開啟（可置頂）、回放此頻道錄影等。
* **頻道改名**：在左側雙擊頻道名稱即可改名；名稱只存在 App，不會修改 DVR。
* **DVR 排序**：畫面選單最下方「編輯 DVR 順序…」。

### 3. 錄影回放

1. 切到上方的 **「錄影回放」**，點左側要看的頻道。
2. 上方選日期（或按「今天」）；拖曳下方時間軸選時間，捏合或滾輪縮放時間軸。
3. 下方控制列：播放／暫停（空白鍵）、±10 秒、逐格（.）、0.5–16 倍速、聲音。
4. **4 分割同步回放**：右上角切到 4 分割，把左側頻道拖到格子裡（或點一下格子選取，再點左側頻道）；格子之間可拖曳互換。4 格會同步播放同一個時間，時間軸、暫停、倍速一起控制；聲音、截圖、下載以選取的格子為準。
5. **事件清單**：按控制列的 **「事件」**（E），列出當天的移動偵測等事件，可依類型、攝影機篩選，點一下就跳到該時間播放。事件來自 DVR 的移動偵測錄影；若 DVR 設定為全天排程錄影，清單會是空的（改成「移動偵測錄影」，或使用有「日誌」權限的帳號即可列出）。

### 4. 下載錄影

在錄影回放按右下角的 **「下載」**（⌘D），選擇時間範圍與攝影機（可勾選多支，或「全選」），按「開始下載」。檔案存成 MP4，預設放在「下載項目」，完成時會跳出 macOS 通知，點通知可在 Finder 中顯示。

**用時間軸標記範圍**：播放到想要的開頭按 **I**、到結尾按 **O**（或用控制列的「標記」選單），也可以按住 **Shift** 在時間軸上拖曳。標記的範圍會以黃色顯示，左下角顯示起訖時間；這時按「下載」會自動帶入這段範圍，精確到秒。

### 5. 多台 Mac 同步

讓家裡、公司的多台 Mac 共用同一份 DVR 清單，不用每台都重新輸入。

**會同步**：DVR 清單（名稱、位址、Port、帳號）、頻道名稱與順序、DVR 順序、自訂畫面。
**不會同步**：**密碼**。密碼只存在各台 Mac 的鑰匙圈，不會寫進同步檔案。

**第一台 Mac（已經設定好 DVR 的那台）**

1. 開啟設定（選單「DVR Viewer → 設定…」或 ⌘,），找到「多台 Mac 同步」。
2. 按「選擇同步資料夾…」，選一個會自動同步到雲端的資料夾，例如：
   * **iCloud 雲碟**（預設會先開在這裡），建議在裡面建一個「DVR Viewer」資料夾
   * **Google 雲端硬碟** 或 **Dropbox** 中的資料夾
3. App 會在資料夾裡建立 `DVR Viewer 設定.json`，之後每次修改都會自動更新它。

**其他 Mac**

1. 安裝 DVR Viewer，開啟後在空白畫面點 **「已在其他裝置設定過？點我設定同步」**（或到設定 →「多台 Mac 同步」）。
2. 選擇**同一個**資料夾。資料夾裡已有設定時會詢問，選 **「使用同步資料夾的設定」**。
3. 幾秒後 DVR 清單就會出現。側邊欄會顯示「這台 Mac 尚未輸入密碼」，點一下輸入該 DVR 的密碼即可。每台 DVR 在每台 Mac 只需輸入一次。

**小提醒**

* 之後在任一台 Mac 新增、修改、排序 DVR 或自訂畫面，其他 Mac 開著 App 時幾秒內就會自動套用。兩台同時修改時，以最後修改的為準。
* 雲端資料夾本身要先能正常同步（例如 Mac 已登入同一個 iCloud 帳號，或已安裝 Google 雲端硬碟）。
* 想立刻同步可按「立即同步」；不想再同步時按「停止同步」，這台 Mac 的設定會保留。

### 6. 更新

App 開啟時會自動檢查新版，有新版會列出更新內容，可選：

* **安裝並重新啟動**：立即更新
* **關閉後自動安裝**：下次關閉 App 時安裝，再開啟時會提示更新內容
* **暫不更新**：略過這一版（之後仍可從選單「檢查更新…」更新）

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
