#!/bin/zsh
# iPhone 版自動重裝（免費 Personal Team 簽章約 7 天到期）
#
# 由 launchd 每 30 分鐘執行一次（~/Library/LaunchAgents/local.dvrviewer.phone-autoinstall.plist）：
#   1. 距離上次成功安裝未滿 5 天 → 什麼都不做
#   2. 需要重裝時，用 Git 已提交的版本（不含未提交的修改）編譯並更新簽章（同一天內重用編譯結果）
#   3. iPhone 在同一個網路且已解鎖才安裝；鎖定或不在家就等下一次
#   4. 成功或編譯失敗時跳出 macOS 通知
#
# 手動執行：tools/iphone-autoinstall.sh [--force|--dry-run]（--force 不管距離上次幾天都嘗試；--dry-run 只編譯、不安裝）
# 停用：launchctl bootout gui/$(id -u)/local.dvrviewer.phone-autoinstall，並刪除上述 plist

set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin"

REPO="${0:A:h:h}"
STATE="$HOME/Library/Application Support/DVRViewerPhoneAuto"
WORK="$HOME/Library/Caches/DVRViewerPhoneAuto"
LOG="$HOME/Library/Logs/DVRViewerPhoneAuto.log"
RENEW_AFTER_DAYS=5
mkdir -p "$STATE" "$WORK"
# iPhone 的 UDID 只存在本機（xcrun devicectl list devices 查得到），不放進公開的 repo
DEVICE=$(cat "$STATE/device-id" 2>/dev/null) || { print "請先把 iPhone UDID 寫入 $STATE/device-id"; exit 1; }

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
notify() { osascript -e "display notification \"$1\" with title \"DVR Viewer iPhone 自動重裝\"" >/dev/null 2>&1; }

now=$(date +%s)
last=$(cat "$STATE/last-install" 2>/dev/null || echo 0)
if [[ "${1:-}" != "--force" && "${1:-}" != "--dry-run" ]] && (( now - last < RENEW_AFTER_DAYS * 86400 )); then
  exit 0
fi

# iPhone 不在（不在家、未配對）就不必編譯
if ! xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | grep -q "available"; then
  log "iPhone 不在線上，稍後再試"
  exit 0
fi

# 編譯（同一天內、同一個提交只編一次）
head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)
stamp="$head-$(date +%Y%m%d)"
app="$WORK/DerivedData/Build/Products/Debug-iphoneos/DVR Viewer Phone.app"
if [[ "$(cat "$STATE/built" 2>/dev/null)" != "$stamp" || ! -d "$app" ]]; then
  log "編譯已提交版本 $head"
  rm -rf "$WORK/src" && mkdir -p "$WORK/src"
  git -C "$REPO" archive HEAD | tar -x -C "$WORK/src"
  if xcodebuild -project "$WORK/src/mac/DVRViewer.xcodeproj" -scheme DVRViewerPhone -configuration Debug \
       -destination 'generic/platform=iOS' -derivedDataPath "$WORK/DerivedData" -allowProvisioningUpdates build \
       >> "$LOG" 2>&1; then
    print -r -- "$stamp" > "$STATE/built"
  else
    log "✖ 編譯失敗"
    # 編譯失敗一天只通知一次
    if [[ "$(cat "$STATE/build-fail-notified" 2>/dev/null)" != "$(date +%Y%m%d)" ]]; then
      notify "編譯失敗，請看 ~/Library/Logs/DVRViewerPhoneAuto.log"
      date +%Y%m%d > "$STATE/build-fail-notified"
    fi
    exit 1
  fi
fi

[[ "${1:-}" == "--dry-run" ]] && { log "（試跑）編譯完成，不安裝"; print "試跑完成：$app"; exit 0; }

# 安裝（鎖定時會失敗，下一次再試）
out=$(xcrun devicectl device install app --device "$DEVICE" "$app" 2>&1)
if print -r -- "$out" | grep -q "databaseSequenceNumber\|installationURL"; then
  print -r -- "$now" > "$STATE/last-install"
  log "✅ 已安裝 $head"
  notify "已重新安裝到 iPhone（版本 $head），簽章再延長約 7 天"
elif print -r -- "$out" | grep -qi "locked"; then
  log "iPhone 鎖定中，稍後再試"
else
  log "✖ 安裝失敗：$(print -r -- "$out" | tail -3 | tr '\n' ' ')"
fi
