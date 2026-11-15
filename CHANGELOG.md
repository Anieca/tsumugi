# 変更履歴

版は [Semantic Versioning](https://semver.org/lang/ja/) に従います。1.0 までは操作感や学習データの形式が変わることがあります。

## [0.2.0] - 2026-11-15

- 確定した文を文全体の読みで読み直し、同音の取り違えや変換し忘れ (仕様率 → 使用率、じょうで → 上で) を小さく提案する。Shift+Tab で反映。3 回見送った提案は出さなくなる。入力メニューから切れる
- `tsumugi-cli proofread` で直しの提案を計測できる。`tsumugi-cli score` で文の自然さを見られる
- 動きを調べる記録 (ふだんは無効) に、打ったキーの種類と直しの提案・適用を加えた

## [0.1.0] - 2026-11-15

最初の公開版。

- ローマ字入力、ライブ変換、Space での候補選択、文節の伸縮
- Mozc OSS 辞書による変換と、zenz-v3.2-small (llama.cpp) による候補の並べ替え
- カーソル前の文章 (最大 300 字) を文脈として変換・先読みに使う
- Tab で続きを先読み入力
- 選んだ変換と読みの書き癖をこの Mac の中だけで学習。入力メニューから一時停止・全消去
- 英数 / かな キーでの切り替え (切り替え時に未確定の文字は確定する)
- `install.sh` による一括インストールと更新、入力ソースの自動有効化、`scripts/uninstall.sh`
- llama.cpp v1.0.0 (b1b770d) を使用

[0.2.0]: https://github.com/Anieca/tsumugi/releases/tag/v0.2.0
[0.1.0]: https://github.com/Anieca/tsumugi/releases/tag/v0.1.0
