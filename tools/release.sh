#!/bin/zsh
# 發佈新版本：版本號 → Release 編譯 → DMG → Sparkle 簽章 → 產生並簽章 appcast.xml
#
# 用法：SPARKLE_BIN=<Sparkle 發行包>/bin tools/release.sh <版本，例如 0.3> <內部版本號（必須遞增），例如 3>
#
# 會先做個資檢查（tools/private-patterns.txt＋通用規則），發現就中斷。
#
# 事前準備：
#   1. 在 RELEASE_NOTES.md 最上方加入「v<版本>」段落（由新到舊列出每個版本的更新內容）
#   2. Sparkle 工具：https://github.com/sparkle-project/Sparkle/releases（解壓後的 bin 資料夾）
#   3. EdDSA 私鑰在鑰匙圈（帳號 local.dvrviewer.app；換電腦時用 generate_keys --account local.dvrviewer.app -f <備份檔> 匯入）
#
# 完成後：commit 並推送（含 appcast.xml），再執行腳本最後印出的 gh release create 指令上傳 DMG 與 appcast.xml。
# appcast 只放最新版本；更新說明（Markdown）包含 RELEASE_NOTES.md 的完整歷史。
# 更新網址：0.8 起為 Releases 的 latest/download/appcast.xml（沒有快取延遲）；
# 0.7.2 以前的版本讀 repo 根目錄的 appcast.xml（raw 網址，快取 5 分鐘），所以兩邊都要更新。

set -euo pipefail
ver="${1:-}"; build="${2:-}"
[[ -z "$ver" || -z "$build" ]] && { sed -n '2,13p' "$0"; exit 1; }
: "${SPARKLE_BIN:?請設定 SPARKLE_BIN（Sparkle 發行包的 bin 資料夾）}"
cd "$(dirname "$0")/.."

repo="doghsiao412/mac-dvr-viewer"
account="local.dvrviewer.app"
minos="26.0"

head -1 RELEASE_NOTES.md | grep -qx "v$ver" || { echo "RELEASE_NOTES.md 第一行必須是 v$ver"; exit 1; }

# 個資檢查：repo 是公開的，發現 IP、帳號、設備名稱、本機路徑或 Email 就中斷
#   tools/private-patterns.txt（只在本機、不進 Git）列出自己的 IP／帳號／設備名稱
echo "■ 個資檢查"
leak=0
patterns=tools/private-patterns.txt
if [[ -f "$patterns" ]]; then
  if git grep --untracked -I -n -E -f <(grep -v '^#' "$patterns" | grep -v '^$') -- . ':!tools/private-patterns.txt'; then leak=1; fi
else
  echo "⚠️ 找不到 $patterns，只做通用檢查（建議建立，列出自己的 IP、帳號、設備名稱）"
fi
# 通用：本機使用者路徑、Email（noreply 與圖檔 @2x 除外）
if git grep --untracked -I -n -E '/Users/[A-Za-z]' -- . ':!tools/private-patterns.txt'; then leak=1; fi
if git grep --untracked -I -n -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}' -- . ':!tools/private-patterns.txt' \
     | grep -v -E 'noreply|@[0-9]+x\.'; then leak=1; fi
(( leak )) && { echo "✖ 發現可能的個人資訊（如上），請移除後再發佈"; exit 1; }
echo "   ✓ 未發現個人資訊"

proj=mac/DVRViewer.xcodeproj/project.pbxproj
sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $ver;/g; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $build;/g" "$proj"

echo "■ Release 編譯 $ver（$build）"
xcodebuild -project mac/DVRViewer.xcodeproj -scheme DVRViewer -configuration Release \
  -derivedDataPath mac/build/DerivedData clean build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
app="mac/build/DerivedData/Build/Products/Release/DVR Viewer.app"
codesign --verify --deep --strict "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$ver" ]]

echo "■ 製作 DMG"
stage="$(mktemp -d)"
ditto "$app" "$stage/DVR Viewer.app"
ln -s /Applications "$stage/應用程式"
mkdir -p dist
dmg="dist/DVR-Viewer-$ver.dmg"
rm -f "$dmg"
hdiutil create -volname "DVR Viewer $ver" -srcfolder "$stage" -ov -format UDZO -fs HFS+ "$dmg" >/dev/null
rm -rf "$stage"
hdiutil verify "$dmg" >/dev/null

echo "■ Sparkle 簽章"
sig="$("$SPARKLE_BIN/sign_update" --account "$account" "$dmg")"
pub="$(LC_ALL=en_US.UTF-8 date -u "+%a, %d %b %Y %H:%M:%S GMT")"
notes="$(cat RELEASE_NOTES.md)"

cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>DVR Viewer 更新</title>
    <item>
      <title>DVR Viewer $ver</title>
      <pubDate>$pub</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$ver</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minos</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[$notes
]]></description>
      <sparkle:fullReleaseNotesLink>https://github.com/$repo/blob/v$ver/RELEASE_NOTES.md</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$repo/releases/download/v$ver/DVR-Viewer-$ver.dmg" $sig type="application/octet-stream"></enclosure>
    </item>
  </channel>
</rss>
XML
xmllint --noout appcast.xml
"$SPARKLE_BIN/sign_update" --account "$account" appcast.xml   # 簽章嵌入 appcast 檔尾
"$SPARKLE_BIN/sign_update" --account "$account" --verify appcast.xml

# 本版的更新說明（給 GitHub Release）
awk -v v="v$ver" 'NR==1 && $0==v {on=1; next} /^v[0-9]/ {on=0} on' RELEASE_NOTES.md > "dist/notes-$ver.md"

echo
echo "完成：$dmg"
echo "下一步：commit 並推送（含 appcast.xml、RELEASE_NOTES.md），再執行："
echo "  gh release create v$ver $dmg appcast.xml --repo $repo --title \"DVR Viewer $ver\" --notes-file dist/notes-$ver.md"
