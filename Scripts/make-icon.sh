#!/bin/bash
# AppIcon.icns を再生成する。実行すると Resources/AppIcon.icns が更新される。
#
# 手順: make-icon.swift（元写真 → Vision で白シルエット）で 1024px PNG を描き、
# sips で iconset の要求サイズをすべて切り出し、iconutil で icns に固める。
#
# 使い方: ./Scripts/make-icon.sh [元写真]   （既定: Resources/shrike.jpg）
# 元写真が無い環境（リポジトリ clone 直後など）では、生成済みでコミット済みの
# Resources/icon-1024.png をそのまま使う。写真自体はウォーターマーク付きの
# 出所不明写真なので git にコミットしない（.gitignore 参照）。
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p build

PHOTO="${1:-Resources/shrike.jpg}"
if [ -f "$PHOTO" ]; then
    swift Scripts/make-icon.swift "$PHOTO" build/icon-1024.png build/menubar.png
    cp build/icon-1024.png Resources/icon-1024.png
    # メニューバー高さは 18pt（@2x で 36px）が目安。横幅はアスペクト比のまま。
    sips --resampleHeight 36 build/menubar.png --out Resources/MenuBarIcon.png >/dev/null
    SRC="build/icon-1024.png"
    echo "regenerated from photo: $PHOTO"
elif [ -f Resources/icon-1024.png ]; then
    echo "photo not found: $PHOTO — using committed Resources/icon-1024.png"
    SRC="Resources/icon-1024.png"
else
    echo "error: neither photo ($PHOTO) nor Resources/icon-1024.png exists" >&2
    exit 1
fi

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

sips -z 16 16     "$SRC" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$SRC" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$SRC" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$SRC"                               "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "created: Resources/AppIcon.icns"
