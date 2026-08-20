---
name: diagnose-card-api
description: ポケカ公式サイトの非公開エンドポイント（card-search / products の resultAPI.php）が壊れていないかを検知し、壊れ方を切り分けて直す。/pokemon_card が「ティロンティロン」しか返さない、/pokemon_release が「取れなかった」と言う、rake test_live や CI の live ジョブが落ちた、定期点検したい、といったときに使う。
---

# 非公開エンドポイントの破損診断

この Bot は `www.pokemon-card.com` の**ドキュメント化されていない** 2 つのエンドポイントに
依存している。どちらも予告なく壊れる前提で、壊れたことに気付ける形にしてある。

| 用途 | エンドポイント | 使っている場所 |
| --- | --- | --- |
| カード画像の検索 | `/card-search/resultAPI.php` | `lib/pokemon_image.rb` |
| 発売予定の取得 | `/products/resultAPI.php` | `lib/pokemon_release.rb` |

**厄介なのは、壊れても HTTP 200 と `result: 1` が返るケースがあること。** ステータスコードでは
検知できないので、下記の手順で「レスポンスの中身が期待どおりか」を見る。

## 手順1: live テストで切り分ける

```sh
bundle exec rake test_live
```

これが全部通れば、両方のエンドポイントは生きている。ユーザーからの不調報告が
テストと食い違う場合は、fly.io 側の問題（`flyctl logs`）を先に疑う。

落ちたテスト名から、下の「既知の壊れ方」のどれかを特定する。テスト名が
壊れ方をそのまま表すように書いてあるので、まずアサーションのメッセージを読む。

- カード検索: `test/test_pokemon_card_search_live.rb`
- 発売予定: `test/test_pokemon_release_live.rb`

live テストは外部要因で落ちうるので、CI の `live` ジョブは `continue-on-error: true`
になっている。**ジョブのステータスは緑でもログを見ること。**

## 手順2: 生のリクエストで裏を取る

テストを疑う前に、素のリクエストで実際に何が返っているかを確認する。

```sh
# カード検索（正常なら hitCnt=90前後、searchCondition に「キーワード：リザードン」が入る）
curl -s -G "https://www.pokemon-card.com/card-search/resultAPI.php" \
  --data-urlencode "keyword=リザードン" \
  --data "page=1&illust=&sm_and_keyword=true&regulation_sidebar_form=all" \
  | head -c 600

# 発売予定（正常なら result=1 で products が並ぶ）
curl -s -G "https://www.pokemon-card.com/products/resultAPI.php" \
  --data "dateLowerY=2025&dateLowerM=1&dateLowerD=1&dateUpperY=2025&dateUpperM=12&dateUpperD=31&priceLower=0&priceUpper=99999&page=1" \
  | head -c 600
```

`--data-urlencode` と `-G` の組み合わせを使う（日本語をクエリに入れるため）。
`POST` は CloudFront に 403 で弾かれるので、必ず GET で叩く。

## 既知の壊れ方

### A. `sm_and_keyword` が効かなくなる（最も危険）

**症状:** `hitCnt` が 2 万件超（= 全カード）になり、`searchCondition` から「キーワード：」の
行が消える。検索語と無関係なカードが返るが、HTTP 200 / `result: 1` のまま。

**影響:** `select_cards_by_name` が名前で絞り直すため、無関係な画像が出ることはない。
代わりに **0 件になって `/pokemon_card` が「ティロンティロン」しか返さなくなる。**

**確認:** `sm_and_keyword` を外して叩いたときと `hitCnt` が変わらなければこれ。
正常なら「外すと 93 件 → 23165 件に跳ね、searchCondition からキーワード行が消える」。

```sh
curl -s -G "https://www.pokemon-card.com/card-search/resultAPI.php" \
  --data-urlencode "keyword=リザードン" --data "page=1&illust=&regulation_sidebar_form=all" \
  | grep -E '"hitCnt"|searchCondition' -A2
```

**対処:** 検索フォームが送っているパラメータ名が変わっている。
`https://www.pokemon-card.com/assets/js/card-search/index.js` と
`/card-search/index.php` の HTML の `name=` 属性を読んで、新しい名前を
`card_search_url` に反映する。

### B. パラメータ名やレスポンスのキーが変わる

**症状:** `cardList` が無い / `cardNameAltText` や `cardThumbFile` が nil になる。
`card_search_page` が「想定外のレスポンスです」を stderr に出す。

**対処:** 手順2 の curl でレスポンス全体を見て、キー名の変更を `build_card` に反映する。
`cardNameViewText` は HTML を含むので**名前には使わない**（旧メガ表記が
`<span class="pcg pcg-megamark"></span>リザードンEX` で返る）。

### C. `regulation_sidebar_form` が効かなくなる

**症状:** `searchCondition` が「レギュレーション：スタンダード」のまま。ヒット数が
1/10 くらいに減り、旧弾のカードが出せなくなる（「ピカチュウ」290件 → 24件）。

**対処:** A と同じ手順でパラメータ名を追う。

### D. 画像の URL 形式が変わる

**症状:** 検索は通るのに `http_get_image` が「画像ではないレスポンス」や HTTP 404 を出す。

**対処:** `cardThumbFile` の値を確認する。相対パスと絶対URLの両方が来るので、
組み立ては `absolute_pokemon_card_url`（`lib/pokemon_card_site.rb`）に任せる。

### E. 発売日の表記が変わる

**症状:** `[build_product] 発売日を解釈できませんでした` が stderr に並び、発売予定が
0 件になる。

**背景:** 発売日は `"2026年 9月16日（水）"` という**表示用の日本語文字列**で返る。
月が1桁だと桁揃えの半角スペースが入る。

**対処:** `parse_japanese_release_date` の正規表現を実データに合わせる。
`test/test_pokemon_release_live.rb` の `test_実データの発売日をすべて解釈できる` が
実データ全件で検証しているので、そこが緑になるまで直す。

### F. ページングの終端が変わる

**症状:** リクエストが止まらない、または同じカードが重複する。

**背景:** `maxPage` を超える `page` を投げると、空ではなく**最終ページが返ってくる**。
そのため終端は `maxPage` で判定している（`lib/pokemon_image.rb` の `search_pokemon_cards`）。

**対処:** `maxPage` の意味が変わっていないか手順2 で確認する。空判定に切り替えてはいけない。

### G. CloudFront に弾かれる（403）

**症状:** レスポンスが JSON ではなく `<TITLE>ERROR: The request could not be satisfied</TITLE>` を含む HTML。

**対処:** リクエストメソッドを確認する。`POST` は許可されていない。GET なら
User-Agent 無しでも通るので、UA を疑う必要はない（確認済み）。
それでも 403 なら相手側のアクセス制限なので、**回避策を実装せず**、
一時的な障害として扱い時間を置いて再確認する。

## 直したあとにやること

1. `bundle exec rake test` — オフラインテストが通ること（skip 0 件）
2. `bundle exec rake test_live` — 疎通が戻ったこと
3. **壊れ方を検知できるテストを live テストに足す。** 今回のパラメータ変更を
   次も検知できるアサーションが無ければ、同じ壊れ方をまた見逃す
4. 壊れ方が新種なら、この SKILL.md の「既知の壊れ方」に追記する
5. `README.md` の「外部データソース」に前提が書いてあるので、前提が変わったら直す

## やってはいけないこと

- **アクセス頻度を上げて総当たりする。** 非公開エンドポイントに無断で負荷をかける。
  切り分けの curl は数回で足りる
- **UA 偽装やアクセス制限の回避を実装する。** 403 が続くなら相手の意思として扱う
- **公式サイトの画像を発売予定 (`/pokemon_release`) の応答に載せる。** 画像を出すのは
  `/pokemon_card` だけに限定していて、発売予定は発売日・商品名・価格・リンクのみに留める
