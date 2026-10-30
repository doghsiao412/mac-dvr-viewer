# 相容性判斷與環境報告

## 1. 環境報告（2026-10-30 實測）

| 項目 | 結果 |
|---|---|
| 晶片 | Apple M1 Pro（arm64） |
| macOS | 27.2（26B123） |
| Xcode | 27.2（27B52），`xcode-select` → `/Applications/Xcode.app` |
| Swift | 6.4.2 |
| SuperLive Plus | 已安裝：`/Applications/SuperLivePlus.app`（iPad 版，1.16.7.11502，`com.pengantai.superliveplus`） |
| 主要網路 | `en0`（區網 /24）；另有一個 VPN 介面（utun） |
| tcpdump / lsof / nettop | 有（系統內建）；`/dev/bpf*` 僅 root 可讀 → **抓封包需要 sudo** |
| Wireshark / tshark / ffmpeg / nmap | 未安裝（不需要；分析器以純 Python 實作） |
| Homebrew | 有（`/opt/homebrew`） |
| Python | 3.12.13（僅用於分析工具，App 本身為 Swift） |
| SuperLive Plus 資料容器 | 受 macOS 沙盒／TCC 保護，無法讀取（不繞過） |

## 2. TVT SDK 分類（A/B/C/D）

### A. 可從公開原始碼理解並用 Swift 重寫

* TVT IPC 協定（9008）的封包框架：`head` 初始化封包、`"1111"` 訊息標頭、命令碼表、登入請求／回覆結構、HTTP-over-私有通道（`CMD_HTTP_REQUEST`）— 來自 `proto/*.lua`
* 原廠 C 標頭中的資料結構：`NET_SDK_DEVICEINFO`、`NET_SDK_REC_FILE`、`NET_SDK_FRAME_INFO`、`DD_TIME`、回放控制碼 `NET_SDK_PLAYCTRL_*`、錯誤碼表 — 可直接轉成 Swift struct／enum
* API 分層與生命週期（login → live/playback handle → stop → logout → dispose）可作為 Swift Protocol Client 的介面設計

### B. 依賴封閉原廠 SDK、目前無法直接移植

* `libdvrnetsdk.so`、`libNatClientSDK.so`、`libShareLib.so` 為 **Linux x86_64 ELF**，不能在 macOS 載入（也不應嘗試）
* NVR／DVR 專用協定（6036 / NVMS-9000 ECMS 二進位封裝、DVR3）沒有公開的 dissector
* 登入密碼的加密／雜湊細節（`loginEncrypt`、`loginNonce`、`encryptType`）
* P2P／雲端中轉（NatClient、`ServerAccoutN9000`）— 本專案以區網／IP 直連為主，暫不實作

### C. 可用 macOS 原生 API 取代

| 原廠 / 舊方案 | macOS 原生替代 |
|---|---|
| SDK 內部 socket 與重連 | Network.framework `NWConnection` + Swift Concurrency |
| SDK 內建解碼（VideoDecodeSDK） | VideoToolbox `VTDecompressionSession`（H.264/H.265 硬體解碼） |
| SDK 顯示（VideoDisplaySDK、HWND） | `AVSampleBufferDisplayLayer`（可直接吃 CMSampleBuffer，免自繪） |
| 私有錄影格式 / AVI 輸出 | AVFoundation `AVAssetWriter`（H.264/H.265 passthrough → MP4/MOV，免轉碼） |
| 截圖 | `VTDecompressionSession` 輸出 CVPixelBuffer → CGImage → PNG/HEIC |
| 帳密儲存 | Keychain Services |
| RTSP 用戶端 | 自寫輕量 RTSP/RTP（Network.framework）或評估第三方（見 architecture.md） |

### D. 需要實際封包驗證

1. DVR 實際是哪一族協定（DVR3／NVMS-9000／IPC）與 Port
2. RTSP 是否開啟、URL 格式、驗證方式（Digest/Basic）、H.264 或 H.265、主／子串流
3. ONVIF 是否開啟、是否支援 Profile G（錄影搜尋／回放）
4. 私有協定登入流程與密碼處理
5. 頻道清單、錄影日期、錄影區段的傳輸格式
6. 回放串流格式、暫停／跳轉／倍速命令、下載（backup）流程
7. SuperLive Plus 是否走區網直連，還是經雲端 P2P 中轉

## 3. 架構可行性（2026-10-31 實測更新）

| 功能 | 採用路徑 | 可行性 |
|---|---|---|
| 登入／設備資訊／頻道 | NVMS-9000 HTTP XML（:8083） | ✅ 實體驗證 |
| 即時影像 | WebSocket `/device/preview/*`，H.265 Annex-B（SHFL 封裝） | ✅ 資料層實體驗證；解碼 ⏳ |
| 錄影日期／區段 | `queryDatesExistRec`、`queryChlRecLog` | ✅ 實體驗證 |
| 錄影回放 | WebSocket `/device/playback/*` + 流量控制 | ✅ 資料層實體驗證；控制命令 ⏳ |
| 錄影下載 | 快速回放 → AVAssetWriter MP4 | 高（資料已可取得）⏳ |
| RTSP / ONVIF | 外網不可用 | 不採用 |

D 類待驗證項目中，1、2、3、5、6、7 已由 DVR 網頁協定與實測解決；4（6036 登入加密）不再需要。

**最後手段（只有原生直連被充分證實不可行時才考慮）**：在 Apple Virtualization.framework 的 Linux arm64 VM 中，
以 Rosetta for Linux 執行 x86_64 `libdvrnetsdk.so`，由 Mac App 透過本機 socket 呼叫。這違反「不依賴外部伺服器」原則，目前**不採用**。
