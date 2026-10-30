# 測試結果

規則：明確標示 **Mock** 與 **實體 DVR**。只有實體 DVR 測試成功才算功能完成。

## Phase 1 工具測試

| 日期 | 測試 | 類型 | 結果 | 說明 |
|---|---|---|---|---|
| 2026-10-30 | `tools/tests/test_pcap_analyze.py` | Mock（合成 pcap） | ✅ 12/12 | 辨識 RTSP、SDP H264、RTP interleaved、TVT IPC 登入／回覆、H.264／H.265 NAL、NVMS XML；密碼、token、session、nonce、Digest response 皆已遮蔽，保留 Digest realm |
| 2026-10-30 | `dvr_probe.py` 對本機 Mock RTSP（Digest） | Mock | ✅ | OPTIONS 200 → DESCRIBE 401 → Digest 驗證 → 200 + SDP（H265）、子串流 200；報告中無密碼 |
| 2026-10-30 | `dvr_probe.py 127.0.0.1` | 本機冒煙測試 | ✅ | 所有 Port 關閉時能正常結束 |

## Phase 2 Swift 單元測試

| 日期 | 測試 | 類型 | 結果 |
|---|---|---|---|
| 2026-10-30 | `swift test`（NVMSFrameTests：8/16 bytes 外層標頭、H.264/H.265 偵測、錯誤碼） | Mock | ✅ 3/3 |
| 2026-10-31 | `swift test`（VideoDecoderTests：VideoToolbox 編碼合成畫面 → SHFL → 解析 → 硬體解碼，H.265 與 H.264；關鍵幀前等待） | Mock（合成畫面，無監視影像） | ✅ 全部 6/6 |

## 實體 DVR 驗證（TD-2716NE-HC，經網際網路連線，網頁 Port 8083）

工具：`mac/Packages/DVRKit` 的 `dvrcli`（Swift 6、URLSession HTTP + URLSessionWebSocketTask，無第三方套件）。

| # | 項目 | 結果 | 使用技術 | 實測說明 | 未解決 | 對後續影響 |
|---|---|---|---|---|---|---|
| 1 | 建立 DVR 連線 | ✅ 實體 | HTTP :8083 | 外網直連，無需 SuperLive／雲端 | 明文 HTTP | 建議 VPN；App 需支援自訂 Port |
| 2 | 帳密登入 | ✅ 實體 | `doLogin`（Base64 密碼）→ sessionId Cookie | 一次成功；結束 `doLogout` | Session 逾時重登 | ConnectionManager 需處理 536871011 自動重登 |
| 3 | 設備資訊 | ✅ 實體 | `querySystemCaps`/`queryBasicCfg`/`queryTimeCfg` | 型號、韌體、16+8 路、時區 CST-8 | — | 設備狀態頁可直接使用 |
| 4 | 頻道清單 | ✅ 實體 | `queryNodeList`、`queryOnlineChlList`、`queryChlsExistRec` | 16 頻道全部在線，12 個有錄影 | — | 頻道 ID 為 GUID，App 以 ID 為主鍵 |
| 5 | 單頻道即時影像 | ✅ 實體 | WebSocket `/device/preview/open` | 子串流（index 2）約 25 fps；主串流（index 1）5 秒 18 幀、關鍵幀約 2 倍大；兩者皆 H.265 1280×720 | 主串流低幀率原因未確認（`mainStreamLimitFps`？`queryNodeEncodeInfo` 回 536870953） | 多分割用子串流；放大可切主串流 |
| 6 | 解碼 | ✅ 實體 | SHFL 解析 → VideoToolbox HEVC（硬體解碼，NV12） | 離線：即時 116/116、回放 1224/1224 幀 0 錯誤；即時主串流截圖 30/30 幀；平均 0.8–4.6 ms/幀；截圖亮度統計正常（標準差 60–67，非灰/綠畫面） | 「顯示」尚未做（需 App 介面）；截圖由使用者自行目視確認 | 多路解碼負擔低；下一步 AVSampleBufferDisplayLayer |
| 7 | 查詢指定日期錄影 | ✅ 實體 | `queryDatesExistRec`、`queryChlRecLog`（本地時間、`<chl id>`） | 184 天有錄影；10/29 頻道 1 有 3 段 SCHEDULE | 事件類型篩選未細測 | 時間軸可直接繪製 |
| 8 | 播放一段錄影 | ✅ 實體（資料層） | WebSocket `/device/playback/open` + `refresh_play_index` | 10/29 12:00 起：8 秒收到 1224 訊框（153 秒錄影，21 個關鍵幀），從 11:59:58 關鍵幀開始 | seek／倍速／暫停未測；尚未解碼顯示 | 傳輸遠快於即時 → 播放需客戶端控速 |
| 9 | 下載一段錄影 | ⏳ | （規劃）快速回放 → AVAssetWriter MP4（不轉碼） | 第 8 項證明可快速取得原始 H.265 | 尚未封裝 | 下一步 |

另：一次測試程式卡住被強制結束，未登出；Session 依 DVR 設定約 60 秒後逾時，之後的登入都正常。

## 播放器控制（DVRKit，`dvrcli playertest`，實體 DVR）

| 日期 | 測試 | 結果 |
|---|---|---|
| 2026-10-31 | LiveStreamPlayer 子串流 4 秒 | ✅ 97 幀（約 24 fps） |
| 2026-10-31 | LiveStreamPlayer 切換主串流 | ✅ 自動重連；主串流 4 秒 3 幀（約 1 fps，DVR 端限制） |
| 2026-10-31 | 回放 1x | ✅ 錄影本身為 8 fps；3 秒前進 3.0 秒 |
| 2026-10-31 | 暫停 2 秒 | ✅ 停止（僅多 1 幀） |
| 2026-10-31 | 2x | ✅ 3 秒前進 6.2 秒 |
| 2026-10-31 | 8x（key_frame 模式） | ✅ 可運作；節奏依 DVR 送出的關鍵幀間距，需在 App 實際觀察 |
| 2026-10-31 | 跳轉到 1 小時後 | ✅（修正前 ❌：舊串流關閉誤判新串流結束，已以 generation 隔離） |
| 2026-10-31 | 逐格 ×5 | ✅ 5 幀，每格約 0.12 秒 |

## macOS App

| 日期 | 測試 | 類型 | 結果 |
|---|---|---|---|
| 2026-10-31 | `xcodebuild` Debug 編譯 | 建置 | ✅ 0 錯誤 0 警告 |
| 2026-10-31 | 啟動 App（無設備） | 冒煙 | ✅ 正常執行、無當機報告 |
| 2026-10-31 | 加入實體 DVR 後 Live／Playback 畫面 | 實體（使用者確認） | ✅ 即時畫面與錄影回放皆正常 |
| 2026-10-31 | 拖曳式時間軸（中央播放線、拖曳跳轉、捏合／滾輪縮放） | 實體（使用者確認） | ✅ 操作順手 |
