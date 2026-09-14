#!/bin/bash
# GitHub Releases 添付用の zip を作る。git には入れず、Release アセットとして置く。
#
# zip をリポジトリにコミットしないこと。バイナリは履歴に永遠に残り、
# クローンするだけの人（Homebrew で tarball を引く人も含む）まで重くする。
#
# 注意点:
# - ditto の --keepParent を忘れると Mozu.app の中身がバラで zip され、
#   展開後に「アプリとして」認識されない。
# - ad-hoc 署名なので、ダウンロードした側には quarantine が付く。
#   解決手順は README の zip 配布の項に書いてある（right-click → 開く か xattr）。
# - TCC の識別は designated requirement（identifier だけ）なので、
#   zip 版を差し替えても既存の許可はそのまま維持される。
set -euo pipefail

cd "$(dirname "$0")/.."

./Scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
OUT="build/Mozu-v${VERSION}.zip"

rm -f "$OUT"
ditto -c -k --sequesterRsrc --keepParent build/Mozu.app "$OUT"

echo
echo "created: $OUT"
echo "attach it to: https://github.com/nicokinu/mozu/releases/tag/v${VERSION}"
