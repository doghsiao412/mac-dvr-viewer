# 協定分析報告

> 狀態：**已確定主要協定並在實體 DVR 驗證**（2026-10-30/31）。✅ = 實體 DVR 驗證；⏳ = 尚未驗證。

## 0. 結論（實測）

目標 DVR：TVT **TD-2716NE-HC**（16 路類比 AHD/TVI/CVI + 8 路 IP，NVMS-9000 平台，韌體 `1.3.8.47575B211101`，
devType=3，時區 CST-8），經網際網路連線（IP 不公開），網頁 Port **8083**，私有協定 Port **6036**（外網皆可連）。
RTSP 554、ONVIF 從外網**不可用**（未轉發／404）；8080 是路由器管理頁（非 DVR，不使用）。

**採用的原生路徑：NVMS-9000 Web API**（DVR 網頁 wasm 播放器使用的同一套協定，前端 JS 公開可讀，不需逆向二進位）：

```
Swift App ── HTTP POST /<指令> (XML) ──────────────▶ DVR :8083   登入、設備資訊、頻道、錄影查詢
          └─ WebSocket /requestWebsocketConnection ─▶ DVR :8083   即時影像、錄影回放（H.265 in SHFL 訊框）
```

不需要 SuperLive Plus、不需要 6036 私有二進位協定、不需要 RTSP。

## 0.1 NVMS-9000 Web API（✅ 實體驗證）

來源：DVR 網頁 `js/lib/Communication.js`、`js/app/login.js`、`js/lib/webSession.js`、`js/app/RecWasm/recWasm.js`。
實作：`mac/Packages/DVRKit/Sources/DVRKit/NVMSClient.swift`。

* 每個指令：`POST http://host:8083/<指令名>`，Body：
  `<?xml version="1.0" encoding="utf-8" ?><request version="1.0" systemType="NVMS-9000" clientType="WEB">…</request>`
  （無參數時 `<request … clientType="WEB"/>`）。回應 `<response><status>success|fail</status><errorCode>…</errorCode><content>…`
* **登入** `doLogin`：`<content><userName><![CDATA[帳號]]></userName><password><![CDATA[Base64(密碼)]]></password></content>`
  → `content/sessionId`（去掉 `{}`）、`userId`、`authGroupId`、`adminName`。
  ⚠️ 密碼只做 Base64，經明文 HTTP 傳送（DVR 網頁本身也是如此）→ 建議日後經 VPN 連線。
* **Session**：之後每個請求帶 `Cookie: sessionId=<id>`；`doLogout` 登出。DVR `autoLogoutWaitTime=60`。
* **錯誤碼**：536870947/536870948 帳密錯誤、536870951 帳號鎖定、536870953 受限、536871011/536870934 Session 逾時、
  536870943 參數錯誤、536870961 無錄影／播放結束。
* 已驗證指令：

| 指令 | 用途 | 結果 |
|---|---|---|
| `doLogin` / `doLogout` | 登入／登出 | ✅ |
| `querySystemCaps` | 能力（analogChlCount=16、ipChlMaxCount=8、previewMaxWin=25、playbackMaxWin=8…） | ✅ |
| `queryBasicCfg` | 型號、韌體、名稱、時區相關 | ✅ |
| `queryTimeCfg` | DVR 時間、時區 CST-8、NTP | ✅ |
| `queryNodeList`（nodeType=chls） | 頻道：`content/item[@id]`、`name`、`chlIndex`(0 起算)、`chlType` | ✅ 16 個頻道，ID `{0000000N-0000-…}` |
| `queryOnlineChlList` | 在線頻道 ID | ✅ 16 在線 |
| `queryChlsExistRec` | 有錄影的頻道 ID | ✅ 12 個 |
| `queryDatesExistRec` | `<condition><chlId>{id}</chlId></condition>` → 有錄影日期 | ✅ 184 天 |
| `queryChlRecLog` | 錄影區段，見下 | ✅ |
| `createRecBackupTask` | 由 DVR 備份到 DVR 端路徑（USB）— **不用於下載** | 未使用 |

* `queryChlRecLog` 條件（時間為 **DVR 本地時間**，不轉 UTC）：
  ```xml
  <types><recType><enum>MOTION</enum><enum>SCHEDULE</enum><enum>SENSOR</enum><enum>MANUAL</enum><enum>INTELLIGENT</enum><enum>POS</enum></recType></types>
  <requireField><chl/><recList><item><recType/><startTime/><endTime/><size/></item></recList></requireField>
  <condition><startTime>2026-10-29 00:00:00</startTime><endTime>2026-10-29 23:59:59</endTime>
    <recType type='list'><itemType type='recType'/><item>MOTION</item>…</recType>
    <chl id='{00000001-…}'></chl></condition>
  ```
  回應 `content/recList/item`：`recType`、`recSubType`、`startTime`、`endTime`、`size`（MB）。
  （用 `<chlId>` 取代 `<chl id>` 會回 536870953。）

## 0.2 WebSocket 串流（✅ 實體驗證）

來源：`js/lib/websocket.cmd.js`、`js/lib/WasmPlayer/downloader.js`、`decoder.js`、`wasm-player.js`。
實作：`mac/Packages/DVRKit/Sources/DVRKit/NVMSStream.swift`。

1. `ws://host:8083/requestWebsocketConnection?sessionID=<sessionId>`
2. 設備先送文字 `{"url":"/device/create_connection#response","data":{"code":0}}`
3. 客戶端送 JSON：`{"url":…,"basic":{"ver":"1.0","time":ms,"id":遞增,"nonce":亂數},"data":{…}}`，設備回 `<url>#response`

| 指令 url | data | 說明 |
|---|---|---|
| `/device/preview/open` | `task_id`(`{guid}`)、`channel_id`、`stream_index`（**1 主／2 子**）、`audio` | 即時 ✅ |
| `/device/preview/close` | `task_id` | |
| `/device/playback/open` | `task_id`、`channel_id`、`start_time`/`end_time`（Unix 秒）、`stream_index`（**0 主／1 子**）、`type_mask`（manual/schedule/motion/sensor…） | 回放 ✅ |
| `/device/playback/refresh_play_index` | `task_id`、`play_frame_index` | **流量控制**：每 8 個訊框回報一次；不回報設備約 15 個訊框後停送 ✅ |
| `/device/playback/key_frame` / `all_frame` | `task_id`、`frame_time`（"yyyy-MM-dd HH:mm:ss:S" UTC） | >4 倍速改只送關鍵幀 ⏳ |
| `/device/playback/seek` | `task_id`、`frame_time` | 網頁實作跳轉是「close + 以新 start_time 重開」 ⏳ |
| `/device/playback/close` | `task_id` | |
| `/device/preview/audio/open` 等 | | 音訊 ⏳ |
| `/device/state_info/subscribe` | `channel_state_info`、`alarm_state_info` | 頻道／警報狀態推播 ⏳ |

* 暫停＝停止回報 `refresh_play_index`；繼續＝再回報；倍速＝客戶端控制顯示速度；逐格＝解碼一格。
* **二進位訊框**（little-endian）：`u32[0]`==0 → 外層標頭 8 bytes，否則 16；`u32[4]` = JSON 長度；
  JSON：`{"url":"/device/preview/data"|"/device/playback/data","data":{"task_id":…,"live_stream_data"|"playback_stream_data":"偏移,長度"}}`；
  媒體 = `buf[hdr + jsonLen + 偏移 ..< +長度]`。

### SHFL 媒體訊框（✅ 由實測資料推得）

```
0   "SHFL"
4   u8 ver=3 | u8 1 | u8 ? (即時=2、回放=7) | u8 keyframe(1/0)
8   u32 = 1，其後 0 至 24
24  u32 dataLen = 總長 - 44
28  u64 FILETIME（100ns since 1601，UTC）擷取時間 → 換算正確
36  u32 即時：毫秒計數；回放：訊框序號（1,2,3…，用於 refresh_play_index）
40  u32 0
44  u8 ? | u8 extLen(關鍵幀 0x0c，否則 0) | u8 ? | u8 ?
48  u32 影像長度（= 總長 - 68 - extLen）
52  u64 FILETIME、60 u64 FILETIME
68  [extLen bytes：u32 0x100 | fourcc "HEVC" | u16 寬 | u16 高]（僅關鍵幀）
68+extLen  H.265 Annex-B（00 00 00 01 + VPS/SPS/PPS/IDR 或 TRAIL）
```

* 頻道 1：子串流（index 2）H.265 1280×720 約 25 fps、約 90 kbps；主串流（index 1）同解析度、關鍵幀約 2 倍大、5 秒僅 18 幀（低幀率，原因待確認）。
* VideoToolbox 可直接硬體解碼（VPS/SPS/PPS 來自關鍵幀，其餘 NAL 轉 4-byte 長度前綴）✅
* 先前「start code 在偏移 21/45」是分析腳本在標頭內誤判；所有訊框影像皆從 68+extLen 開始 ✅。offset 44 偶爾為 0x04（用途未知，不影響解碼）。

## 0.3 6036 私有協定（觀察，未採用）

連線後設備主動送 64 bytes `head`（devType=3、productType=0x2000、protocolVer=6、encryptType=0、loginEncrypt=0）
接著 `1111` + 長度 0 的心跳，與 2BAD/tvt IPC dissector 框架一致。SuperLive Plus 應是走這條（`ServerNVMS9000`）。
Web API 已涵蓋所需功能，故不實作；保留為備案。

**SuperLive Plus 實際連線（`slp-watch.sh`，2026-10-30，不需 sudo）**：開啟 App 後立即建立並持續保持：
* `DVR:6036`（TCP，NVMS-9000 私有協定）與 `DVR:6033`（TCP，用途待確認，推測為另一條資料／串流通道）— 區網外直連，**未經雲端中轉**
* 另一個外部 IP 的 `:6036`（推測為 SuperLive Plus 清單中的第二台設備）
* TVT 雲端：`47.88.x.x:7010/7023`、`47.241.x.x:443`（短暫連線，推測為帳號／推播／NAT 服務）
* 每秒開關一次、未連線的 UDP socket（推測為區網設備搜尋）
* SuperLive Plus **不使用** 8083 網頁 API；本專案改用 8083 是因為協定公開且功能完整。

## 1. 資料來源

| 來源 | 內容 | 取得方式 |
|---|---|---|
| [2BAD/tvt](https://github.com/2BAD/tvt)（MIT，commit `a56afd9`，2026-10-26） | TypeScript FFI 包裝、Wireshark Lua dissector、原廠 C 標頭、原廠 SDK 手冊與 Demo | `git clone --depth 1`（只放在 scratchpad，未納入本 repo） |
| SuperLive Plus 1.16.7（`com.pengantai.superliveplus`，iPad App 於 Apple Silicon 執行） | 主程式靜態字串（類別名稱、XML 範本、命令名稱） | `strings` 唯讀讀取；未解密、未修改、未注入 |
| DVR 網頁前端（`http://DVR:8083/js/...`） | NVMS-9000 Web API 與 WebSocket 播放協定的 JS 原始碼 | `curl` 讀取公開靜態檔（存 scratchpad，未納入 repo） |
| 實體 DVR 連線 | `dvr_probe.py` 探測、`dvrcli` 實際登入／串流 | 見 `docs/test-results.md` |
| SuperLive Plus 封包 | 未擷取（Web API 已足夠，暫不需要） | `tools/capture.sh` + `tools/pcap_analyze.py` |

## 2. TVT 協定家族（由原始碼與字串證實）

SuperLive Plus 主程式內含多套設備協定實作（Objective-C 類別名稱）：

| 類別 | 推測對象 | 證據 |
|---|---|---|
| `ServerDVR3` | 舊款 DVR（DVR3 協定） | `-[ServerDVR3 ParsePlaybackSearchResult:Length:]` |
| `ServerNVMS9000` | NVMS-9000 平台的 NVR／新款 DVR | `OnParserChannelListInfo`、`OnParserRecDatesReply`、`RequestPlaybackData` |
| `ServerAccoutN9000` | 透過雲端帳號／P2P（NatClient）連到 N9000 設備 | `NatClientProtocalDelegate_*`、`connetDeviceWithDeviceId:` |
| `ServerIPcamera` | TVT IP 攝影機（9008 IPC 協定） | `ParseLoginReturn:`、`SearchByTime:endTime:eventArray:` |

**結論**：DVR 屬於哪一族要看實際封包。這會決定 Swift 原型要實作哪套協定，是 Phase 1 最重要的待驗證項目。

### 2.1 TVT IPC 協定（9008，Wireshark dissector 已公開）

由 `proto/ipc.lua` 與 `proto/struct/*.lua` 證實：

```
連線後設備送出 CMD_INIT（64 bytes，開頭 ASCII "head"）：
  flag "head" | devType u32 | productType u32 | protocolVer u32 | configVer u32 | id u32
  | encryptType u32 | encryptParam[4] | mac[8] | softwareVer u32
  | loginEncrypt u8 | loginNonce[3] | supportSoftEncrypt u32 | transportEncryptType u8 | reserved[11]

一般訊息（little-endian）：
  "1111"(4) | cmdLen u32 | cmd u32 | cmdId u32 | cmdVer u32 | dataLen u32 | data[dataLen]
  cmd 高位 0x01000000 = 回覆方向；cmdLen=0 為心跳

CMD_REQUEST_LOGIN (0x101) data：
  connectType u32 | username[32] | password[32] | computerName[28] | ip[8] | mac[6]
  | productType u8 | reserved u8 | protocolVer u32
  （password 欄位是否經 loginNonce/encryptType 加密 → ⏳ 需封包驗證；helpers/xor.ts 顯示有 XOR 運算）

CMD_REPLY_LOGIN_SUCC (0x1000101)：設備能力（PTZ、串流數、音訊、軟體版本、裝置名稱 34 bytes…）
CMD_REQUEST_STREAM_START (0x201) / CMD_REPLY_LIVE_STREAM (0x1000C01)：即時串流
CMD_REQUEST_DATA_SD_SEARCH_EVENT (0x904) / CMD_REQUEST_PLAY_EVENT_STREAM (0x906)：SD 卡錄影
CMD_HTTP_REQUEST (0x1010D00)：在私有通道內傳送 HTTP 式 XML 設定請求
```

### 2.2 NVMS-9000 協定（NVR／新款 DVR，常見 Port 6036）

由 SuperLive Plus 字串證實的事實：

* 設定／查詢使用 XML：`<request version='1.0' systemType='NVMS-9000' clientType='MOBILE' url='...'>`
* 已見指令名：`doLogin`、`multipRequestCmd`（一次送出 `doLogin`+`queryBasicCfg`+`queryNodeList`+`querySystemCaps`）、
  `queryNodeList`（nodeType=chls，頻道清單）、`queryOnlineChlList`、`queryDevList`、`queryNodeEncodeInfo`（主／子串流參數）、
  `queryDatesExistRec`（有錄影的日期）、`queryTimeCfg`、`querySystemCaps`
* 錄影搜尋條件 XML：`<queryCondition><condition><startTime>…<endTime>…<startTimeUtc>…<recType><item>schedule|manual|motion|sensor|…`
* 串流／回放使用二進位命令（ECMS）：
  `ECMS_CMD_REQUEST_LIVE_STREAM_START/STOP`、`ECMS_CMD_PLAY_STREAM_DATA`、
  `ECMS_CMD_REQUEST_REC_DATA_PLAY/STOP`、`ECMS_CMD_REQUEST_REC_INDEX`、`ECMS_CMD_REQUEST_REC_EVENT_SEARCH`、
  `ECMS_CMD_REQUEST_REC_DATA_BACKUP`（錄影備份＝下載）、`ECMS_CMD_REQUEST_REC_CANCEL_REWIND`、`ECMS_CMD_REQUEST_REC_CLOSE_ONLY_KEY_FRAME`
* 回放控制：`-[RemotePlayback RequestREWPlaybackData:speed:…]`、`-[RemotePlayer changeFFRemotePlaybackSpeed:]`、
  `RequestPlaybackData:BeginTime:EndTime:streamID:streamType:EventMask:`

⏳ 未知、需封包驗證：二進位封裝標頭格式、登入密碼雜湊／加密方式、Session 維持（心跳）、
串流訊框標頭（時間戳、I/P 幀、編碼類型）、回放倍速與跳轉的實際命令參數。

### 2.3 原廠 NET_SDK API（C 標頭，可作為 Swift 介面設計參考）

| 功能 | 原廠函式 | Swift 實作方向 |
|---|---|---|
| 登入 | `NET_SDK_Login(ip, port, user, pass, &deviceInfo)` | 依封包結果實作 |
| 頻道 | `NET_SDK_GetDeviceInfo`、`NET_SDK_GetDeviceIPCInfo` | NVMS XML `queryNodeList` 或 IPC 能力 |
| 即時影像 | `NET_SDK_LivePlay` + `LIVE_DATA_CALLBACK(NET_SDK_FRAME_INFO, buffer)` | RTSP 優先；否則私有串流 |
| RTSP URL | `NET_SDK_GetRtspUrl(user, ch, streamType, url)` | **代表設備端有 RTSP 服務** ⏳ |
| 錄影日期 | `NET_SDK_GetNvrRecordDays` | `queryDatesExistRec` |
| 錄影搜尋 | `NET_SDK_FindFile`/`FindNextFile` → `NET_SDK_REC_FILE{channel, locked, start, stop, recType, partition, fileIndex}` | 私有協定 |
| 回放 | `NET_SDK_PlayBackByTime` + `NET_SDK_PlayBackControl(PAUSE/FF/REW/RESUME/STOP/FRAME/NORMAL/SETPOS)` | 私有協定 |
| 下載 | `NET_SDK_GetFileByTimeExV2(…, recFormat, bFirstStream, callback)` | 私有協定，下載後以 AVFoundation 封裝為 MP4 |

`NET_SDK_FRAME_INFO`：`deviceID, channel, frameType, length, keyFrame, width, height, frameIndex, frameAttrib, streamID, time(int64), relativeTime(int64)`
— 私有串流的每個訊框大概會帶有類似欄位 ⏳。

## 3. 標準協定候選（⏳ 待 `tools/dvr_probe.py` 驗證）

| 協定 | 預期 | 用途 |
|---|---|---|
| RTSP 554 | TVT NVR 常見 URL：`rtsp://IP:554/chID=1&streamType=main&linkType=tcp`（sub＝子串流） | Live View（最簡單、最穩定的原生路徑） |
| ONVIF（HTTP 80） | Profile S（即時）可能支援；Profile G（錄影回放）TVT DVR 多半**不支援** | 頻道／串流 URI 探索 |
| HTTP Web | NVMS-9000 Web 介面（XML over HTTP） | 設定查詢、可能可查錄影 |

## 4. 實測紀錄

詳見 `docs/test-results.md`。原始串流資料只存在本機 `captures/`。

| 測試 | 日期 | 結果 |
|---|---|---|
| dvr_probe（外網，未驗證） | 2026-10-30 | ✅ 6036 送 `head`；8083 為 DVR 網頁；554/80/ONVIF 不可用 |
| 登入／設備資訊／頻道 | 2026-10-30 | ✅ `dvrcli survey` |
| 即時影像（WebSocket） | 2026-10-30 | ✅ H.265 子串流 |
| 錄影日期與區段 | 2026-10-31 | ✅ |
| 錄影回放（含流量控制） | 2026-10-31 | ✅ 8 秒取得 153 秒錄影 |
| SuperLive Plus 封包 A–D | — | 暫不需要 |
