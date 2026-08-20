require_relative 'test_helper'

# ポケカ公式サイトのカード検索API（非公式に叩いているエンドポイント）への疎通テスト。
# 予告なく壊れうる相手なので、既定の rake test からは外して LIVE=1 のときだけ実行する。
#
#   bundle exec rake test_live
#
# ここが落ちたときの切り分けは .claude/skills/diagnose-card-api/ を参照。
class TestPokemonCardSearchLive < PokeTestCase
  def setup
    super
    skip '外部APIに接続するテスト（LIVE=1 で実行）' unless ENV['LIVE'] == '1'

    # スタブではなく実物の HTTP 実装を使う
    StubHttp.json_handler  = REAL_HTTP_GET_JSON
    StubHttp.image_handler = REAL_HTTP_GET_IMAGE
  end

  def test_カード検索APIに疎通できる
    body = silently { card_search_page('ピカチュウ') }

    refute_nil body, '公式のカード検索APIからレスポンスが得られない'
    assert_operator body['hitCnt'].to_i, :>, 0, '「ピカチュウ」が0件になっている'
    refute_empty body['cardList'], 'hitCnt はあるのに cardList が空'
  end

  # sm_and_keyword が効かなくなると keyword が黙って無視され、全カード（5000件超）が返る。
  # HTTP ステータスも result も正常なままなので、これが唯一の検知手段。
  def test_キーワードでの絞り込みが効いている
    body = silently { card_search_page('リザードン') }
    refute_nil body

    conditions = body['searchCondition'].to_a.join(' ')
    assert_includes conditions, 'キーワード',
                    "検索条件にキーワードが反映されていない（sm_and_keyword の仕様変更？）: #{conditions}"
    assert_operator body['hitCnt'].to_i, :<, 1_000,
                    "ヒット数が多すぎる。キーワードが無視されて全件返っている可能性がある: #{body['hitCnt']}"
  end

  # regulation_sidebar_form=all を渡さないとスタンダードのみに絞られ、旧弾が出せなくなる
  def test_全レギュレーションが対象になっている
    body = silently { card_search_page('ピカチュウ') }

    assert_includes body['searchCondition'].to_a.join(' '), 'すべてのカード',
                    'レギュレーションの絞り込みが解除されていない'
  end

  def test_該当が無い検索語では0件が返る
    body = silently { card_search_page('ぜったいにないポケモンXYZ') }

    refute_nil body, '0件でもレスポンス自体は正常に返るはず'
    assert_equal 0, body['hitCnt'].to_i
    assert_empty body['cardList']
  end

  def test_表示に必要な項目がすべて揃っている
    cards = silently { search_pokemon_cards('ヒトカゲ') }

    refute_empty cards
    cards.each do |card|
      refute_empty card['id'],   "cardID が空: #{card.inspect}"
      refute_empty card['name'], "カード名が空: #{card.inspect}"
      assert card['image'].start_with?('https://'), "画像URLが絶対URLでない: #{card['image']}"
    end
  end

  # cardNameViewText には HTML が混ざる。alt を使う前提が崩れていないことの確認。
  def test_カード名にHTMLが混ざらない
    cards = silently { search_pokemon_cards('リザードン') }

    cards.each do |card|
      refute_includes card['name'], '<', "カード名にHTMLが混ざっている: #{card['name'].inspect}"
    end
  end

  # keyword はカード名だけでなくカードテキストも検索対象にしている。
  # この前提が崩れると select_cards_by_name が不要になるため、明示的に固定する。
  def test_キーワードはカードテキストも拾う
    cards = silently { search_pokemon_cards('サンド') }
    refute_empty cards

    unrelated = cards.reject { |c| c['name'].include?('サンド') }
    refute_empty unrelated,
                 '名前に検索語を含まないカードが返ってこない（名前だけの検索に変わった？）'
  end

  def test_完全一致するカードを検索できる
    cards = silently { search_pokemon_cards('ヒトカゲ') }
    exact, = partition_cards_by_match(select_cards_by_name(cards, 'ヒトカゲ'), 'ヒトカゲ')

    refute_empty exact, '「ヒトカゲ」に完全一致するカードが取得できない'
  end

  # 複数ページある検索語で、最終ページまで辿れること（1ページ目で止まっていない）
  def test_複数ページを辿れる
    body = silently { card_search_page('リザードン') }
    assert_operator body['maxPage'].to_i, :>, 1, '「リザードン」が1ページに収まるのは想定外'

    cards = silently { search_pokemon_cards('リザードン') }
    assert_operator cards.size, :>, body['cardList'].size, '2ページ目以降が結合されていない'
  end

  # 公式サイトを取得先にしている理由。新しい弾のカードにも画像が付いていること。
  def test_新しい弾のカードにも画像がある
    cards = silently { search_pokemon_cards('メガリザードン') }

    refute_empty cards, '新しい弾のカードが画像付きで取得できない'
  end

  def test_画像を実際にダウンロードできる
    bytes, filename = silently { download_pokemon_card_image('ピカチュウ') }

    refute_nil bytes, '画像のダウンロードに失敗した'
    assert_operator bytes.bytesize, :>, 1_000, "画像が小さすぎる: #{bytes.bytesize} bytes"
    # Discord の添付上限（無課金サーバーは 8MB）に収まること
    assert_operator bytes.bytesize, :<, 8 * 1024 * 1024, "画像が大きすぎる: #{bytes.bytesize} bytes"
    assert_match(/\Apokemon_card\.(webp|png|jpg|gif)\z/, filename)
  end

  def test_存在しない検索語では_nil_を返す
    assert_nil silently { download_pokemon_card_image('ぜったいにないポケモンXYZ') }
  end
end
