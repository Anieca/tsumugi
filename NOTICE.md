# 第三者のデータ・ソフトウェア

Tsumugi は次のものを利用しています。再配布するときはそれぞれのライセンスに従ってください。

| 名称 | 用途 | ライセンス | 入手元 |
|---|---|---|---|
| Mozc OSS 辞書 (dictionary_oss) | 単語・接続コスト | BSD 3-Clause (Google)。辞書は IPAdic 由来のデータを含み、NAIST / ICOT の条項が付く。詳細は同梱の `vendor/mozc/LICENSE` と `README.txt` | https://github.com/google/mozc |
| zenz-v3.2-small (GGUF) | かな漢字変換・続きの予測 | CC BY-SA 4.0 (Keita Miwa)。基盤モデル ku-nlp/gpt2-small-japanese-char も CC BY-SA 4.0 | https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf |
| llama.cpp | LLM の推論 | MIT | https://github.com/ggml-org/llama.cpp |

zenz のプロンプト書式は AzooKeyKanaKanjiConverter (MIT) の公開実装を参考にしました。コードは流用していません。
