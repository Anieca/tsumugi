#!/bin/sh
# ~/Library/Input Methods に入れて入力ソースとして登録する。
set -e
cd "$(dirname "$0")/.."
DEST="$HOME/Library/Input Methods"
mkdir -p "$DEST"
pkill -x TsumugiIME 2>/dev/null || true
rm -rf "$DEST/Tsumugi.app"
cp -R build/Tsumugi.app "$DEST/"
"$DEST/Tsumugi.app/Contents/MacOS/TsumugiIME" --register
echo "システム設定 > キーボード > 入力ソース > 編集… > ＋ > 日本語 から Tsumugi を追加してください。"
