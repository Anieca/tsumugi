#!/bin/sh
# Tsumugi をソースからビルドしてインストールする。2 回目以降は更新として動く。
#
#   curl -fsSL https://raw.githubusercontent.com/Anieca/tsumugi/main/install.sh | sh
#   または、クローン済みのフォルダで  ./install.sh
#
# 環境変数
#   TSUMUGI_DIR   ソースを置く場所 (既定: ~/.local/src/tsumugi。クローン内で実行したときはそのフォルダ)
#   TSUMUGI_REF   入れる版 (タグかブランチ。既定: main)
set -e

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mエラー: %s\033[0m\n' "$*" >&2; exit 1; }

# --- 前提の確認 ---
[ "$(uname -s)" = Darwin ] || fail "macOS 専用です。"
[ "$(uname -m)" = arm64 ] || fail "Apple Silicon (M1 以降) の Mac が必要です。"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || fail "macOS 13 以降が必要です。"
xcode-select -p >/dev/null 2>&1 || fail "Xcode (またはコマンドラインツール) がありません。 xcode-select --install を実行してください。"
command -v swift   >/dev/null || fail "swift が見つかりません。Xcode を入れてください。"
command -v git     >/dev/null || fail "git が見つかりません。"
command -v python3 >/dev/null || fail "python3 が見つかりません。"
if ! command -v cmake >/dev/null; then
  if command -v brew >/dev/null; then
    say "cmake を Homebrew で入れます"
    brew install cmake
  else
    fail "cmake が見つかりません。 https://cmake.org か Homebrew (brew install cmake) で入れてください。"
  fi
fi
free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
[ "$free_gb" -ge 2 ] || fail "空き容量が足りません (2GB 以上必要、現在 ${free_gb}GB)。"

# --- ソースの取得 ---
here="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$here" ] && [ -f "$here/Package.swift" ] && [ -f "$here/scripts/llama.commit" ]; then
  DIR="${TSUMUGI_DIR:-$here}"
else
  DIR="${TSUMUGI_DIR:-$HOME/.local/src/tsumugi}"
fi
REF="${TSUMUGI_REF:-}"
if [ -d "$DIR/.git" ]; then
  cd "$DIR"
  if [ -n "$REF" ] || [ "$DIR" != "$here" ]; then
    say "ソースを更新します ($DIR)"
    git fetch -q --tags origin
    git checkout -q "${REF:-main}"
    git symbolic-ref -q HEAD >/dev/null && git pull -q --ff-only
  fi
else
  say "ソースを取得します ($DIR)"
  mkdir -p "$(dirname "$DIR")"
  git clone -q https://github.com/Anieca/tsumugi.git "$DIR"
  cd "$DIR"
  [ -n "$REF" ] && git checkout -q "$REF"
fi
say "版: $(git describe --tags --always)"

# --- ビルドとインストール ---
say "辞書とモデルを用意します (初回は約 170MB をダウンロード)"
make -s data
say "llama.cpp を用意します (初回は数分かかります)"
make -s llama
say "Tsumugi をビルドします"
make -s app
say "インストールします"
sh scripts/install.sh

say "完了"
echo "更新するときは同じコマンドをもう一度実行してください。"
echo "削除: sh \"$DIR/scripts/uninstall.sh\""
