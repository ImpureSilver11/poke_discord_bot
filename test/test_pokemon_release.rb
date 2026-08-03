require_relative 'test_helper'
require 'pokemon_release'

class PokeReleaseTestCase < PokeTestCase
  TODAY = Date.new(2026, 8, 3)

  # 公式APIの1件分のレスポンス形状を模した Hash を作る
  def product_json(title:, release_date:, type: '拡張パック', price: '360円（税込）', link: '/ex/m6/')
    {
      'productTitle'     => title,
      'productType'      => type,
      'tumbsImg'         => '/products/2026/images/dummy.jpg',
      'releaseDate'      => release_date,
      'priceTxt'         => price,
      'description'      => 'せつめい',
      'beginnerFlg'      => 0,
      'storesAvailable'  => '',
      'link_cardList'    => '',
      'link_detailPage'  => link,
      'link_pokemonCenter' => '',
    }
  end

  def api_response(products, result: 1)
    { 'result' => result, 'errMsg' => '', 'thisPage' => 1, 'maxPage' => 1,
      'hitCnt' => products.size, 'products' => products }
  end

  # API が返す JSON を固定して fetch_upcoming_products を呼ぶ
  def fetch(products, result: 1, today: TODAY)
    StubHttp.json_handler = ->(_url) { api_response(products, result: result) }
    silently { fetch_upcoming_products(today: today) }
  end
end

# 表示用の日本語文字列から Date を起こせるか。
# 月が1桁だと桁揃えの半角スペースが入るのが実データの厄介なところ。
class TestParseJapaneseReleaseDate < PokeReleaseTestCase
  def test_通常の表記
    assert_equal Date.new(2026, 10, 16), parse_japanese_release_date('2026年10月16日（金）')
  end

  def test_月が1桁のときの桁揃えスペース
    assert_equal Date.new(2026, 9, 16), parse_japanese_release_date('2026年 9月16日（水）')
  end

  def test_曜日が無くても読める
    assert_equal Date.new(2026, 5, 22), parse_japanese_release_date('2026年5月22日')
  end

  def test_全角数字も読める
    assert_equal Date.new(2026, 9, 16), parse_japanese_release_date('２０２６年９月１６日（水）')
  end

  def test_日付として存在しない値は_nil
    assert_nil parse_japanese_release_date('2026年2月30日')
  end

  def test_解釈できない文字列は_nil
    assert_nil parse_japanese_release_date('発売日未定')
    assert_nil parse_japanese_release_date('')
    assert_nil parse_japanese_release_date(nil)
  end
end

# link_detailPage は相対パスのことも別ドメインの絶対URLのこともある
class TestAbsoluteProductUrl < PokeReleaseTestCase
  def test_相対パスは公式サイトのURLにする
    assert_equal 'https://www.pokemon-card.com/ex/m6/', absolute_product_url('/ex/m6/')
  end

  def test_先頭のスラッシュが無くても繋げる
    assert_equal 'https://www.pokemon-card.com/ex/m6/', absolute_product_url('ex/m6/')
  end

  def test_絶対URLはそのまま使う
    url = 'https://www.30th.pokemon-card.com/product/m6a'
    assert_equal url, absolute_product_url(url)
  end

  def test_空なら_nil
    assert_nil absolute_product_url('')
    assert_nil absolute_product_url('  ')
    assert_nil absolute_product_url(nil)
  end
end

# API に渡す日付範囲の組み立て
class TestProductsApiUrl < PokeReleaseTestCase
  def params(url)
    URI.decode_www_form(URI(url).query).to_h
  end

  def test_発売日の下限と上限を分解して渡す
    got = params(products_api_url(from: Date.new(2026, 8, 3), to: Date.new(2026, 10, 3)))

    assert_equal %w[2026 8 3],  got.values_at('dateLowerY', 'dateLowerM', 'dateLowerD')
    assert_equal %w[2026 10 3], got.values_at('dateUpperY', 'dateUpperM', 'dateUpperD')
  end

  # productType を渡さないと「すべて」になる。周辺グッズまで含めたいので指定しない。
  def test_商品種別で絞り込まない
    refute_includes params(products_api_url(from: TODAY, to: TODAY >> 2)), 'productType'
  end

  def test_価格の下限と上限を必ず渡す
    got = params(products_api_url(from: TODAY, to: TODAY >> 2))

    assert_equal RELEASE_PRICE_LOWER.to_s, got['priceLower']
    assert_equal RELEASE_PRICE_UPPER.to_s, got['priceUpper']
  end
end

class TestFetchUpcomingProducts < PokeReleaseTestCase
  def test_取得した商品を発売日の昇順に並べる
    products = fetch([
                       product_json(title: '10月のやつ', release_date: '2026年10月16日（金）'),
                       product_json(title: '9月のやつ',  release_date: '2026年 9月16日（水）'),
                     ])

    assert_equal %w[9月のやつ 10月のやつ], products.map { |p| p[:title] }
  end

  # 同日に複数出る回（カードセット9種など）で並び順が実行ごとに変わらないこと
  def test_同じ発売日なら商品名で安定して並ぶ
    products = fetch([
                       product_json(title: 'ぶ', release_date: '2026年 9月16日（水）'),
                       product_json(title: 'あ', release_date: '2026年 9月16日（水）'),
                       product_json(title: 'い', release_date: '2026年 9月16日（水）'),
                     ])

    assert_equal %w[あ い ぶ], products.map { |p| p[:title] }
  end

  def test_今日発売のものは含める
    products = fetch([product_json(title: '今日発売', release_date: '2026年 8月 3日（月）')])

    assert_equal ['今日発売'], products.map { |p| p[:title] }
  end

  # API の日付範囲の境界の扱いが変わっても、過去のものが混ざらないようにしている
  def test_今日より前の発売日は落とす
    products = fetch([
                       product_json(title: '発売済み', release_date: '2026年 7月31日（金）'),
                       product_json(title: 'これから', release_date: '2026年 9月16日（水）'),
                     ])

    assert_equal ['これから'], products.map { |p| p[:title] }
  end

  def test_発売日が読めない商品は落とす
    products = fetch([
                       product_json(title: '未定', release_date: '発売日未定'),
                       product_json(title: '確定', release_date: '2026年 9月16日（水）'),
                     ])

    assert_equal ['確定'], products.map { |p| p[:title] }
  end

  def test_表示に必要な項目を取り出す
    product = fetch([product_json(title: '拡張パック「30th CELEBRATION」',
                                  release_date: '2026年 9月16日（水）',
                                  type: '拡張パック',
                                  price: '360円（税込）',
                                  link: 'https://www.30th.pokemon-card.com/product/m6a')]).first

    assert_equal Date.new(2026, 9, 16),                            product[:release_date]
    assert_equal '拡張パック「30th CELEBRATION」',                  product[:title]
    assert_equal '拡張パック',                                      product[:type]
    assert_equal '360円（税込）',                                   product[:price]
    assert_equal 'https://www.30th.pokemon-card.com/product/m6a',  product[:url]
  end

  def test_詳細ページが無ければ商品情報ページへ逃がす
    product = fetch([product_json(title: 'リンクなし', release_date: '2026年 9月16日（水）', link: '')]).first

    assert_equal POKEMON_CARD_PRODUCTS_PAGE, product[:url]
  end

  def test_予定が無ければ空配列
    assert_equal [], fetch([])
  end

  # nil（取得失敗）と []（予定なし）は表示を出し分けるので、混同しないこと
  def test_APIがエラーを返したら_nil
    assert_nil fetch([], result: 0)
  end

  def test_想定外のレスポンスなら_nil
    StubHttp.json_handler = ->(_url) { nil }
    assert_nil silently { fetch_upcoming_products(today: TODAY) }

    StubHttp.json_handler = ->(_url) { { 'result' => 1 } }
    assert_nil silently { fetch_upcoming_products(today: TODAY) }
  end

  def test_今日から指定した月数先までを問い合わせる
    requested = nil
    StubHttp.json_handler = lambda { |url|
      requested = URI.decode_www_form(URI(url).query).to_h
      api_response([])
    }
    silently { fetch_upcoming_products(today: TODAY, months: 2) }

    assert_equal %w[2026 8 3],  requested.values_at('dateLowerY', 'dateLowerM', 'dateLowerD')
    assert_equal %w[2026 10 3], requested.values_at('dateUpperY', 'dateUpperM', 'dateUpperD')
  end

  def test_失敗はstderrに記録する
    StubHttp.json_handler = ->(_url) { nil }
    _out, err = capture_io { fetch_upcoming_products(today: TODAY) }

    assert_includes err, '[fetch_upcoming_products]'
  end

  # 「該当0件」は検索の正常な結果なので stdout 側
  def test_成功はstdoutに記録しstderrは空
    StubHttp.json_handler = ->(_url) { api_response([]) }
    out, err = capture_io { fetch_upcoming_products(today: TODAY) }

    assert_includes out, '[fetch_upcoming_products]'
    assert_empty err
  end
end

class TestFormatUpcomingProducts < PokeReleaseTestCase
  def products(count, release_date: '2026年 9月16日（水）')
    fetch(Array.new(count) { |i| product_json(title: format('商品%02d', i), release_date: release_date) })
  end

  def test_発売日ごとにまとめて見出しを付ける
    text = format_upcoming_products(fetch([
                                            product_json(title: '9月のやつ',  release_date: '2026年 9月16日（水）'),
                                            product_json(title: '10月のやつ', release_date: '2026年10月16日（金）'),
                                          ]))

    assert_includes text, '**2026年9月16日（水）**'
    assert_includes text, '**2026年10月16日（金）**'
    assert_operator text.index('9月16日'), :<, text.index('10月16日'), '発売日の早い順に並んでいない'
  end

  def test_商品名をリンクにして種別と価格を添える
    text = format_upcoming_products(fetch([
                                            product_json(title: '拡張パック「30th CELEBRATION」',
                                                         release_date: '2026年 9月16日（水）',
                                                         link: 'https://www.30th.pokemon-card.com/product/m6a'),
                                          ]))

    assert_includes text, '[拡張パック「30th CELEBRATION」](https://www.30th.pokemon-card.com/product/m6a)'
    assert_includes text, '拡張パック / 360円（税込）'
  end

  def test_上限を超えたら切り詰めて残数を知らせる
    text = format_upcoming_products(products(12), limit: 10)

    assert_includes    text, '商品09'
    refute_includes    text, '商品10'
    assert_includes    text, 'ほか2件'
    assert_includes    text, POKEMON_CARD_PRODUCTS_PAGE
  end

  def test_上限以内なら残数を出さない
    refute_includes format_upcoming_products(products(3), limit: 10), 'ほか'
  end

  # nil（取得失敗）と []（予定なし）でユーザーに伝えることが違う
  def test_予定が無いことを伝える
    text = format_upcoming_products([])

    assert_includes text, '発表されてない'
    assert_includes text, POKEMON_CARD_PRODUCTS_PAGE
  end

  def test_取得に失敗したことを伝える
    text = format_upcoming_products(nil)

    assert_includes text, '取れなかった'
    assert_includes text, POKEMON_CARD_PRODUCTS_PAGE
    refute_includes text, '発表されてない'
  end

  # Discord のメッセージ上限は 2000 文字
  def test_上限件数まで並べても2000文字以内
    long = fetch(Array.new(RELEASE_MAX_ITEMS) do |i|
      product_json(title: "「30th CELEBRATION カードセット なんとかかんとか#{i}」",
                   release_date: '2026年10月16日（金）',
                   type: 'その他の商品',
                   price: '1,200円（税込）',
                   link: 'https://www.30th.pokemon-card.com/product/cardset')
    end)

    assert_operator format_upcoming_products(long).length, :<=, 2_000
  end

  def test_それでも超える場合は打ち切る
    huge = fetch(Array.new(RELEASE_MAX_ITEMS) do |i|
      product_json(title: "#{'なが' * 200}#{i}", release_date: '2026年10月16日（金）')
    end)
    text = format_upcoming_products(huge)

    assert_operator text.length, :<=, 2_000
    assert text.end_with?('...'), '打ち切りの目印がない'
  end

  # 商品名の角括弧をそのまま出すとマスクリンクの記法が壊れる
  def test_商品名の角括弧を潰す
    text = format_upcoming_products(fetch([
                                            product_json(title: '[限定] なにか', release_date: '2026年 9月16日（水）'),
                                          ]))

    assert_includes text, '［限定］ なにか'
    assert_equal 1, text.scan('](').size, 'リンクの記法が壊れている'
  end
end
