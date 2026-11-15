#!/bin/sh
# llama.cpp を取得し、zenz 用のパッチを当てて静的ライブラリを vendor/llama に置く。
# scripts/llama.commit の版でビルド済みなら何もしない (版を変えると作り直す)。
set -e
cd "$(dirname "$0")/.."
WANT="$(cat scripts/llama.commit)"
if [ -f vendor/llama/lib/libllama.a ] && [ "$(cat vendor/llama/COMMIT 2>/dev/null)" = "$WANT" ] && [ "$1" != "-f" ]; then
  echo "llama.cpp は $WANT でビルド済み"
  exit 0
fi
if [ ! -d vendor/llama.cpp ]; then
  git clone -q https://github.com/ggml-org/llama.cpp.git vendor/llama.cpp
fi
(
  cd vendor/llama.cpp
  git cat-file -e "$WANT^{commit}" 2>/dev/null || git fetch -q origin
  git checkout -q -- . && git checkout -q "$WANT"
  git apply ../../scripts/llama-zenz.patch
)
cd vendor/llama.cpp
rm -rf build
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_CURL=OFF -DLLAMA_BUILD_COMMON=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 > /dev/null
cmake --build build -j "$(sysctl -n hw.ncpu)" --target llama > /dev/null
rm -rf ../llama
mkdir -p ../llama/lib ../llama/include
find build -name "*.a" -exec cp {} ../llama/lib/ \;
cp include/*.h ggml/include/*.h ../llama/include/
echo "$WANT" > ../llama/COMMIT
echo "llama.cpp ($WANT) -> vendor/llama"
