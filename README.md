# poke_discord_bot

## セットアップ

```sh
bundle install
```

gem は Gemfile / Gemfile.lock で管理します。`rake` と `minitest` は
`group :development, :test` に入れており、本番イメージには入りません。

## テスト

**`rake test` は skip 0 件で常に全部通る状態を保ちます。** 落ちたら壊れている合図です。

```sh
bundle exec rake test        # 既定。外部APIに接続しない（skip 0 件）
bundle exec rake test_live   # 実 tcgdex API への疎通テストのみ
bundle exec rake test_all    # 上記の両方
```

外部APIに接続するテストは `test/test_*_live.rb` に分け、`rake test` の対象から
除外しています。ネットワーク障害や相手側の仕様変更で既定のテストが落ちないようにするためです。

個別のファイルだけ実行する場合:

```sh
bundle exec ruby -Ilib -Itest test/test_pokemon_image.rb
```

### 常に通る状態を保つ仕組み

多重に関門を置いていますが、**最後の砦は Docker ビルド内のテストステージ**です。

| 仕組み | 効く経路 | 内容 |
| --- | --- | --- |
| `rake test` から live テストを除外 | 全部 | 外部要因で落ちない。skip も 0 件 |
| pre-push フック | `git push` | 失敗したら push を中止 |
| CI (`test.yml`) | push / PR | 早く気付くための一次チェック |
| **Docker の test ステージ** | **イメージを作る経路すべて** | **テストが落ちるとイメージが作られない = デプロイ不能** |

Docker ビルドに内包しているのは、ローカルの `fly deploy` が git を経由せず
作業ディレクトリをそのまま送るため、pre-push フックも GitHub Actions もすり抜けるからです。
実際にこれで一度、未コミットの壊れたコードが本番に出て起動できなくなりました。

pre-push フックの有効化（各自のマシンで1回だけ）:

```sh
bundle exec rake hooks:install    # git config core.hooksPath .githooks
bundle exec rake hooks:uninstall  # 解除
```

緊急時は `git push --no-verify` で飛ばせます（Docker 側の関門は残ります）。

### 構成

| ファイル | 内容 |
| --- | --- |
| `test/test_helper.rb` | HTTP 層 (`http_get_json` / `http_get_image`) をスタブに差し替える仕組みとフィクスチャ |
| `test/test_commands.rb` | コマンド登録・@メンション時のヘルプ。代用 Bot で Discord に繋がず検証 |
| `test/test_pokemon_image.rb` | カード検索・画像選択のロジック。ネットワーク非依存で決定的 |
| `test/test_pokemon_stats.rb` | 種族値の描画と `data/pokemon_data.json` の整合性チェック |
| `test/test_tcgdex_live.rb` | 実 API への疎通確認。`rake test` の対象外（`rake test_live` で実行） |

テスト中に未スタブの HTTP 呼び出しが起きると `StubHttp::NotConfigured` を投げて失敗するため、
意図しない外部アクセスが混入しないようになっています。

## CI

`.github/workflows/test.yml`

| ジョブ | 実行契機 | 内容 |
| --- | --- | --- |
| `test` | push (main) / PR / 手動 / `fly-deploy` からの呼び出し | `bundle exec rake test`。外部APIに繋がないので安定して落とせる |
| `live` | 手動 / 毎週月曜 | `bundle exec rake test_live`。tcgdex の仕様変更・障害の検知用 |

`live` は `continue-on-error: true` です。外部要因の失敗で「テストは常に全部通る」という
シグナルを汚さないためで、**結果はジョブのステータスではなくログで確認してください。**

`test.yml` は `workflow_call` に対応しており、`fly-deploy.yml` がこれを `needs` します。
Docker ビルドでもテストは走るので二重ですが、CI 側のほうが速く失敗するため
早期のフィードバック用として残しています。

Ruby のバージョンは Dockerfile の `ARG RUBY_VERSION` と揃えています。
片方だけ上げると本番とテスト環境がずれるため、変更時は両方直してください。

## Docker / 本番構成

### ステージ構成

| ステージ | 役割 |
| --- | --- |
| `base` | Ruby + bundler。`BUNDLE_WITHOUT` / `BUNDLE_FROZEN` を設定 |
| `build` | 本番用 gem をビルド・インストール |
| `test` | `build` にテスト用 gem を足して `rake test` を実行。**落ちるとビルド失敗** |
| 最終 | `build` から gem を、コンテキストから実行に必要なファイルだけを COPY |

最終ステージは `COPY --from=test /tmp/tests-passed` で `test` ステージに依存させています。
この依存が無いと BuildKit がテストステージを丸ごとスキップするため、**消さないでください。**

gem は `test` ではなく `build` から取るので、テスト用 gem は本番イメージに入りません。
アプリのコードも `main.rb` / `lib` / `data` だけを明示的に COPY しており、
`test/` や `Rakefile`、`scripts/` は含まれません（`scripts/` はローカル実行用のため）。

### bundler の設定

- `BUNDLE_WITHOUT="development:test"` … テスト用 gem を本番イメージに入れない
- `BUNDLE_FROZEN="true"` … `Gemfile.lock` を書き換えさせず、Gemfile とずれていればビルドを失敗させる

`test` ステージではテスト用 gem が要るので打ち消していますが、環境変数を空にするだけでは
足りません。`build` の `bundle install` が `/usr/local/bundle/config` に `without` を
永続化するため、`bundle config unset without` も必要です。

そのため **Gemfile を変更したら `bundle install` して Gemfile.lock も commit** してください。
lock が古いままだと Docker ビルドが失敗します。

`Gemfile.lock` の `PLATFORMS` には Linux (`x86_64-linux` / `aarch64-linux`) を追加済みです。
追加していないと Linux 上の frozen ビルドで解決に失敗します。

## コマンドとヘルプ

コマンドの定義は `lib/commands.rb` の `COMMAND_SPECS` が唯一の定義元です。
スラッシュコマンドの登録と、@メンション時に返すヘルプ本文の両方をここから生成します。

**新しいコマンドを追加する手順:**

1. `COMMAND_SPECS` に定義（`name` / `description` / `options` / `example`）を足す
2. `bot.application_command(:name) do |event| ... end` でハンドラを書く

ヘルプは自動で追従するので手を入れる必要はありません。逆にヘルプを別に手書きすると
必ず実装とずれるため、`COMMAND_SPECS` 以外に説明文を置かないでください。
`test/test_commands.rb` が「全コマンドがヘルプに載っていること」を検証しています。

**@メンションについて:**

- `bot.mention` は payload の `mentions` 配列で発火します。`mentions` は
  MESSAGE_CONTENT（特権 intent）の制限対象外なので、**intent の追加設定は不要**です
  （discordrb 3.5.0 はそもそも `message_content` intent に対応していません）
- 他の bot からのメンションは無視します（相互に反応し合うループを防ぐため）
- 自分自身のメッセージは discordrb 側で除外されます

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

## 種族値データ (`data/pokemon_data.json`)

取得スクリプトはどちらも PokeAPI が正典です。**種族値を手書きしないでください。**

```sh
ruby scripts/fetch_missing_pokemon.rb              # 未登録の No. を追加
DRY_RUN=1 ruby scripts/fetch_mega_evolutions.rb    # メガシンカの差分を確認（書き込まない）
ruby scripts/fetch_mega_evolutions.rb              # メガシンカを追加
FIX_EXISTING=1 ruby scripts/fetch_mega_evolutions.rb  # 既存が API と食い違う場合に上書き
```

`fetch_mega_evolutions.rb` の仕様:

- 並び順は `no` の安定ソート。メガは基本形の直後に入り、既存の並びは変わらない
- 日本語名は `pokemon-form` の `form_names`（ゲーム内ローカライズ由来）を使う
- PokeAPI は「メガリザードンＸ」のように英数を全角で返すため、**半角へ正規化**して既存表記に合わせる
- ゲンシカイキは `form_names` が「ゲンシカイキのすがた」という汎用ラベルで種別が判別できないため、
  種族名から `ゲンシ + 種族名` を組み立てる
- 同名・同値のフォーム（シャリタツの3形態など）は1件に統合する
- 既存と食い違う場合は既定では**報告のみ**。誤りを確認してから `FIX_EXISTING=1` で上書きする
- PokeAPI 側の特性が空のときは比較対象から外す（欠落で既存の正しい値を消さないため）

メガディメンション（Legends Z-A の DLC）の一部は PokeAPI に特性が未収録で
`abilities` が空になります。表示側は「特性: 不明」にフォールバックします。
