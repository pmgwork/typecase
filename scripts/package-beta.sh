#!/bin/bash
set -euo pipefail

version=${1:?使用例: scripts/package-beta.sh 1.0.0-beta.1}
if [[ ! $version =~ ^([0-9]+\.[0-9]+\.[0-9]+)-beta\.([1-9][0-9]{0,2})$ ]] || (( 10#${BASH_REMATCH[2]} > 255 )); then
  echo 'ベータ版の形式は 1.0.0-beta.1（番号は 1〜255）です。' >&2
  exit 1
fi
marketing=${BASH_REMATCH[1]}
build="${marketing}b${BASH_REMATCH[2]}"
root=$(cd "$(dirname "$0")/.." && pwd)
dist="$root/dist"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mkdir -p "$dist"
xcodebuild -project "$root/typecase.xcodeproj" -scheme typecase -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$dist/DerivedData" \
  MARKETING_VERSION="$marketing" CURRENT_PROJECT_VERSION="$build" build
app="$dist/DerivedData/Build/Products/Release/TypeCase.app"
codesign --verify --deep --strict "$app"
tools="$dist/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
key=$($tools/generate_keys --account pmgwork.typecase -p)
expected=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")
[[ $key == "$expected" ]] || { echo 'Sparkle の公開鍵がアプリの設定と一致しません。' >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/typecase-beta.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
zip="TypeCase-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$tmp/$zip"
ditto -x -k "$tmp/$zip" "$tmp/extracted"
codesign --verify --deep --strict "$tmp/extracted/TypeCase.app"
if [[ -f "$dist/release-notes-v$version.md" ]]; then cp "$dist/release-notes-v$version.md" "$tmp/TypeCase-$version.md"; fi
"$tools/generate_appcast" --account pmgwork.typecase --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/pmgwork/typecase/releases/download/v$version/" \
  -o "$tmp/appcast.xml" "$tmp"
mv "$tmp/$zip" "$dist/$zip"
mv "$tmp/appcast.xml" "$dist/appcast.xml"
(cd "$dist" && shasum -a 256 "$zip" > "TypeCase-$version.sha256")
echo "作成しました: $dist/$zip, $dist/appcast.xml"
