# SuperLive Plus 封包分析操作指南（測試 A–D）

所有指令都在專案根目錄執行。輸出檔都在 `captures/`（已被 Git 排除，權限 700/600）。

## 0. 準備（只需一次）

1. **找出 DVR 位址（不需 sudo）**：開一個終端機分頁執行
   ```bash
   tools/slp-watch.sh find-dvr
   ```
   再開啟 SuperLive Plus 並連上 DVR。畫面會列出 App 連線的 `IP:Port`，就是 DVR 位址（或雲端中轉伺服器）。
   看到後按 Ctrl-C。

2. **把 DVR 密碼存進 Keychain**（密碼只在終端機輸入，不經過聊天）：
   ```bash
   tools/dvr-credentials.sh set <DVR_IP> <帳號>
   ```

3. **非破壞性探測**（唯讀：Port 連線、RTSP/HTTP/ONVIF 查詢；帶憑證的請求遇到 401 立即停止）：
   ```bash
   python3 -I tools/dvr_probe.py <DVR_IP> --user <帳號> --extra-port <SuperLive 用的 Port>
   ```

## 1. 抓封包（每個測試一個檔案）

`tcpdump` 需要 root 權限讀 `/dev/bpf`，請**自己**在終端機執行（會要求輸入 Mac 登入密碼）：

```bash
sudo tools/capture.sh <DVR_IP> testA-login
```

開始後操作 SuperLive Plus，完成後 Ctrl-C。建議同時在另一個分頁跑 `tools/slp-watch.sh testA-login` 記錄連線開關時間。

| 測試 | 標籤 | 操作 |
|---|---|---|
| A 登入 | `testA-login` | 先完全結束 SuperLive Plus → 開始抓 → 開 App → 登入 DVR → 停在設備畫面約 30 秒（觀察心跳）→ Ctrl-C |
| B 頻道 | `testB-channels` | 開始抓 → 進入設備的頻道清單／重新整理 → Ctrl-C |
| C 即時 | `testC-live` | 開始抓 → 開 1 個頻道即時影像 10 秒 → 切換主／子串流（高清／流暢）→ 再開 4 分割 10 秒 → Ctrl-C |
| D1 回放 | `testD1-playback` | 開始抓 → 進入回放 → 選日期 → 選頻道 → 播放 10 秒 → 暫停 → 繼續 → 拖曳時間軸跳轉 → 2 倍速 → Ctrl-C |
| D2 下載 | `testD2-download` | 開始抓 → 下載一小段錄影（約 1 分鐘）→ 完成後 Ctrl-C |

若 A 的報告顯示 App 並沒有直接連 DVR（例如只連到外部 IP），請改用 `--wide` 重抓：
```bash
sudo tools/capture.sh <DVR_IP> testA-login-wide --wide
```

## 2. 分析（不需 sudo）

```bash
python3 -I tools/pcap_analyze.py captures/<檔名>.pcap --dvr <DVR_IP> --user <帳號>
```

報告寫在同目錄 `<檔名>.pcap.report.md`。分析器會自動遮蔽 Keychain 中的密碼、XML/JSON 的
password/token/nonce/session、HTTP/RTSP Authorization、URL 帳密、TVT 登入帳密欄位。
完成後告訴 Claude「testA 完成」即可，Claude 只讀取遮蔽後的報告，不讀原始 pcap。

## 3. 安全原則

* 只分析你自己有權使用的 DVR；不掃描網段，不暴力破解
* 不修改 DVR 設定，不刪除錄影
* pcap、報告、截圖只留在本機 `captures/`，不上傳、不提交 Git
* 不停用 SIP；sudo 只用在 `tcpdump`
