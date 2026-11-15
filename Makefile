.PHONY: all data llama dict build test app install uninstall playground clean

all: app

data:            ## 辞書とモデルをダウンロード
	sh scripts/fetch-data.sh

llama:           ## llama.cpp をビルド
	sh scripts/build-llama.sh

dict: build/system.dict

build/system.dict: Tools/build_dict.py
	mkdir -p build
	python3 Tools/build_dict.py vendor/mozc build/system.dict

build: dict      ## すべてビルド
	swift build -c release

test: dict       ## テスト
	swift test

app: dict        ## build/Tsumugi.app を作る
	sh scripts/build-app.sh

install: app     ## 入力メソッドとしてインストール
	sh scripts/install.sh

uninstall:       ## 入力メニューから外して削除 (学習内容は残す)
	sh scripts/uninstall.sh

playground: build ## 登録なしで試せるウインドウを開く
	.build/release/TsumugiPlayground

clean:
	rm -rf .build build
