#!/bin/sh
# Mozc OSS 辞書と zenz モデルをダウンロードする。
set -e
cd "$(dirname "$0")/.."
mkdir -p vendor/mozc vendor/models
# 辞書は版を固定する (変えるときはこの値を更新して vendor/mozc を消す)
MOZC_REV=a4541df29db443b49f81cf54665873b68fde9efa
for f in dictionary00.txt dictionary01.txt dictionary02.txt dictionary03.txt dictionary04.txt dictionary05.txt \
         dictionary06.txt dictionary07.txt dictionary08.txt dictionary09.txt connection_single_column.txt id.def README.txt; do
  [ -f "vendor/mozc/$f" ] || curl -fL -o "vendor/mozc/$f" "https://raw.githubusercontent.com/google/mozc/$MOZC_REV/src/data/dictionary_oss/$f"
done
[ -f vendor/mozc/LICENSE ] || curl -fL -o vendor/mozc/LICENSE https://raw.githubusercontent.com/google/mozc/$MOZC_REV/LICENSE
M=vendor/models/zenz-v3.2-small-Q5_K_M.gguf
[ -f "$M" ] || curl -fL -o "$M" https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf/resolve/main/ggml-model-Q5_K_M.gguf
