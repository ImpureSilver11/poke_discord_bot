# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Discord 用のポケモン Bot（Ruby / discordrb）。fly.io 上で常駐する 1 プロセス。
このファイルは要点のみ。設計の背景や理由は `README.md` に詳しく書かれているので、
判断に迷ったらそちらを読むこと。コード・コメント・コミットは日本語で書かれている。

## コマンド

```sh
bundle install

bundle exec rake test        # 既定。外部APIに接続しない。skip 0 件で常に全部通る
bundle exec rake test_live   # 実 API への疎通テストのみ（LIVE=1 は rake 側で立つ）
bundle exec rake test_all

bundle exec ruby -Ilib -Itest test/test_pokemon_image.rb   # 単一ファイル
bundle exec ruby -Ilib -Itest test/test_commands.rb -n /help/  # 単一テスト（minitest の -n）

bundle exec rake hooks:install   # pre-push で rake test を走らせる（各自1回）

ruby main.rb                 # 起動には .env の TOKEN が必要
```

種族値データの更新（PokeAPI が正典。**手書き禁止**）:

```sh
ruby scripts/fetch_missing_pokemon.rb
DRY_RUN=1 ruby scripts/fetch_mega_evolutions.rb        # 差分確認のみ
FIX_EXISTING=1 ruby scripts/fetch_mega_evolutions.rb   # 既存が API と食い違う場合に上書き
```

## 構成

`main.rb` が dotenv → discordrb の Bot 生成 → `register_commands(bot)` → `bot.run` を行うだけ。
`lib/` の各ファイルはクラスではなく**トップレベルのメソッド定義**で、`require_relative` で
グローバルに生える（テストも同じ前提で書かれている）。

| ファイル | 役割 |
| --- | --- |
| `lib/commands.rb` | `COMMAND_SPECS`（コマンド定義の唯一の情報源）とハンドラ、@メンション時のヘルプ生成 |
| `lib/pokemon_image.rb` | 公式のカード検索・画像取得。**`http_get_json` / `http_get_image` の定義元でもある** |
| `lib/pokemon_stats.rb` | `data/pokemon_data.json`（約1180件）を読んで種族値バーを整形 |
| `lib/pokemon_release.rb` | 公式の商品情報 API から発売予定を取得・整形 |
| `lib/pokemon_card_site.rb` | 公式サイトのホスト名と URL 組み立て。上記2つが共有する |
| `lib/discord_helper.rb` | defer 後のファイル添付。discordrb では送れないので Webhook API を直接叩く |

## 変更時に踏みやすい点

**コマンド追加は `COMMAND_SPECS` に定義を足してから `bot.application_command` でハンドラを書く。**
ヘルプは `COMMAND_SPECS` から自動生成されるので手書きしないこと（`test/test_commands.rb` が
全コマンドのヘルプ掲載を検証している）。`description` は Discord の制約で 1〜100 文字の 1 行。
長い説明は `details` に置く。

**HTTP は必ず `http_get_json` / `http_get_image` を経由する。** テストはこの 2 つを
`test/test_helper.rb` で差し替えており、未スタブの呼び出しは `StubHttp::NotConfigured`
（`StandardError` を継承しない = `rescue StandardError` に飲まれない）で落ちる。
`Net::HTTP` を直接呼ぶコードを足すとテストがすり抜けて外部アクセスが混入する。

**外部 API に触るテストは `test/test_*_live.rb` に置く。** `rake test` の対象から除外され、
`rake test_live`（CI の `live` ジョブ・週次）でだけ走る。既定のテストを外部要因で
落とさないための分離なので、通常のテストに live なケースを混ぜない。

**Docker の `test` ステージが最後の関門。** 最終ステージの `COPY --from=test /tmp/tests-passed`
を消すと BuildKit がテストステージごとスキップするので消さないこと。
ローカルの `fly deploy` は git を経由しないため pre-push も CI もすり抜ける。

**Gemfile を変えたら `bundle install` して `Gemfile.lock` も commit する。**
`BUNDLE_FROZEN=true` なので lock が古いと Docker ビルドが失敗する。
`PLATFORMS` に Linux (`x86_64-linux` / `aarch64-linux`) が入っている必要もある。

**Ruby のバージョンは 3 箇所で揃える。** `Dockerfile` の `ARG RUBY_VERSION` と
`.github/workflows/test.yml` の `ruby-version`。片方だけ上げない。

**ログ:** 正常系（0 件ヒットを含む）は `puts`、運用者が対処すべき異常系は `warn`。
fly.io でバッファされるため `main.rb` で `$stdout.sync = true` している。

**Discord の 2000 文字制限:** ユーザーに返す長文（ヘルプ・発売予定）は組み立ての最後で
切り詰めている。新しく長文を返す箇所を足すなら同様に。

## 外部データソース

| 用途 | 取得先 | 性質 |
| --- | --- | --- |
| カード画像 | `www.pokemon-card.com/card-search/resultAPI.php` | **非公式**。予告なく壊れる前提で扱う |
| 発売予定日 | `www.pokemon-card.com/products/resultAPI.php` | **非公式**。同上 |
| 種族値 | PokeAPI（スクリプト経由のみ、実行時には叩かない） | `data/pokemon_data.json` に固める |

**どちらも壊れたら `.claude/skills/diagnose-card-api/` の手順で切り分ける。**
どちらも `POST` は CloudFront に 403 で弾かれるので GET で叩く。

カード検索で特に注意する点（詳細は README の「カード画像の検索仕様」）:

- **`sm_and_keyword=true` が必須。** 抜けると `keyword` が黙って無視され全カード（2万件超）が
  返る。0件にならず HTTP も 200 なので、パラメータを消しても気付けない
- **`regulation_sidebar_form=all` が必須。** 抜けるとスタンダードのみに絞られる
- **`keyword` はカードテキストも検索対象。** 名前で絞り直さないと無関係なカードが出る
- **空白だけの検索語も全カードを返す**（全角スペースも API 側でトリムされる）。正規化後が
  空文字だと名前フィルタも効かないので、`blank_search_query?` で検索前に弾いている
- **`maxPage` 超のページを投げると最終ページが返る**（空にならない）。終端は `maxPage` で判定
- 名前は `cardNameAltText` を使う。`cardNameViewText` は HTML を含む
- 画像フィルタ → 名前フィルタ → 完全一致/部分一致の順。順序を変えると画像未整備の
  完全一致カードを掴んで失敗する

発売日は `"2026年 9月16日（水）"` のような表示用文字列（月が1桁だと半角スペースが入る）で
返るため `parse_japanese_release_date` で吸収している。

**画像の転載範囲:** 公式サイトは無断転載禁止なので、カード画像を添付するのは
`/pokemon_card` だけに限定している。`/pokemon_release` は発売日・商品名・価格・リンクのみで、
ここに画像を足さない。

## デプロイ

main への push で `.github/workflows/fly-deploy.yml` が `test.yml` を `needs` してから
`flyctl deploy --remote-only`。fly のアプリ名・リージョンは `fly.toml`。
`TOKEN` は fly の secrets で渡す。
