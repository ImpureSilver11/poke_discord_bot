require_relative 'test_helper'
require 'pokemon_release'

# ポケカ公式サイトの商品情報API（非公式に叩いているエンドポイント）への疎通テスト。
# 予告なく壊れうる相手なので、既定の rake test からは外して LIVE=1 のときだけ実行する。
#
#   bundle exec rake test_live
#
class TestPokemonReleaseLive < PokeTestCase
  # 発売予定の有無は時期によって 0 件になりうる。
  # 疎通とレスポンス形状の検証には、確実に商品が存在する過去の範囲を使う。
  PAST_RANGE_START  = Date.new(2025, 1, 1)
  PAST_RANGE_MONTHS = 12

  def setup
    super
    skip '外部APIに接続するテスト（LIVE=1 で実行）' unless ENV['LIVE'] == '1'

    StubHttp.json_handler = REAL_HTTP_GET_JSON
  end

  def past_products
    silently { fetch_upcoming_products(today: PAST_RANGE_START, months: PAST_RANGE_MONTHS) }
  end

  def test_商品情報APIに疎通できる
    products = past_products

    refute_nil   products, '公式の商品情報APIからレスポンスが得られない'
    refute_empty products, "#{PAST_RANGE_START} からの1年間に商品が1件も無いのはおかしい"
  end

  def test_表示に必要な項目がすべて揃っている
    past_products.each do |product|
      assert_kind_of Date, product[:release_date]
      refute_empty   product[:title], "商品名が空: #{product.inspect}"
      assert         product[:url].start_with?('https://'), "URLが絶対URLでない: #{product[:url]}"
    end
  end

  # 発売日は "2026年 9月16日（水）" のような表示用の文字列なので、
  # 表記が変わるとパースが黙って全滅する。実データ全件で確認する。
  def test_実データの発売日をすべて解釈できる
    _out, err = capture_io { fetch_upcoming_products(today: PAST_RANGE_START, months: PAST_RANGE_MONTHS) }

    refute_includes err, '[build_product]', '発売日を解釈できない商品がある（表記が変わった可能性）'
  end

  def test_発売日の昇順で返る
    dates = past_products.map { |p| p[:release_date] }

    assert_equal dates.sort, dates
  end

  # 拡張パックだけでなく構築デッキ・その他・周辺グッズまで返っていること
  # （productType を指定しない = すべて、という前提が崩れていないかの確認）
  def test_複数の商品種別が含まれる
    types = past_products.map { |p| p[:type] }.uniq

    assert_operator types.size, :>, 1, "商品種別が1つしか無い: #{types.inspect}"
  end

  # 実際にコマンドが返す本文が Discord の制限内に収まること
  def test_今後の予定を本文にできる
    products = silently { fetch_upcoming_products }
    refute_nil products, '今後の発売予定の取得に失敗した'

    text = format_upcoming_products(products)
    refute_empty    text
    assert_operator text.length, :<=, 2_000
  end
end
