require_relative 'test_helper'

# カード名の正規化
class TestNormalizeCardName < PokeTestCase
  def test_前後の空白を無視する
    assert_equal 'ピカチュウ', normalize_card_name('  ピカチュウ  ')
  end

  def test_英字の大小差を無視する
    assert_equal normalize_card_name('Pikachu'), normalize_card_name('pikachu')
  end

  def test_nil_を空文字として扱う
    assert_equal '', normalize_card_name(nil)
  end
end

# 完全一致 / 部分一致の振り分け
class TestPartitionCardsByMatch < PokeTestCase
  def test_完全一致と部分一致に分割する
    cards = [
      card('SV3-125', 'リザードンex'),
      card('S1-013',  'リザードン'),
      card('M2-013',  'メガリザードンXex'),
      card('SM10-007', 'レシラム&リザードンGX'),
    ]
    exact, partial = partition_cards_by_match(cards, 'リザードン')

    assert_equal ['リザードン'], exact.map { |c| c['name'] }
    assert_equal ['リザードンex', 'メガリザードンXex', 'レシラム&リザードンGX'], partial.map { |c| c['name'] }
  end

  def test_完全一致が無い場合は全て部分一致になる
    cards = [card('SV10-040', 'ロケット団のソーナンス')]
    exact, partial = partition_cards_by_match(cards, 'ソーナンス')

    assert_empty exact
    assert_equal 1, partial.size
  end

  def test_検索語の空白差を吸収して完全一致にする
    cards = [card('E1-016', 'ピカチュウ')]
    exact, = partition_cards_by_match(cards, ' ピカチュウ ')

    assert_equal 1, exact.size
  end

  def test_同名カードが複数ある場合は全て完全一致に入る
    cards = [card('E1-016', 'ピカチュウ'), card('S12-024', 'ピカチュウ'), card('SV8-033', 'ピカチュウex')]
    exact, partial = partition_cards_by_match(cards, 'ピカチュウ')

    assert_equal %w[E1-016 S12-024], exact.map { |c| c['id'] }
    assert_equal %w[SV8-033], partial.map { |c| c['id'] }
  end
end

# 画像選択のロジック（今回の主眼）
class TestDownloadImageMatching < PokeTestCase
  def test_完全一致があればそれを選ぶ
    stub_search [
      card('SV3-125', 'リザードンex'),
      card('S1-013',  'リザードン'),
      card('M2-013',  'メガリザードンXex'),
    ]
    bytes, = silently { download_first_tcg_pokemon_image('リザードン') }

    assert_equal 'S1-013', picked_id(bytes)
  end

  def test_完全一致が無い場合は部分一致にフォールバックする
    stub_search [card('SV10-040', 'ロケット団のソーナンス')]
    bytes, = silently { download_first_tcg_pokemon_image('ソーナンス') }

    assert_equal 'SV10-040', picked_id(bytes)
  end

  # 回帰テスト: 実際の「リザードン」はこのケース。完全一致カード PMCG1-021 が
  # API 上に存在するが image を持たないため、画像フィルタで除外されて
  # 部分一致にフォールバックする必要がある。
  # 画像フィルタより先に一致度で分割してしまうと、ここで nil を返してしまう。
  def test_完全一致が画像を持たない場合は部分一致にフォールバックする
    stub_search [
      card('PMCG1-021', 'リザードン',   image: false),
      card('SV3-125',   'リザードンex', image: true),
    ]
    bytes, = silently { download_first_tcg_pokemon_image('リザードン') }

    refute_nil bytes, '完全一致が画像なしのとき部分一致に落ちていない'
    assert_equal 'SV3-125', picked_id(bytes)
  end

  def test_完全一致が複数ある場合も必ず完全一致の中から選ぶ
    stub_search [
      card('E1-016',  'ピカチュウ'),
      card('S12-024', 'ピカチュウ'),
      card('SV2D-017', 'ピカチュウ'),
      card('SV8-033', 'ピカチュウex'),
      card('SM12a-041', 'ピカチュウ&ゼクロムGX'),
    ]
    exact_ids = %w[E1-016 S12-024 SV2D-017]

    # sample によるランダム選択なので、複数回試して常に完全一致集合に入ることを確認する
    30.times do
      bytes, = silently { download_first_tcg_pokemon_image('ピカチュウ') }
      assert_includes exact_ids, picked_id(bytes)
    end
  end

  def test_部分一致のみの場合は部分一致集合の中から選ぶ
    stub_search [
      card('SV3-125', 'リザードンex'),
      card('M2-013',  'メガリザードンXex'),
    ]
    30.times do
      bytes, = silently { download_first_tcg_pokemon_image('リザードン') }
      assert_includes %w[SV3-125 M2-013], picked_id(bytes)
    end
  end
end

# 画像が得られないケース
class TestDownloadImageFailures < PokeTestCase
  def test_検索結果が0件なら_nil_を返す
    stub_search []

    assert_nil silently { download_first_tcg_pokemon_image('ぜったいにないポケモン') }
  end

  def test_全カードが画像を持たない場合は_nil_を返す
    stub_search [
      card('PMCG1-021', 'リザードン',   image: false),
      card('PMCG4-017', 'わるいリザードン', image: false),
    ]

    assert_nil silently { download_first_tcg_pokemon_image('リザードン') }
  end

  def test_画像ダウンロードが失敗したら_nil_を返す
    StubHttp.json_handler  = ->(_url) { [card('E1-016', 'ピカチュウ')] }
    StubHttp.image_handler = ->(_url) { nil }

    assert_nil silently { download_first_tcg_pokemon_image('ピカチュウ') }
  end

  def test_検索APIが配列以外を返しても例外にせず_nil_を返す
    StubHttp.json_handler = ->(_url) { nil } # HTTP エラー時の http_get_json の戻り値

    assert_nil silently { download_first_tcg_pokemon_image('ピカチュウ') }
  end

  def test_検索中の例外を捕捉して空配列を返す
    StubHttp.json_handler = ->(_url) { raise Timeout::Error, 'execution expired' }

    assert_equal [], silently { tcgdex_search_cards('ピカチュウ') }
  end
end

# 検索リクエストの組み立て
class TestSearchRequest < PokeTestCase
  def test_日本語の検索語をURLエンコードして問い合わせる
    captured = nil
    StubHttp.json_handler = ->(url) { captured = url; [] }
    silently { tcgdex_search_cards('ピカチュウ') }

    assert captured.start_with?("#{TCGDEX_API_BASE}/cards?"), "想定外のURL: #{captured}"
    assert_equal 'ピカチュウ', URI.decode_www_form(URI(captured).query).to_h['name']
  end

  def test_アンパサンドを含む名前も壊さずに送る
    captured = nil
    StubHttp.json_handler = ->(url) { captured = url; [] }
    silently { tcgdex_search_cards('ピカチュウ&ゼクロムGX') }

    assert_equal 'ピカチュウ&ゼクロムGX', URI.decode_www_form(URI(captured).query).to_h['name']
  end
end

# 拡張子の決定
class TestExtensionFromContentType < PokeTestCase
  def test_主要な画像形式を対応付ける
    assert_equal '.jpg',  extension_from_content_type('image/jpeg')
    assert_equal '.png',  extension_from_content_type('image/png')
    assert_equal '.gif',  extension_from_content_type('image/gif')
    assert_equal '.webp', extension_from_content_type('image/webp')
  end

  def test_charset_付きでも判定できる
    assert_equal '.png', extension_from_content_type('image/png; charset=binary')
  end

  def test_未知の形式や_nil_は_webp_にフォールバックする
    assert_equal '.webp', extension_from_content_type('image/avif')
    assert_equal '.webp', extension_from_content_type(nil)
  end

  def test_ファイル名に_content_type_由来の拡張子が付く
    stub_search [card('E1-016', 'ピカチュウ')], content_type: 'image/png'
    _, filename = silently { download_first_tcg_pokemon_image('ピカチュウ') }

    assert_equal 'pokemon_card.png', filename
  end
end

# ログの出力先（stdout=正常系 / stderr=異常系）
class TestLogRouting < PokeTestCase
  def test_正常系のログは_stdout_に出て_stderr_は空
    stub_search [card('S1-013', 'リザードン'), card('SV3-125', 'リザードンex')]
    out, err = capture_io { download_first_tcg_pokemon_image('リザードン') }

    assert_includes out, '完全一致 1 件 / 部分一致 1 件'
    assert_includes out, '完全一致から S1-013'
    assert_empty err, "正常系で stderr に出力された: #{err}"
  end

  def test_0件は正常な結果として_stdout_に出る
    stub_search []
    out, err = capture_io { download_first_tcg_pokemon_image('ぜったいにないポケモン') }

    assert_includes out, '画像付きのカードが見つかりませんでした'
    assert_empty err, "0件は異常ではないので stderr に出してはいけない: #{err}"
  end

  def test_画像ダウンロード失敗は_stderr_に出る
    StubHttp.json_handler  = ->(_url) { [card('E1-016', 'ピカチュウ')] }
    StubHttp.image_handler = ->(_url) { nil }
    _, err = capture_io { download_first_tcg_pokemon_image('ピカチュウ') }

    assert_includes err, '画像のダウンロードに失敗しました'
  end

  def test_例外は_stderr_に出る
    StubHttp.json_handler = ->(_url) { raise Timeout::Error, 'execution expired' }
    _, err = capture_io { tcgdex_search_cards('ピカチュウ') }

    assert_includes err, 'Timeout::Error'
  end
end
