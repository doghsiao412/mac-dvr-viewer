#!/bin/zsh
# DVR 憑證管理（存放於 macOS Keychain，不寫入檔案、不出現在指令歷史）
#
# 用法：
#   tools/dvr-credentials.sh set    <host> <username>   # 互動輸入密碼
#   tools/dvr-credentials.sh check  <host> <username>   # 只確認是否存在，不顯示密碼
#   tools/dvr-credentials.sh delete <host> <username>
#
# Keychain 項目：service = DVRViewer.dev，account = <username>@<host>
# 分析工具會從 Keychain 讀取密碼，用來「遮蔽」封包中出現的明文密碼，以及執行 RTSP/ONVIF 驗證。

set -euo pipefail
SERVICE="DVRViewer.dev"

cmd="${1:-}"; host="${2:-}"; user="${3:-}"
if [[ -z "$cmd" || -z "$host" || -z "$user" ]]; then
  sed -n '2,10p' "$0"; exit 1
fi
account="${user}@${host}"

case "$cmd" in
  set)
    echo "請輸入 ${account} 的 DVR 密碼（輸入時不會顯示）："
    # -U：已存在時更新；-w 放最後且不帶值 → security 會安全地互動提示輸入
    security add-generic-password -U -s "$SERVICE" -a "$account" -l "DVR Viewer (dev) ${account}" -w
    echo "已儲存到 Keychain：service=${SERVICE} account=${account}"
    ;;
  check)
    if security find-generic-password -s "$SERVICE" -a "$account" >/dev/null 2>&1; then
      echo "存在：${account}"
    else
      echo "不存在：${account}"; exit 2
    fi
    ;;
  delete)
    security delete-generic-password -s "$SERVICE" -a "$account" >/dev/null && echo "已刪除：${account}"
    ;;
  *)
    sed -n '2,10p' "$0"; exit 1
    ;;
esac
