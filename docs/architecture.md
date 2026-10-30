# 架構設計

> 狀態：設計草案（Phase 1）。協定層的具體實作要等封包驗證後才決定，見 `protocol-analysis.md`。

## 1. 原則

* Mac App **直接**連 DVR：SwiftUI → 原生網路層 → DVR。不用 Docker、Node、Electron、常駐伺服器。
* 混合式通訊：能用標準 RTSP 的就用 RTSP（Live View），錄影搜尋／回放／下載用 TVT 私有協定。
* 優先 Apple 原生框架；第三方程式庫要說明用途、授權、維護狀態與替代方案。
* 不轉碼：H.264/H.265 直接送 VideoToolbox 硬體解碼；下載用 AVAssetWriter passthrough。
* 主執行緒只做 UI；網路與解碼都在 actor／背景佇列。

## 2. 模組

```
DVRViewer.app (SwiftUI + AppKit)
│
├─ App UI ─────────── NavigationSplitView、LiveGrid、PlaybackTimeline、Settings、多視窗
│      │ (@Observable view models, MainActor)
├─ DeviceManager ──── 已儲存的 DVR 清單、狀態、頻道別名與排序（持久化：JSON in Application Support）
├─ CredentialStore ── Keychain Services（kSecClassGenericPassword；service=com.dvrviewer.device）
├─ ConnectionManager  每台 DVR 一個 actor：登入、Session、心跳、自動重連（指數退避）、共享控制連線
│      │
│      └─ ProtocolClient (protocol)
│             ├─ RTSPClient ........ Network.framework；RTSP over TCP、Digest；RTP 解封裝（H.264 RFC 6184 / H.265 RFC 7798）
│             ├─ TVTNVMSClient ..... ⏳ NVMS-9000 私有協定（XML 指令 + ECMS 二進位串流）
│             ├─ TVTIPCClient ...... ⏳ 9008 IPC 協定（若 DVR 屬此族）
│             └─ ONVIFClient ....... 選用：裝置資訊、Profile、StreamUri
│
├─ StreamManager ──── 依視窗大小選主／子串流、引用計數共享同一路串流、離線偵測與恢復
├─ VideoDecoder ───── VTDecompressionSession（硬體），參數集變更時重建
├─ VideoRenderer ──── AVSampleBufferDisplayLayer（NSViewRepresentable 包裝），數位縮放、比例控制
├─ PlaybackManager ── 錄影日期 / 區段查詢、時間軸模型、播放／暫停／跳轉／倍速／逐格
├─ ExportManager ──── 時間區間下載 → AVAssetWriter（MP4/MOV passthrough）、進度、取消
└─ Settings ───────── 偏好設定（預設串流、版面、快捷鍵）
```

### 媒體資料流

```
NWConnection ─▶ ProtocolClient（解析訊框）─▶ AsyncStream<EncodedFrame>
   EncodedFrame { codec(h264/h265), nalUnits, pts, isKeyframe, channel, streamType }
        └▶ VideoDecoder（CMSampleBuffer）─▶ AVSampleBufferDisplayLayer
        └▶ ExportManager（AVAssetWriter，不解碼）
```

`EncodedFrame` 是 RTSP 與私有協定共用的介面，讓上層不在乎影像來源。

## 3. 生命週期與資源管理

* 每台 DVR 的 `ConnectionManager` 是 actor；UI 只持有弱參考或 ID。
* 串流以 **lease** 管理：每個顯示畫面取得 `StreamLease`，最後一個 lease 釋放時才關閉 socket（避免重複連線）。
* 每個非同步工作都用 `Task` 綁定 View 生命週期（`.task {}`），View 消失時自動取消 → 關閉連線。
* 解碼器在 App 進入背景／視窗最小化時降級（暫停解碼，只保留連線或關閉子串流）。

## 4. 第三方程式庫評估（目前：**不引入**）

| 候選 | 用途 | 授權 | 評估 |
|---|---|---|---|
| 自寫 RTSP/RTP（Network.framework） | Live View | — | **首選**：TVT RTSP 只需 TCP interleaved + Digest，程式碼量小、可完全控制延遲 |
| FFmpeg（libavformat/libavcodec） | RTSP 解析／特殊封裝 | LGPL 2.1+（需動態連結、注意 GPL 元件） | 備案：若遇到非標準 RTSP 或私有錄影格式 |
| VLCKit | 全功能播放器 | LGPL 2.1 | 不採用：體積大、難以控制解碼路徑與多路效能 |

## 5. 專案結構（實際，2026-10-31）

```
mac/
  DVRViewer.xcodeproj           # 資料夾同步群組；本地套件依賴 Packages/DVRKit
  Config/Info.plist             # ATS 例外（DVR 只有 http/ws）、區網使用說明
  DVRViewer/
    DVRViewerApp.swift          # 主視窗、攝影機視窗（WindowGroup for: CameraRef）、設定、選單快捷鍵
    Model/  AppStore（全域狀態、版面記憶、截圖）· DeviceModel（連線/保活/在線）· DeviceConfig（JSON 持久化）
    Services/ KeychainStore · VideoRenderer（AVSampleBufferDisplayLayer）· PlayerControllers（Live/Playback 生命週期）
    Views/  ContentView · SidebarView · DeviceEditorView · LiveGridView · VideoTile（含攝影機視窗）· PlaybackView · TimelineView · SettingsView
  Packages/DVRKit/
    NVMSClient（HTTP XML）· NVMSStream（WebSocket）· SHFLFrame · VideoDecoder（VideoToolbox）· Snapshot
    DVRConnection（ConnectionManager）· LiveStreamPlayer · PlaybackStreamPlayer
    dvrcli（命令列驗證工具）· Tests（Mock）
```

建置：`xcodebuild -project mac/DVRViewer.xcodeproj -scheme DVRViewer -derivedDataPath mac/build/DerivedData build`

## 5.1 原規劃

```
mac/
  DVRViewer.xcodeproj           # Phase 3
  Packages/DVRKit/              # Swift Package：協定、串流、解碼（可單獨測試）
    Sources/DVRKit/{Protocol,RTSP,TVT,Media,Credentials}
    Sources/dvrcli/             # Phase 2 命令列原型：login / channels / live / search / playback / download
    Tests/DVRKitTests/
tools/                          # Phase 1 分析工具（Python/zsh，僅開發用）
docs/
```
