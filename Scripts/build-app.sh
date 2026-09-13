#!/bin/bash
# Release ビルドして build/Mozu.app にバンドルする。
#
# ad-hoc 署名を必ずかけるのは、署名がないとビルドのたびに
# アクセシビリティ権限の許可が外れてしまうからだ（TCC はコード署名を
# 以降アプリの識別に使う）。--identifier で bundle id を固定しているのも同じ理由。
#
# --requirements で cdhash を含まない指定要件（identifier だけ）を
# 埋め込むのも重要。これがないと ad-hoc 署名の識別子は cdhashそのもので、
# リビルドのたびに「別のアプリ」とみなされて許可が外れる（実測で地獄を見た）。
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Mozu.app"
IDENTIFIER="com.nico.mozu"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Mozu "$APP/Contents/MacOS/Mozu"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# UI 文言（ja / en / zh-Hans / zh-Hant）。lproj をそのまま Contents/Resources に置く。
mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

codesign --force --sign - --identifier "$IDENTIFIER" \
  --requirements '=designated => identifier "'"$IDENTIFIER"'";' \
  "$APP"

echo
echo "created: $APP"
echo "run:     open $APP"
