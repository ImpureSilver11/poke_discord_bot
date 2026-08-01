require_relative 'test_helper'

# 実際の tcgdex API に対する疎通テスト。
# 外部サービスに依存するため既定ではスキップし、LIVE=1 のときだけ実行する。
#
#   LIVE=1 rake test
#
class TestTcgdexLive < PokeTestCase
  def setup
    super
    skip '外部APIに接続するテスト（LIVE=1 で実行）' unless ENV['LIVE'] == '1'

    # スタブではなく実物の HTTP 実装を使う
    StubHttp.json_handler  = REAL_HTTP_GET_JSON
    StubHttp.image_handler = REAL_HTTP_GET_IMAGE
  end

  def test_カード検索APIに疎通できる
    cards = silently { tcgdex_search_cards('ピカチュウ') }

    refute_empty cards, 'tcgdex の検索APIから結果が返らない'
    assert cards.all? { |c| c['id'] && c['name'] }, 'id / name を持たないレスポンスがある'
  end

  def test_APIは部分一致検索である
    # この前提が崩れると完全一致/部分一致の分離そのものが不要になるため、明示的に固定する
    cards = silently { tcgdex_search_cards('リザードン') }
    _, partial = partition_cards_by_match(cards, 'リザードン')

    refute_empty partial, 'API が部分一致を返さなくなっている（実装の見直しが必要）'
  end

  def test_完全一致するカードを検索できる
    cards = silently { tcgdex_search_cards('ヒトカゲ') }
    exact, = partition_cards_by_match(cards, 'ヒトカゲ')

    refute_empty exact, '「ヒトカゲ」に完全一致するカードが取得できない'
  end

  def test_画像を実際にダウンロードできる
    bytes, filename = silently { download_first_tcg_pokemon_image('ピカチュウ') }

    refute_nil bytes, '画像のダウンロードに失敗した'
    assert_operator bytes.bytesize, :>, 1_000, "画像が小さすぎる: #{bytes.bytesize} bytes"
    assert_match(/\Apokemon_card\.(webp|png|jpg|gif)\z/, filename)
  end

  def test_存在しない検索語では_nil_を返す
    assert_nil silently { download_first_tcg_pokemon_image('ぜったいにないポケモンXYZ') }
  end
end
