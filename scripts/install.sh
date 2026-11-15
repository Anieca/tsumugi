#!/bin/sh
# build/Tsumugi.app を ~/Library/Input Methods に入れ、入力ソースとして登録・有効化する。
set -e
cd "$(dirname "$0")/.."
DEST="$HOME/Library/Input Methods"
mkdir -p "$DEST"
pkill -x TsumugiIME 2>/dev/null || true
rm -rf "$DEST/Tsumugi.app"
cp -R build/Tsumugi.app "$DEST/"
"$DEST/Tsumugi.app/Contents/MacOS/TsumugiIME" --register
echo "入力メニュー (メニューバー) から「Tsumugi」を選ぶと使えます。"
echo "出てこないときは一度ログアウトしてログインし直してください。"
