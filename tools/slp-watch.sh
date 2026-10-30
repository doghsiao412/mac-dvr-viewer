#!/bin/zsh
# 監看 SuperLive Plus 的網路連線（不需要 sudo）
#
# 用法：tools/slp-watch.sh [標籤]
#   例如：tools/slp-watch.sh testA-login
#
# 每秒以 lsof 讀取 SuperLivePlus 程序的 socket，新增或關閉的連線會即時列出，
# 並寫入 captures/<時間>-<標籤>/connections.log。按 Ctrl-C 結束。
# 只記錄 IP/Port/協定/狀態，不讀取任何內容。
# 預設略過未連線的 UDP socket；要全部顯示：SLP_WATCH_ALL=1 tools/slp-watch.sh

set -uo pipefail
cd "$(dirname "$0")/.."
label="${1:-watch}"
outdir="captures/$(date +%Y%m%d-%H%M%S)-${label}"
mkdir -p "$outdir"; chmod 700 captures "$outdir"
log="$outdir/connections.log"

find_pid() { pgrep -x SuperLivePlus | head -1; }

pid="$(find_pid)"
if [[ -z "$pid" ]]; then
  echo "等待 SuperLive Plus 啟動…（請開啟 App）"
  while [[ -z "$pid" ]]; do sleep 1; pid="$(find_pid)"; done
fi
echo "SuperLivePlus PID=$pid，記錄到 $log（Ctrl-C 結束）"
echo "# start $(date '+%F %T') pid=$pid label=$label" >> "$log"

typeset -A seen
while true; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "$(date +%T) SuperLive Plus 已結束" | tee -a "$log"; break
  fi
  typeset -A now
  now=()
  # 欄位：COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME [STATE]
  while IFS= read -r line; do
    proto=$(echo "$line" | awk '{print $8}')
    name=$(echo "$line" | awk '{print $9}')
    state=$(echo "$line" | awk '{print $10}')
    [[ -z "$name" ]] && continue
    # 未連線的 UDP socket（例如 *:50416，SuperLive 每秒開關一次的區網搜尋）只會洗版，預設略過
    [[ "$name" != *"->"* && -z "${SLP_WATCH_ALL:-}" ]] && continue
    key="$proto $name"
    now[$key]="$state"
  done < <(lsof -nP -a -p "$pid" -i 2>/dev/null | tail -n +2)

  for k in ${(k)now}; do
    if [[ -z "${seen[$k]-}" ]]; then
      msg="$(date +%T) + $k ${now[$k]}"
      echo "$msg" | tee -a "$log"
    fi
  done
  for k in ${(k)seen}; do
    if [[ -z "${now[$k]-}" ]]; then
      msg="$(date +%T) - $k"
      echo "$msg" | tee -a "$log"
    fi
  done
  seen=(); for k in ${(k)now}; do seen[$k]="${now[$k]}"; done
  sleep 1
done
