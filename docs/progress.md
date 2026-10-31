# 進度

## 目前狀態（2026-10-31，v0.8）

**原生直連可行，已在實體 DVR 驗證**：Swift 程式（不經 SuperLive Plus、不用 Docker）已能登入外網 DVR、
讀設備資訊與頻道、取即時 H.265 影像、查詢錄影、取得歷史錄影串流，並以 VideoToolbox 硬體解碼成畫面。**macOS App（DVR Viewer）已在實體 DVR 上由使用者確認即時畫面與錄影回放正常 → 專案最終驗收標準已達成**（不開 SuperLive Plus、不用 Docker）。錄影下載（MP4，不轉碼）已在兩台實體 DVR 驗證。

協定細節見 `docs/protocol-analysis.md` §0；測試證據見 `docs/test-results.md`。

## 下一版待辦

* **iPhone 版（試作中）**：計畫 ① DVRKit 支援 iOS → ② 新增 iPhone App 最小版（加入 DVR、頻道清單、單頻道即時影像）→ ③ 手機介面（4 分割、全螢幕、橫放、回放時間軸、事件、下載存到照片／檔案）→ ④ 平台差異（無 Sparkle 改 TestFlight／Xcode 安裝、Info.plist 開放 HTTP 與區域網路權限、切背景後自動重連）。
  * ✅ ①（2026-10-31）：Package 加 `.iOS(.v26)`；macOS 專屬的 `XMLDocument` 改為跨平台 `DVRXMLElement`（`XMLParser`）；`AudioPlayer` 在 iOS 設定 `AVAudioSession`（.playback）。iOS 編譯成功、macOS 測試與 App 編譯通過、dvrcli 對實體 DVR 結果不變。**尚未在 iPhone 實機執行。**
  * ✅ ②（2026-10-31，**使用者已在 iPhone 實機確認即時影像**）：同一個 Xcode 專案新增 target `DVRViewerPhone`（`mac/DVRViewerPhone/`，Bundle ID `local.dvrviewer.phone`，Personal Team 自動簽章）。Mac 與 iPhone 共用的檔案移到 `mac/Shared/`（DeviceConfig、DeviceModel、KeychainStore、VideoRenderer、PlayerControllers；`VideoSurface` 以 `#if os` 分 NSView／UIView）。畫面：DVR 清單（滑動編輯／刪除）→ 加入 DVR（測試登入後才儲存）→ 頻道清單（離線頻道不可點）→ 單頻道即時影像（流暢／高畫質、聲音、直放 16:9、橫放全螢幕點一下顯示控制、觀看時不自動鎖定）。iPhone 實機編譯、簽章、安裝成功；使用者在 iPhone 信任開發者後，加入 DVR 並看到即時影像。
    * 免費 Personal Team 簽章 7 天到期，到期後需重新從 Xcode 安裝。
    * 這台 Mac 未安裝 iOS 模擬器執行環境（約 8 GB），目前直接用實機測試。
    * App 圖示沿用 Mac 版 1024 圖（含 macOS 透明圓角邊），之後換成 iOS 專用圖示。
  * ✅ ③（2026-10-31，**使用者已在 iPhone 實機確認全部正常**）：
    * DVR 頁改為 4 分割即時影像（左右滑換頁；只有目前頁且畫面在最上層時連線，使用子碼流）；點一下放大（單頻道頁），長按選單可進回放。單頻道頁被回放頁蓋住時停止串流。
    * 回放頁（單頻道）：時間軸手指拖曳／點一下跳轉／雙指縮放；倒退・前進 10 秒、倍速 0.5–16×、畫質、聲音；日期前後一天＋日曆；這天沒錄影時提供最近有錄影的日期；橫放全螢幕。
    * 事件清單（底部面板）：類型篩選，點一下跳到該時間。
    * 下載：選開始時間與長度（30 秒–30 分）→ `RecordingExporter` 存成 MP4（暫存資料夾）→「儲存到照片」（只要求加入權限）或分享／存到「檔案」；關閉面板時刪除暫存檔。
    * 時間軸繪製抽到 `mac/Shared/TimelineStyle.swift`，Mac 版 `RecordTimeline` 改為呼叫共用程式（Mac App 重新編譯通過，外觀邏輯未改）。
  * 下一步：④ 平台差異（切背景後自動重連、iOS 圖示）。

* **1.1 已發佈（build 17）**：回放頁「事件」清單（移動偵測等，來源為錄影區段的非排程類型＋有權限時的系統日誌）；時間軸標記下載範圍（I／O、Shift＋拖曳），「下載」帶入精確到秒的範圍；單格回放介面不遮畫面、控制列播放鍵置中。dvrcli `events` 已對實體 DVR 驗證；App 介面使用者已確認；系統日誌合併未驗證。

* ~~appcast 改放 GitHub Releases 附件~~：✅ 0.8 完成（SUFeedURL＝releases/latest/download/appcast.xml；repo 根目錄 appcast.xml 仍需更新給 0.7.2 以前的版本）。
* 待使用者實際使用確認：16 路同時播（8083）、拖曳頻道、點選不延遲、讀取卡住自動恢復、鑰匙圈更新後只問一次、超過上限提示。
* 之後可做：自動輪播、全螢幕監看模式、多路同步回放、移動偵測事件清單。

### 多路同步回放（2026-10-31，步驟 ①②③ 已實作，④ 未做）

* **介面**：回放頁加 1／4／9 分割（同一台 DVR 選多支）；一條共用時間軸（拖曳、暫停、倍速、±10 秒全部一起）；時間軸顯示所選攝影機錄影範圍的合併；某格該時間無錄影顯示「無錄影」；聲音只播選取的格子；雙擊放大。
* **同步**：各播放器改用共用「回放時鐘」（目前每個 PlaybackStreamPlayer 各自依 FILETIME 控速）：超前的等待、落後的跳幀追上；暫停＝時鐘停止且停止 refresh_play_index 回報（DVR 自動停送）；拖曳＝全部從新時間重開（現有 seek 流程）；>4× 沿用 key_frame 模式。
* **DVR 限制**：8083 `playbackMaxWin`=8、WebSocket 約 6 條（與即時共用，切到回放時即時已關閉）→ 4 分割可行；9 分割需比照即時，超過上限改走私有協定（`openPlayback` 目前沒有此切換）。8082 全走同一條私有協定，單路下載約 14 倍速，4 路頻寬充裕。
* **步驟**：① dvrcli 加「同時回放 4 路」實測兩台 DVR（改動小，先做）② DVRKit 共用時鐘 ③ 回放頁多格＋共用時間軸＋合併錄影範圍 ④ 回放的連線上限切換（9 分割才需要）。工作量約為「多支下載」的 3–4 倍。

## Phase 1：研究與協定驗證 — ✅ 完成

- [x] 環境檢查、SuperLive Plus 靜態字串研究、2BAD/tvt 研究、A/B/C/D 分類
- [x] 分析工具（slp-watch、capture、pcap_analyze、dvr_probe、dvr-credentials）與 Mock 測試
- [x] 外網探測：6036（TVT `head`）、8083（DVR 網頁）開啟；554/ONVIF 不可用
- [x] **關鍵發現**：DVR 網頁（NVMS-9000）使用 HTTP XML + WebSocket（wasm 播放器），前端 JS 可讀 → 完整協定
- [ ] ~~SuperLive Plus 封包 A–D~~：暫不需要（若日後要用 6036 私有協定再做）

## Phase 2：原生通訊原型 — 進行中

`mac/Packages/DVRKit`（Swift Package）＋ `dvrcli` 命令列：

- [x] NVMSClient：doLogin/doLogout、系統能力、基本設定、時間、頻道、在線、錄影日期、錄影區段
- [x] NVMSStream：WebSocket 連線、preview/playback open/close、refresh_play_index、SHFL 訊框解析
- [x] 實體驗證 1–5、7、8（見 test-results）
- [x] SHFLFrame 解析、VideoDecoder（VideoToolbox，H.265/H.264，硬體）、Snapshot（JPEG + 亮度統計）
- [x] `dvrcli decode`（離線）與 `dvrcli snapshot`（即時）實體驗證
- [x] DVRConnection（登入去重、Session 失效自動重登）、LiveStreamPlayer（自動重連、主子串流切換）、PlaybackStreamPlayer（控速、暫停、倍速、關鍵幀模式、跳轉、逐格）
- [x] `dvrcli playertest live|playback` 實體驗證播放器控制（見 test-results）
- [x] 錄影下載：RecordingExporter（快速回放 → AVAssetWriter passthrough → MP4；壓縮 >3 秒空檔；可取消）；`dvrcli export` 實體驗證
- [ ] 主串流低幀率原因（可能是 DVR 遠端限制）
- [ ] Session 逾時自動重登

## Phase 3：正式 macOS 專案 — 進行中

`mac/DVRViewer.xcodeproj`（Xcode 16+ 資料夾同步群組，新增檔案不需改專案檔）＋ `mac/DVRViewer/`：

- [x] 設備管理：新增／編輯／移除、儲存前實際登入測試、Keychain 密碼、自動連線與重連、30 秒保活與在線狀態
- [x] 側邊欄（NavigationSplitView）：設備狀態、頻道清單、自訂名稱、拖曳排序、右鍵選單、每台 DVR 可收合（記憶狀態；全部收合／展開）
- [x] Live View：1/4/9/16 分割、點選或拖放頻道、雙擊放大、主／子串流、畫面比例、數位縮放（捏合＋拖曳）、截圖、離線／重連提示、版面記憶
- [x] 獨立攝影機視窗（多視窗、第二螢幕、可置頂）
- [x] Playback：日期、拖曳式時間軸（播放位置固定在中央紅線；拖曳／觸控板滑動平移後跳轉；捏合、滾輪、⌘±、選單縮放 24 小時→1 分鐘，刻度最細 5 秒；單擊跳轉；空白處跳到下一段）、播放／暫停、±10 秒、逐格、0.5–16 倍速、主／子串流、截圖
- [x] 鍵盤：⌘1–⌘4 分割、⌘↩ 放大、⌥⌘L／⌥⌘P 切換模式、空白鍵播放、←→ ±10 秒、. 逐格、⌘＋／⌘－ 時間軸縮放、Delete 從即時畫面移除選取格（僅即時畫面有焦點時，不攔截輸入框）
- [x] 回放當天無錄影：提示並提供前後最接近有錄影的日期按鈕（舊韌體 536870942 視為無錄影）
- [x] 設定頁（主串流偏好、截圖位置、安全說明）
- [x] 使用者實機確認：Live／Playback 畫面正常（2026-10-31）
- [x] 偵測 DVR 韌體是否支援 WebSocket 串流，不支援時顯示說明（第二台 DVR，8082）
- [x] **TVT 私有協定（6036）**：舊韌體 DVR 的即時與回放（DVRKit TVTPrivateClient；App 自動選擇傳輸方式；設備設定新增「影像服務 Port」）
- [x] 錄影下載（Export）：回放畫面「下載」按鈕（⌘D）→ 選擇開始時間／長度（1–60 分或自訂）／子主串流／儲存位置（預設 ~/Movies/DVR Viewer）；背景下載、工具列進度、取消、開啟／在 Finder 顯示
- [x] 聲音：G.711 A-law 解碼 + AVAudioEngine；即時畫面同時一格出聲（喇叭按鈕）、回放 1× 出聲與音量；WebSocket DVR 已驗證
- [x] 私有協定（舊韌體）聲音：即時 0x501／0x502、回放 0x803 @84=3（第三台 DVR 實測）
- [x] Sparkle 2.10.0 自動更新（appcast：repo 根目錄 `appcast.xml`；EdDSA 私鑰在開發者鑰匙圈 `local.dvrviewer.app`；`tools/release.sh` 發佈流程）、改以 DMG 發佈
- [x] 錄影下載含聲音：G.711 → PCM → AAC（8 kHz 單聲道），聲音晚到時先暫存影像（最多 8 秒）再決定是否建聲音軌；交錯寫入、補靜音避免 AVAssetWriter 互等卡死
- [x] 最低版本改為 macOS 26（App 與 DVRKit；Package tools 6.2）
- [x] 下載預設存到「下載項目」；下載視窗不再顯示清單，開始後關閉並有圖示以弧線飛到右上角下載按鈕（類似 Safari），按鈕彈跳
- [x] 開啟 App 時自動在背景檢查更新（SUEnableAutomaticChecks=YES、啟動 3 秒後 checkForUpdatesInBackground；設定頁可關閉）
- [x] 回放與下載固定主串流（移除子／主切換；實測 8083 主串流回放 8 fps、下載正常；私有協定回放本來就不分）
- [x] 介面 Liquid Glass：回放影像滿版＋浮動玻璃面板（上方頻道／日期、下方時間軸與控制）、畫面格玻璃名稱列與玻璃圓形按鈕（GlassEffectContainer）、玻璃狀態提示與 toast、主要按鈕 glassProminent
- [ ] 多頻道同步回放、事件書籤
- [x] App 圖示（程式繪製：攝影機＋錄影燈＋時間軸）、Release 打包 **v0.1**（arm64、ad-hoc 簽章、未公證）→ GitHub Release
## Phase 4：整合與優化 — 未開始

## 重要技術決策

| 日期 | 決策 | 理由 |
|---|---|---|
| 2026-10-30 | 分析工具用 Python 標準函式庫，不安裝 Wireshark | 不需管理員權限、可內建遮蔽 |
| 2026-10-30 | 不解密、不注入 SuperLive Plus | 安全原則 |
| 2026-10-30 | 不使用 Linux .so / VM 方案 | 違反原生直連原則 |
| 2026-10-31 | **採用 NVMS-9000 Web API（HTTP XML + WebSocket，:8083）為唯一通訊協定** | 實體驗證可用；協定由 DVR 自帶 JS 公開；RTSP/ONVIF 外網不可用；6036 私有協定需逆向，不必要 |
| 2026-10-31 | dvrcli 開發階段用 `/usr/bin/security` 讀 Keychain | 避免未簽章 CLI 觸發 Keychain 授權視窗；正式 App 用 Keychain Services 自有項目 |
| 2026-10-31 | 錄影下載採「快速回放 + 本機封裝 MP4」，不用 `createRecBackupTask` | 後者是備份到 DVR 端 USB；回放傳輸約 19 倍速，足以下載 |
| 2026-10-31 | Live 放大預設仍用子串流 | 實測此 DVR 主串流遠端約 1 fps、解析度與子串流相同（1280×720）；主串流改為手動選項 |
| 2026-10-31 | App 暫不啟用 Sandbox、ad-hoc 簽章、Swift 5 語言模式 | 先確保功能可用；DVRKit 套件維持 Swift 6 嚴格併發。Release 前再評估 Sandbox（需 network.client）與正式簽章 |
| 2026-10-31 | 新增 TVT 私有協定，並以 MediaStream 統一 WebSocket／私有協定 | 舊韌體（2020）無 WebSocket 串流；播放器與解碼不需區分來源 |
| 2026-10-31 | 自動更新採 Sparkle 2.10.0（SPM，exactVersion），appcast 放 GitHub raw、DMG 放 Release | 主流開源方案；選發佈超過兩週的版本（2.10.1 僅 6 天）；App 未公證，靠 EdDSA 簽章確保更新檔完整 |
| 2026-10-31 | 最低版本 macOS 26 | 使用 Liquid Glass API（glassEffect、GlassEffectContainer、.glass 按鈕） |
| 2026-10-31 | 下載的聲音轉 AAC（不保留 G.711） | MP4 不支援 G.711；AVAssetWriter 內建 AAC 編碼，相容性最好 |
| 2026-10-31 | 新韌體即時影像超過 WebSocket 上限（實測 6 條）時，多出的畫面自動改走私有協定 | 同一條 WebSocket 無法多工（536871004）；私有協定一條 TCP 可傳多路（SuperLive Plus 同樣做法），實測 16 路正常 |
| 2026-10-31 | 所有設備密碼存成同一筆鑰匙圈項目，啟動後只讀一次並快取於記憶體 | ad-hoc 簽章每次更新／編譯都會改變，macOS 會對每筆項目重新詢問；DVR 多時無法使用 |
| 2026-10-31 | 顯示使用 VideoToolbox 解碼 → AVSampleBufferDisplayLayer（DisplayImmediately） | 同一份解碼結果可直接截圖；回放節奏由 PlaybackStreamPlayer 依 FILETIME 控制 |

## 安全注意

- DVR 登入密碼經 **明文 HTTP**（Base64）傳送到外網 8083，這是 DVR 自身設計。建議日後改經 VPN 連線，或確認路由器僅允許必要來源。
