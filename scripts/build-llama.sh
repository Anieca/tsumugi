#!/bin/sh
# llama.cpp を取得し、zenz 用のパッチを当てて静的ライブラリを vendor/llama に置く。
set -e
cd "$(dirname "$0")/.."
if [ ! -d vendor/llama.cpp ]; then
  git clone -q https://github.com/ggml-org/llama.cpp.git vendor/llama.cpp
  (cd vendor/llama.cpp && git checkout -q "$(cat ../../scripts/llama.commit)" && git apply ../../scripts/llama-zenz.patch)
fi
cd vendor/llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_CURL=OFF -DLLAMA_BUILD_COMMON=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 > /dev/null
cmake --build build -j 6 --target llama > /dev/null
mkdir -p ../llama/lib ../llama/include
find build -name "*.a" -exec cp {} ../llama/lib/ \;
cp include/*.h ggml/include/*.h ../llama/include/
echo "llama.cpp -> vendor/llama"
