#!/bin/zsh
# 發佈新版本（編譯 → DMG → Sparkle 簽章 → 印出 appcast 項目）
#
# 用法：tools/release.sh <版本，例如 0.3> <內部版本號，必須遞增，例如 3>
#
# 需要：Sparkle 工具（sign_update）路徑放在環境變數 SPARKLE_BIN，例如
#   SPARKLE_BIN=~/Tools/Sparkle-2.10.0/bin tools/release.sh 0.3 3
# 私鑰在鑰匙圈（帳號 local.dvrviewer.app，由 generate_keys --account local.dvrviewer.app 產生）。
# 完成後：把印出的 <item> 加到 appcast.xml 最上方、commit、推送，再用
#   gh release create v<版本> dist/DVR-Viewer-<版本>.dmg
# 上傳 DMG（appcast 中的下載網址指向該 Release）。

set -euo pipefail
ver="${1:-}"; build="${2:-}"
[[ -z "$ver" || -z "$build" ]] && { sed -n '2,13p' "$0"; exit 1; }
: "${SPARKLE_BIN:?請設定 SPARKLE_BIN（Sparkle 發行包的 bin 資料夾）}"
cd "$(dirname "$0")/.."

proj=mac/DVRViewer.xcodeproj/project.pbxproj
sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $ver;/; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $build;/" "$proj"
sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $ver;/; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $build;/" "$proj"

xcodebuild -project mac/DVRViewer.xcodeproj -scheme DVRViewer -configuration Release \
  -derivedDataPath mac/build/DerivedData clean build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
app="mac/build/DerivedData/Build/Products/Release/DVR Viewer.app"
codesign --verify --deep --strict "$app"

stage="$(mktemp -d)"
ditto "$app" "$stage/DVR Viewer.app"
ln -s /Applications "$stage/應用程式"
mkdir -p dist
dmg="dist/DVR-Viewer-$ver.dmg"
rm -f "$dmg"
hdiutil create -volname "DVR Viewer $ver" -srcfolder "$stage" -ov -format UDZO -fs HFS+ "$dmg" >/dev/null
rm -rf "$stage"

sig="$("$SPARKLE_BIN/sign_update" --account local.dvrviewer.app "$dmg")"
pub="$(LC_ALL=en_US.UTF-8 date -u "+%a, %d %b %Y %H:%M:%S +0000")"
cat <<ITEM

=== 加到 appcast.xml 的 <channel> 內（最新版本放最上面）===
    <item>
      <title>DVR Viewer $ver</title>
      <pubDate>$pub</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$ver</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[ <ul><li>（更新內容）</li></ul> ]]></description>
      <enclosure url="https://github.com/doghsiao412/mac-dvr-viewer/releases/download/v$ver/DVR-Viewer-$ver.dmg"
                 $sig
                 type="application/octet-stream" />
    </item>
ITEM
echo "DMG：$dmg"
