#!/bin/sh
# build/Tsumugi.app (入力メソッド) を組み立てる。
set -e
cd "$(dirname "$0")/.."
swift build -c release --product TsumugiIME
APP=build/Tsumugi.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TsumugiIME "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
sh scripts/build-app-icon.sh
cp build/AppIcon.icns "$APP/Contents/Resources/"
cp build/system.dict "$APP/Contents/Resources/system.dict"
cp vendor/models/zenz-v3.2-small-Q5_K_M.gguf "$APP/Contents/Resources/zenz.gguf"
swift scripts/make-icon.swift ja "$APP/Contents/Resources/icon.tiff"
swift scripts/make-icon.swift roman "$APP/Contents/Resources/icon-roman.tiff"
cp -R Resources/ja.lproj Resources/en.lproj "$APP/Contents/Resources/"
cp NOTICE.md "$APP/Contents/Resources/" 2>/dev/null || true
codesign --force --sign - "$APP" > /dev/null 2>&1
echo "built $APP ($(du -sh "$APP" | cut -f1))"
