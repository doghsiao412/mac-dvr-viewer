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
* **錯誤碼**：536870947/536870948 帳密錯誤、536870951 帳號鎖定、536870953 **沒有權限**（舊版網頁 IDCS_NO_PERMISSION）、536871011/536870934 Session 逾時、
  536870943 參數錯誤、536870961 無錄影／播放結束、**536870942／513 沒有錄影資料**（舊韌體 `queryChlRecLog` 當天無錄影時回傳此錯誤，而非空清單）、536870960 設備忙碌。
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
| `queryLog` | 系統日誌（依據 `js/app/System/viewLog.js`）；警報類型 `LOG_ALARM_MOTION`／`LOG_ALARM_SENSOR`／`LOG_ALARM_INTELLIGENT`，時間為 **UTC**，回應 `content@total`、`content/item`（`logType`、`time`、`chl@id`、`triggerRecChls/item@id`），可分頁 `pageIndex`／`pageSize` | ⚠️ 需「日誌」權限，測試帳號回 536870953 |
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

## 0.21 聲音（✅ WebSocket 實體驗證，2026-10-31）

* 要求：開啟影像後送 `/device/preview/audio/open`（回放 `/device/playback/audio/open`）`{task_id}`；關閉為 `…/audio/close`。
  回覆 code `536870944` = 此頻道不支援聲音（網頁 TVTPlayer.handlePlayError）
* 聲音訊框與影像在**同一條串流**，同樣是 SHFL：offset 6 = `0x06`（影像為 0x02 即時／0x07 回放），offset 7 = 1，
  extLen 12，延伸區 `00 01 01 00 | u16 16 | u16 0x3E80 | u32 8000`（第 3 byte = 1 表示聲音，影像關鍵幀為 0），
  資料 320 bytes／訊框（40 毫秒），每秒 25 個
* 編碼：**G.711 A-law、8000 Hz、單聲道**（資料以 0xD5／0x55 靜音值為主）
* 回放：聲音訊框沿用前一個影像訊框的序號（不另外遞增）→ 流量控制只依影像訊框；DVR 從「要求的時間」才送聲音，
  影像則從之前最近的關鍵幀開始
* 8083 全部 16 頻道皆有聲音
* **私有協定聲音**（✅ 2026-10-31，以第三台 DVR 的 SuperLive Plus 封包分析並實測）：
  - `0x505` 的 `<audio>1</audio>` **無效**
  - 即時：`0x501`（路由 op=1，目標＝頻道 GUID，**獨立的聲音任務 GUID**）開啟；`0x502`（op=2，同任務）關閉；
    內容 76 bytes：u32 頻道編號(1 起) @0、u32 6 @68、u32 3 @72。聲音訊框同樣以 `0x6/0x10001` 送達（SHFL offset 8 = 頻道）
  - 回放：`0x803` offset 84 = **3**（含聲音）；聲音訊框混在 `0x20006` 回放串流中，**offset 6 與影像相同為 7**，需以延伸區第 3 byte = 1 辨識
  - 關閉即時影像 `0x502` 的 offset 0 應為頻道編號（原本寫死 1，已修正）

## 0.25 第二台 DVR（網頁 Port 8082，舊韌體）— 2026-10-31

* 同為 NVMS-9000，但網頁版本 `20191212.01`（8083 那台為 `20210528.01`）
* `js/lib/websocket.cmd.js` 回 **404**、無 `liveWasm`／`recWasm` 路由 → **不支援 WebSocket 影像串流**；網頁只能靠瀏覽器外掛（OCX/NPAPI）看影像
* HTTP XML API 可用：`doLogin` ✅、`queryNodeList` ✅、`queryChlRecLog` ✅（10/30 頻道 1 有 7 段 MOTION）
* 外掛影像 Port 取自 `queryUPnPCfg` 的 `portType=SERVICE`（內部 6036）；外網轉發推測為 **6033**
  （SuperLive Plus 同時連 `DVR:6036` 與 `DVR:6033`；兩者皆送 `head`，softwareVer 欄位不同：6033=`00080301`、6036=`00060301`，對應關係待登入確認）
* App 處理：以 `HEAD /js/lib/websocket.cmd.js`（404/200）判斷，不支援時顯示說明、不重試連線
* ✅ 已實作 6036 私有協定（見 §0.4），即時與回放皆可用
* 外網對應更正：**8082 DVR → 外網 6036**（softwareVer 00060301 = 1.3.6），**8083 DVR → 外網 6033**
* ✅ 2026-11-01 `queryUPnPCfg`（唯讀）確認：**6033 是 8083 DVR 本身的 SERVICE Port**（`localPort`=6033，`externalPort`=6033；HTTP 也是 local 8083），不是路由器把 6036 轉成 6033。8082 DVR 為 HTTP 8082／SERVICE 6036。兩台 UPnP 皆關閉（`switch`=false，status `ineffective`），路由器以同號轉發。
  → 影像服務 Port 可在登入後由 `queryUPnPCfg` 的 `portType=SERVICE` `localPort` 取得（前提：路由器同號轉發）

## 0.4 TVT NVMS-9000 私有協定（SERVICE Port 6036）— ✅ 實體驗證（2026-10-31）

用於**不支援 WebSocket 的舊韌體**（8082 那台：TD-2716TE-HC，韌體 1.3.6 / 2020-05）。
來源：SuperLive Plus 封包（`tools/capture.sh` + `tools/re/tvt_frames.py`），實作：`DVRKit/TVTPrivateClient.swift`。
App 依 DVR 是否提供 `js/lib/websocket.cmd.js` 自動選擇 WebSocket 或本協定。

**框架**（little-endian）
```
"1111" | u32 len | body(len)                    一般訊息
"1111" | 00000000                               心跳（雙方約每 5 秒）
"1111" | FFFFFFFF | u32 id | u32 分段數 | u32 總長 | u32 第幾段(1起) | u32 本段長度(≤65504) | u32 0 | 資料
                                                分段訊息（> 約 64 KB，例如大關鍵幀），依 id 組合
"head" + 60 bytes                               連線後設備主動送出（devType=3、protocolVer=6、loginEncrypt=0）
body = u32 cmd | u32 sub | u32 id | u32 dataLen | [路由區塊 72] | data(dataLen)
```
* cmd：`0x01000003` 直接請求、`0x01020003` 路由請求（帶路由區塊）；回覆把 `…03` 換成 `…06`、`sub |= 0x10000000`，id 相同
* `0x00000006 / 0x00010001`：即時 SHFL（SHFL offset 8 = 頻道序號，1 起）；`0x00000006 / 0x0A01–0A03`：狀態通知
* `0x00020006 / 0x00020001`：回放 SHFL（含路由區塊，任務 GUID 在 data[52:68]，SHFL 從 data[72] 起）；`/0x00020002`：回放結束
* **路由區塊**：`GUID 請求(隨機) | GUID session | GUID 目標 | u32 2 | GUID 任務 | u32 op`
  目標：即時＝頻道 GUID（`{00000001-…}`），回放＝設備 GUID；GUID 為 Windows 排列（前三段 little-endian）

| sub | 種類 | 內容 | 驗證 |
|---|---|---|---|
| `0x101` | 直接 | **登入**：data 236 bytes：u32 3 @0、帳號 @36（64）、**密碼明文** @100（64）、u32 0xCD @200。回覆 sub `0x10000101` 成功：設備 GUID @0、session GUID @84 | ✅ |
| `0x91B` | 直接 | **XML 查詢**：帳號(64) + url(64) + NVMS-9000 XML（同 HTTP API）；回覆為 HTTP 文字（含 `Data:` 標頭）＋ XML | ✅ |
| `0x505` | 路由 op 1 | **開啟即時**：XML `<destId>頻道</destId><taskId>{任務}</taskId><chNo>0起</chNo><audio>0</audio><streamType>1主/2子</streamType>`（clientType='SYS'） | ✅ |
| `0x502` | 路由 op 2 | 關閉即時：u32 1 + 72 bytes 0 | ✅ |
| `0x803` | 路由 op 1 | **開啟回放**：88 bytes：u32 開始、u32 結束（Unix 秒）、u16 0xFFFF、u16 頻道數量(1)、**u32 頻道編號（1 起）@12**、u32 7 @80、u16 1 @86。⚠️ 起初誤判為位元遮罩（Camera3 播出 Camera4），已以 16 頻道逐一驗證修正 | ✅ |
| `0x807` | 路由 op 2 | 關閉回放（同上，@86=0） | ✅ |
| `0x808` | 路由 op 5 | **流量控制**：u32 已顯示的訊框序號（SHFL offset 36）；SuperLive 約每 6 幀，本專案每 8 幀 | ✅ |
| `0x80B` | 路由 op 5 | 跳轉：u64 FILETIME + u32 結束 — 本專案改用「關閉後重開」 | 未使用 |
| `0x801` | 直接 | 錄影搜尋（二進位）— 本專案改用 HTTP `queryChlRecLog` | 未使用 |

⚠️ 安全性：登入密碼以**明文**經 TCP 傳送（設備宣告 loginEncrypt=0），比 HTTP 的 Base64 更不安全 → 強烈建議經 VPN。

## 0.3 6036 私有協定（觀察，未採用）

連線後設備主動送 64 bytes `head`（devType=3、productType=0x2000、protocolVer=6、encryptType=0、loginEncrypt=0）
接著 `1111` + 長度 0 的心跳，與 2BAD/tvt IPC dissector 框架一致。SuperLive Plus 應是走這條（`ServerNVMS9000`）。
Web API 已涵蓋所需功能，故不實作；保留為備案。

**SuperLive Plus 實際連線（`slp-watch.sh`，2026-10-30，不需 sudo）**：開啟 App 後立即建立並持續保持：
* `DVR:6036`（TCP，NVMS-9000 私有協定）與 `DVR:6033`（TCP，用途待確認，推測為另一條資料／串流通道）— 區網外直連，**未經雲端中轉**
* 另一個外部 IP 的 `:6036`（推測為 SuperLive Plus 清單中的另一台設備）
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

## 0.5 WebSocket 連線上限（2026-10-31，8083 TD-2716NE-HC）

* DVR 網頁伺服器同時只接受約 6 條 `/requestWebsocketConnection`，第 7 條起 WebSocket 握手失敗；`querySystemCaps` 的 `previewMaxWin` 為 25，限制不在預覽路數。
* 同一條 WebSocket 第二個 `/device/preview/open` 回 536871004（網頁前端也是每個畫面一條 WebSocket）。
* 同一台 DVR 的私有協定（SERVICE Port，外部轉發 6033）在同一條 TCP 上可同時開 16 路即時影像。
* App 做法：`DVRConnection.openLive` 先用 WebSocket；建立失敗（非 DVR 指令錯誤）時記下上限，之後超過上限的畫面改用私有協定；私有協定連不上時 60 秒內不再嘗試。
