# 進度

## 目前狀態（2026-10-31，v0.1 已發佈）

**原生直連可行，已在實體 DVR 驗證**：Swift 程式（不經 SuperLive Plus、不用 Docker）已能登入外網 DVR、
讀設備資訊與頻道、取即時 H.265 影像、查詢錄影、取得歷史錄影串流，並以 VideoToolbox 硬體解碼成畫面。**macOS App（DVR Viewer）已在實體 DVR 上由使用者確認即時畫面與錄影回放正常 → 專案最終驗收標準已達成**（不開 SuperLive Plus、不用 Docker）。錄影下載（MP4，不轉碼）已在兩台實體 DVR 驗證。

協定細節見 `docs/protocol-analysis.md` §0；測試證據見 `docs/test-results.md`。

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
- [ ] 錄影下載含聲音（目前只下載影像）
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
| 2026-10-31 | 顯示使用 VideoToolbox 解碼 → AVSampleBufferDisplayLayer（DisplayImmediately） | 同一份解碼結果可直接截圖；回放節奏由 PlaybackStreamPlayer 依 FILETIME 控制 |

## 安全注意

- DVR 登入密碼經 **明文 HTTP**（Base64）傳送到外網 8083，這是 DVR 自身設計。建議日後改經 VPN 連線，或確認路由器僅允許必要來源。
