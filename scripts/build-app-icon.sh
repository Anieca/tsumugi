#!/bin/sh
# 元画像から macOS 用の全解像度を持つアプリアイコンを生成する。
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
WORK=$(mktemp -d build/app-icon.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" Resources/AppIcon.png \
        --out "$ICONSET/icon_${SIZE}x${SIZE}.png" > /dev/null
    RETINA=$((SIZE * 2))
    sips -z "$RETINA" "$RETINA" Resources/AppIcon.png \
        --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o build/AppIcon.icns
