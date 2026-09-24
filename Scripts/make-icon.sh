#!/bin/bash
# AppIcon.icns を再生成する。実行すると Resources/AppIcon.icns が更新される。
#
# アプリアイコンの原画は Resources/icon-art.png（ChatGPT で生成した絵、コミット済み）。
# これを 1024px にリサンプルして iconset に展開し、iconutil で icns に固める。
#
# メニューバー用テンプレート（黒シルエット）の原画は Resources/menubar-art.png
# （吹き出しなし版の絵、コミット済み）。輝度しきいで鳥だけ拾って tight crop する。
#
# 使い方: ./Scripts/make-icon.sh
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p build

# --- アプリアイコン: icon-art.png（原画）→ icon-1024.png → iconset → icns ---
ART="Resources/icon-art.png"
if [ -f "$ART" ]; then
    sips -z 1024 1024 "$ART" --out build/icon-1024.png >/dev/null
    cp build/icon-1024.png Resources/icon-1024.png
    SRC="build/icon-1024.png"
    echo "icon from art: $ART"
elif [ -f Resources/icon-1024.png ]; then
    echo "art not found: $ART — using committed Resources/icon-1024.png"
    SRC="Resources/icon-1024.png"
else
    echo "error: neither $ART nor Resources/icon-1024.png exists" >&2
    exit 1
fi

# --- メニューバー用テンプレート: menubar-art.png（吹き出しなし原画）→ 黒シルエット ---
MB_ART="Resources/menubar-art.png"
if [ -f "$MB_ART" ]; then
    swift Scripts/make-menubar-icon.swift "$MB_ART" build/menubar.png
    sips --resampleHeight 36 build/menubar.png --out Resources/MenuBarIcon.png >/dev/null
    echo "menubar template regenerated from art: $MB_ART"
elif [ -f Resources/MenuBarIcon.png ]; then
    echo "menubar art not found: $MB_ART — keeping committed Resources/MenuBarIcon.png"
else
    echo "error: neither $MB_ART nor Resources/MenuBarIcon.png exists" >&2
    exit 1
fi

# --- iconset → icns ---
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
