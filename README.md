# poke_discord_bot

## セットアップ

```sh
bundle install
```

gem は Gemfile / Gemfile.lock で管理します。`rake` と `minitest` は
`group :development, :test` に入れており、本番イメージには入りません。

## テスト

```sh
bundle exec rake test        # 既定。外部APIには接続しない
bundle exec rake test_live   # 実際の tcgdex API への疎通も含めて実行
```

個別のファイルだけ実行する場合:

```sh
bundle exec ruby -Ilib -Itest test/test_pokemon_image.rb
```

### 構成

| ファイル | 内容 |
| --- | --- |
| `test/test_helper.rb` | HTTP 層 (`http_get_json` / `http_get_image`) をスタブに差し替える仕組みとフィクスチャ |
| `test/test_pokemon_image.rb` | カード検索・画像選択のロジック。ネットワーク非依存で決定的 |
| `test/test_tcgdex_live.rb` | 実 API への疎通確認。既定ではスキップし `LIVE=1` でのみ実行 |

テスト中に未スタブの HTTP 呼び出しが起きると `StubHttp::NotConfigured` を投げて失敗するため、
意図しない外部アクセスが混入しないようになっています。

## CI

`.github/workflows/test.yml`

| ジョブ | 実行契機 | 内容 |
| --- | --- | --- |
| `test` | push (main) / PR / 手動 | `bundle exec rake test`。外部APIに繋がないので安定して落とせる |
| `live` | 手動のみ | `bundle exec rake test_live`。tcgdex の仕様変更・障害の検知用。`continue-on-error` で PR はブロックしない |

Ruby のバージョンは Dockerfile の `ARG RUBY_VERSION` と揃えています。
片方だけ上げると本番とテスト環境がずれるため、変更時は両方直してください。

デプロイ (`.github/workflows/fly-deploy.yml`) は現在テストの成否と独立して
main への push で走ります。テストを通してからデプロイしたい場合は、deploy ジョブに
`needs: test` 相当の依存を入れてください。

## Docker / 本番構成

`Dockerfile` の base ステージで以下を設定しています。

- `BUNDLE_WITHOUT="development:test"` … テスト用 gem を本番イメージに入れない
- `BUNDLE_FROZEN="true"` … `Gemfile.lock` を書き換えさせず、Gemfile とずれていればビルドを失敗させる

そのため **Gemfile を変更したら `bundle install` して Gemfile.lock も commit** してください。
lock が古いままだと Docker ビルドが失敗します。

`Gemfile.lock` の `PLATFORMS` には Linux (`x86_64-linux` / `aarch64-linux`) を追加済みです。
追加していないと Linux 上の frozen ビルドで解決に失敗します。

## ログの方針

| 出力先 | 用途 | 例 |
| --- | --- | --- |
| `puts` (stdout) | 正常系の進行状況。「該当0件」も検索の正常な結果 | ヒット件数、選択したカード、送信成功 |
| `warn` (stderr) | 異常系。運用者が対処すべきもの | HTTP エラー、例外、画像以外のレスポンス |

`main.rb` で `$stdout.sync = true` を設定しています。fly.io / Docker では stdout が
バッファリングされ、`puts` がログに現れなかったりクラッシュ時に失われるためです。

## カード画像の検索仕様

tcgdex の `?name=` は**部分一致**検索です（`リザードン` で `リザードンex` や
`メガリザードンXex` も返る）。そのため取得後に完全一致と部分一致へ振り分け、
**完全一致があればそこから選び、無い場合のみ部分一致へフォールバック**します。

振り分けは「画像を持つカードで絞り込んだ後」に行います。完全一致カードが存在しても
画像が未整備な弾があり（例: `リザードン` の `PMCG1-021`）、先に振り分けると
画像を出せずに失敗するためです。
