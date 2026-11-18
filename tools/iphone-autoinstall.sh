#!/bin/zsh
# iPhone 版自動重裝（免費 Personal Team 簽章約 7 天到期）
#
# 由 launchd 每 30 分鐘執行一次（~/Library/LaunchAgents/local.dvrviewer.phone-autoinstall.plist）：
#   1. 距離上次成功安裝未滿 5 天、且 App 的描述檔離到期還有 2 天以上 → 什麼都不做
#      （App 實際到期看描述檔：Xcode 可能沿用較早建立的描述檔，所以不能只看安裝日期）
#   2. 需要重裝時，用 Git 已提交的版本（不含未提交的修改）編譯並更新簽章（同一天內重用編譯結果）
#   3. iPhone 在同一個網路且已解鎖才安裝；鎖定或不在家就等下一次
#   4. 成功或編譯失敗時跳出 macOS 通知；Xcode 沒有登入 Apple ID 時通知去登入
#   5. 編譯出的描述檔剩不到 3 天就到期時，刪掉本機那份描述檔再編一次，讓 Xcode 重新產生
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
RENEW_BEFORE_EXPIRY_DAYS=2
mkdir -p "$STATE" "$WORK"
# iPhone 的 UDID 只存在本機（xcrun devicectl list devices 查得到），不放進公開的 repo
DEVICE=$(cat "$STATE/device-id" 2>/dev/null) || { print "請先把 iPhone UDID 寫入 $STATE/device-id"; exit 1; }

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
notify() { osascript -e "display notification \"$1\" with title \"DVR Viewer iPhone 自動重裝\"" >/dev/null 2>&1; }

# 讀取 App 內描述檔的到期時間（epoch 秒）；讀不到回傳 0
profile_expiry() {
  local plist="$WORK/profile.plist" d
  security cms -D -i "$1/embedded.mobileprovision" > "$plist" 2>/dev/null || { print 0; return; }
  d=$(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" "$plist" 2>/dev/null)
  rm -f "$plist"
  [[ -n "$d" ]] && date -j -f "%a %b %d %T %Z %Y" "$d" +%s 2>/dev/null || print 0
}

# 通知一天最多一次（key 區分不同事件）
notify_daily() {
  if [[ "$(cat "$STATE/notified-$1" 2>/dev/null)" != "$(date +%Y%m%d)" ]]; then
    notify "$2"
    date +%Y%m%d > "$STATE/notified-$1"
  fi
}

now=$(date +%s)
last=$(cat "$STATE/last-install" 2>/dev/null || echo 0)
expires=$(cat "$STATE/profile-expires" 2>/dev/null || echo 0)
due=$(( last + RENEW_AFTER_DAYS * 86400 ))
(( expires > 0 && expires - RENEW_BEFORE_EXPIRY_DAYS * 86400 < due )) && due=$(( expires - RENEW_BEFORE_EXPIRY_DAYS * 86400 ))
if [[ "${1:-}" != "--force" && "${1:-}" != "--dry-run" ]] && (( now < due )); then
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

build() {
  log "編譯已提交版本 $head"
  rm -rf "$WORK/src" && mkdir -p "$WORK/src"
  git -C "$REPO" archive HEAD | tar -x -C "$WORK/src"
  local blog="$WORK/build.log"
  xcodebuild -project "$WORK/src/mac/DVRViewer.xcodeproj" -scheme DVRViewerPhone -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath "$WORK/DerivedData" -allowProvisioningUpdates build > "$blog" 2>&1
  local rc=$?
  cat "$blog" >> "$LOG"
  if (( rc != 0 )); then
    if grep -q "No Accounts" "$blog"; then
      log "✖ Xcode 沒有登入 Apple ID，無法重新簽章"
      notify_daily no-account "Xcode 沒有登入 Apple ID：請打開 Xcode → 設定 → Accounts 登入，iPhone App 才能續期"
    else
      log "✖ 編譯失敗"
      notify_daily build-fail "編譯失敗，請看 ~/Library/Logs/DVRViewerPhoneAuto.log"
    fi
    return 1
  fi
  print -r -- "$stamp" > "$STATE/built"
}

if [[ "$(cat "$STATE/built" 2>/dev/null)" != "$stamp" || ! -d "$app" ]]; then
  build || exit 1
fi

# 描述檔快到期（Xcode 沿用了舊的）：刪掉本機的這份描述檔，重新編譯讓 Xcode 產生新的
exp=$(profile_expiry "$app")
if (( exp > 0 && exp - now < 3 * 86400 )); then
  log "描述檔將於 $(date -r $exp '+%m/%d %H:%M') 到期，刪除後重新產生"
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    for f in "$dir"/*.mobileprovision(N); do
      security cms -D -i "$f" 2>/dev/null | grep -q "local.dvrviewer.phone" && rm -f "$f"
    done
  done
  rm -f "$STATE/built"
  build || exit 1
  exp=$(profile_expiry "$app")
fi

[[ "${1:-}" == "--dry-run" ]] && { log "（試跑）編譯完成，不安裝"; print "試跑完成：$app"; exit 0; }

# 安裝（鎖定時會失敗，下一次再試）
out=$(xcrun devicectl device install app --device "$DEVICE" "$app" 2>&1)
if print -r -- "$out" | grep -q "databaseSequenceNumber\|installationURL"; then
  print -r -- "$now" > "$STATE/last-install"
  print -r -- "$exp" > "$STATE/profile-expires"
  log "✅ 已安裝 $head（簽章到期 $(date -r $exp '+%m/%d %H:%M')）"
  notify "已重新安裝到 iPhone（版本 $head），簽章到期 $(date -r $exp '+%m/%d')"
elif print -r -- "$out" | grep -qi "locked"; then
  log "iPhone 鎖定中，稍後再試"
else
  log "✖ 安裝失敗：$(print -r -- "$out" | tail -3 | tr '\n' ' ')"
fi
