#!/bin/sh
# 入力メニューから外し、~/Library/Input Methods/Tsumugi.app を削除する。
# 学習内容 (~/Library/Application Support/Tsumugi) は残す。--purge を付けると一緒に消す。
set -e
APP="$HOME/Library/Input Methods/Tsumugi.app"
if [ -x "$APP/Contents/MacOS/TsumugiIME" ]; then
  "$APP/Contents/MacOS/TsumugiIME" --unregister || true
fi
pkill -x TsumugiIME 2>/dev/null || true
rm -rf "$APP"
if [ "$1" = "--purge" ]; then
  rm -rf "$HOME/Library/Application Support/Tsumugi"
  echo "学習内容も削除しました。"
fi
echo "Tsumugi を削除しました。"
