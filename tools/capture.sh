#!/bin/zsh
# 抓取 Mac ↔ DVR 之間的封包（需要 sudo，請由你本人在終端機執行）
#
# 用法：
#   sudo tools/capture.sh <DVR 主機 IP> <標籤> [--wide]
#   例如：sudo tools/capture.sh 192.168.1.100 testA-login
#
# 預設只抓與 DVR 主機之間的封包（filter: host <IP>）。
# --wide：同時抓 Mac 的其他流量（排除 443/HTTPS），用來確認 App 是否透過雲端/P2P 伺服器中轉。
# 輸出：captures/<時間>-<標籤>.pcap（權限 600，擁有者改回你的帳號）。按 Ctrl-C 結束。
# 封包檔只留在本機，已被 .gitignore 排除。

set -euo pipefail
host="${1:-}"; label="${2:-}"; mode="${3:-}"
if [[ -z "$host" || -z "$label" ]]; then sed -n '2,12p' "$0"; exit 1; fi
if [[ $EUID -ne 0 ]]; then echo "需要 sudo：sudo $0 $*"; exit 1; fi

cd "$(dirname "$0")/.."
owner="${SUDO_USER:-$(stat -f %Su .)}"
iface="$(route -n get "$host" 2>/dev/null | awk '/interface:/{print $2}')"
iface="${iface:-en0}"
mkdir -p captures; chmod 700 captures; chown "$owner" captures
out="captures/$(date +%Y%m%d-%H%M%S)-${label}.pcap"

if [[ "$mode" == "--wide" ]]; then
  filter="host $host or (not port 443 and not port 5353 and not arp)"
else
  filter="host $host"
fi

echo "介面：$iface"
echo "過濾：$filter"
echo "輸出：$out"
echo "現在請操作 SuperLive Plus，完成後按 Ctrl-C。"

cleanup() {
  [[ -f "$out" ]] && { chown "$owner" "$out"; chmod 600 "$out"; }
  echo; echo "已儲存：$out"
  echo "分析：python3 -I tools/pcap_analyze.py $out --dvr $host"
}
trap cleanup EXIT
# -s 0 完整封包；-U 即時寫入；-n 不反查 DNS
tcpdump -i "$iface" -s 0 -U -n -w "$out" "$filter"
