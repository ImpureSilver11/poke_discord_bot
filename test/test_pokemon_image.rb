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

# API の1件分を表示用の形に整える
class TestBuildCard < PokeTestCase
  def test_必要な項目を取り出して画像を絶対URLにする
    got = build_card(card('50034', 'メガリザードンYex'))

    assert_equal '50034', got['id']
    assert_equal 'メガリザードンYex', got['name']
    assert_equal "https://www.pokemon-card.com#{IMAGE_DIR}/50034.jpg", got['image']
  end

  # cardNameViewText は旧メガ表記で HTML を含む。名前の比較に使えないので alt を使う。
  def test_HTMLを含む_cardNameViewText_ではなく_cardNameAltText_を使う
    raw = {
      'cardID'          => '32219',
      'cardNameAltText' => 'メガリザードンEX',
      'cardNameViewText' => '<span class="pcg pcg-megamark"></span>リザードンEX',
      'cardThumbFile'   => "#{IMAGE_DIR}/32219.jpg",
    }

    assert_equal 'メガリザードンEX', build_card(raw)['name']
  end

  def test_画像を持たないカードは落とす
    assert_nil build_card(card('30000', 'リザードン', image: false))
  end

  def test_名前が空のカードは落とす
    assert_nil build_card(card('30000', '  '))
  end

  def test_Hash_以外は落とす
    assert_nil build_card(nil)
    assert_nil build_card('カード')
  end
end

# 空白だけの検索語。API に投げると全カードが返ってきてしまうので手前で弾く。
class TestBlankSearchQuery < PokeTestCase
  def test_空白だけの検索語を空とみなす
    ['', ' ', '   ', "\t", "\n", '　', '  　 '].each do |query|
      assert blank_search_query?(query), "空と判定されなかった: #{query.inspect}"
    end
  end

  def test_nil_も空とみなす
    assert blank_search_query?(nil)
  end

  def test_検索語があれば空とみなさない
    ['ピカチュウ', ' ピカチュウ ', 'a'].each do |query|
      refute blank_search_query?(query), "空と判定された: #{query.inspect}"
    end
  end

  # StubHttp は未スタブの呼び出しで NotConfigured を投げるため、
  # スタブを一切設定しないことで「1度も問い合わせていない」ことを検証できる。
  def test_空白だけの検索語では問い合わせずに_nil_を返す
    ['', ' ', '　', "\t"].each do |query|
      assert_nil silently { download_pokemon_card_image(query) },
                 "nil を返さなかった: #{query.inspect}"
    end
  end

  # 半角スペース1個でも API は keyword を無視して全カードを返し、
  # 正規化後が空文字だと select_cards_by_name の絞り込みも効かなくなる。
  # その状態で無関係なカードを返さないこと。
  def test_空白だけの検索語で無関係なカードを返さない
    stub_search [card('1', 'ホーホー'), card('2', 'カバルドン'), card('3', 'ピカチュウ')]

    assert_nil silently { download_pokemon_card_image(' ') }
  end

  def test_空白だけの検索語は正常系として_stdout_に出る
    out, err = capture_io { download_pokemon_card_image(' ') }

    assert_includes out, '検索語が空'
    assert_empty err, "入力の問題なので stderr に出してはいけない: #{err}"
  end
end

# 公式の keyword はカードテキストも検索対象なので、名前で絞り直す必要がある
class TestSelectCardsByName < PokeTestCase
  def test_名前に検索語を含まないカードを落とす
    cards = [
      build_card(card('1', 'サンド')),
      build_card(card('2', 'サンドパン')),
      build_card(card('3', 'ホーホー')),      # テキストに「サンド」を含むために返ってくる
      build_card(card('4', 'カバルドン')),
    ]

    assert_equal %w[サンド サンドパン], select_cards_by_name(cards, 'サンド').map { |c| c['name'] }
  end

  def test_検索語の空白と英字の大小差を無視する
    cards = [build_card(card('1', 'リザードンex'))]

    assert_equal 1, select_cards_by_name(cards, ' リザードンEX ').size
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
    ].map { |raw| build_card(raw) }
    exact, partial = partition_cards_by_match(cards, 'リザードン')

    assert_equal ['リザードン'], exact.map { |c| c['name'] }
    assert_equal ['リザードンex', 'メガリザードンXex', 'レシラム&リザードンGX'], partial.map { |c| c['name'] }
  end

  def test_完全一致が無い場合は全て部分一致になる
    cards = [build_card(card('SV10-040', 'ロケット団のソーナンス'))]
    exact, partial = partition_cards_by_match(cards, 'ソーナンス')

    assert_empty exact
    assert_equal 1, partial.size
  end

  def test_検索語の空白差を吸収して完全一致にする
    cards = [build_card(card('E1-016', 'ピカチュウ'))]
    exact, = partition_cards_by_match(cards, ' ピカチュウ ')

    assert_equal 1, exact.size
  end

  def test_同名カードが複数ある場合は全て完全一致に入る
    cards = [
      card('E1-016', 'ピカチュウ'), card('S12-024', 'ピカチュウ'), card('SV8-033', 'ピカチュウex')
    ].map { |raw| build_card(raw) }
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
    bytes, = silently { download_pokemon_card_image('リザードン') }

    assert_equal 'S1-013', picked_id(bytes)
  end

  def test_完全一致が無い場合は部分一致にフォールバックする
    stub_search [card('SV10-040', 'ロケット団のソーナンス')]
    bytes, = silently { download_pokemon_card_image('ソーナンス') }

    assert_equal 'SV10-040', picked_id(bytes)
  end

  # 回帰テスト: 実際の「リザードン」はこのケース。完全一致カードが API 上に存在するが
  # 画像を持たないため、画像フィルタで除外されて部分一致にフォールバックする必要がある。
  # 画像フィルタより先に一致度で分割してしまうと、ここで nil を返してしまう。
  def test_完全一致が画像を持たない場合は部分一致にフォールバックする
    stub_search [
      card('PMCG1-021', 'リザードン',   image: false),
      card('SV3-125',   'リザードンex', image: true),
    ]
    bytes, = silently { download_pokemon_card_image('リザードン') }

    refute_nil bytes, '完全一致が画像なしのとき部分一致に落ちていない'
    assert_equal 'SV3-125', picked_id(bytes)
  end

  # カードテキストで引っかかっただけのカードを選んでしまわないこと
  def test_名前が一致しないカードは選ばない
    stub_search [
      card('1', 'ホーホー'),     # テキストに「サンド」を含むために返ってくる
      card('2', 'カバルドン'),
      card('3', 'サンドパン'),
    ]
    30.times do
      bytes, = silently { download_pokemon_card_image('サンド') }
      assert_equal '3', picked_id(bytes)
    end
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
      bytes, = silently { download_pokemon_card_image('ピカチュウ') }
      assert_includes exact_ids, picked_id(bytes)
    end
  end

  def test_部分一致のみの場合は部分一致集合の中から選ぶ
    stub_search [
      card('SV3-125', 'リザードンex'),
      card('M2-013',  'メガリザードンXex'),
    ]
    30.times do
      bytes, = silently { download_pokemon_card_image('リザードン') }
      assert_includes %w[SV3-125 M2-013], picked_id(bytes)
    end
  end
end

# ページング。完全一致カードは1ページ目に固まらないため複数ページを見る必要がある。
class TestSearchPaging < PokeTestCase
  def test_複数ページを結合して返す
    stub_search_pages [
      [card('1', 'リザードンex')],
      [card('2', 'リザードンVMAX')],
      [card('3', 'リザードン')],
    ]
    cards = silently { search_pokemon_cards('リザードン') }

    assert_equal %w[1 2 3], cards.map { |c| c['id'] }
  end

  # 後ろのページにしか完全一致が無いケース（実データの「リザードン」がこれ）
  def test_後ろのページの完全一致を取りこぼさない
    stub_search_pages [
      [card('1', 'リザードンex')],
      [card('2', 'リザードンVMAX')],
      [card('3', 'リザードン')],
    ]
    bytes, = silently { download_pokemon_card_image('リザードン') }

    assert_equal '3', picked_id(bytes)
  end

  def test_maxPage_までしか取得しない
    requested = []
    StubHttp.json_handler = lambda do |url|
      requested << URI.decode_www_form(URI(url).query).to_h['page']
      search_response([card('1', 'リザードン')], max_page: 2)
    end
    silently { search_pokemon_cards('リザードン') }

    assert_equal %w[1 2], requested, 'maxPage を超えて取得している'
  end

  def test_ページ数の上限で打ち切る
    requested = []
    StubHttp.json_handler = lambda do |url|
      requested << URI.decode_www_form(URI(url).query).to_h['page']
      search_response([card('1', 'ピカチュウ')], max_page: 8)
    end
    silently { search_pokemon_cards('ピカチュウ', max_pages: 3) }

    assert_equal %w[1 2 3], requested
  end

  def test_1ページで収まるなら1回しか問い合わせない
    count = 0
    StubHttp.json_handler = lambda do |_url|
      count += 1
      search_response([card('1', 'ヒトカゲ')], max_page: 1)
    end
    silently { search_pokemon_cards('ヒトカゲ') }

    assert_equal 1, count
  end

  # 途中のページで失敗しても、取れた分は捨てない
  def test_途中のページが失敗しても取得済みの分を返す
    StubHttp.json_handler = lambda do |url|
      page = URI.decode_www_form(URI(url).query).to_h['page'].to_i
      page == 1 ? search_response([card('1', 'リザードン')], max_page: 3) : nil
    end
    cards = silently { search_pokemon_cards('リザードン') }

    assert_equal %w[1], cards.map { |c| c['id'] }
  end
end

# 画像が得られないケース
class TestDownloadImageFailures < PokeTestCase
  def test_検索結果が0件なら_nil_を返す
    stub_search []

    assert_nil silently { download_pokemon_card_image('ぜったいにないポケモン') }
  end

  def test_全カードが画像を持たない場合は_nil_を返す
    stub_search [
      card('PMCG1-021', 'リザードン',   image: false),
      card('PMCG4-017', 'わるいリザードン', image: false),
    ]

    assert_nil silently { download_pokemon_card_image('リザードン') }
  end

  # 名前が一致するカードが1枚も無い（全部テキストマッチだった）ケース
  def test_名前の一致が0件なら_nil_を返す
    stub_search [card('1', 'ホーホー'), card('2', 'カバルドン')]

    assert_nil silently { download_pokemon_card_image('サンド') }
  end

  def test_画像ダウンロードが失敗したら_nil_を返す
    stub_search [card('E1-016', 'ピカチュウ')]
    StubHttp.image_handler = ->(_url) { nil }

    assert_nil silently { download_pokemon_card_image('ピカチュウ') }
  end

  def test_想定外のレスポンスなら_nil_を返す
    StubHttp.json_handler = ->(_url) { nil } # HTTP エラー時の http_get_json の戻り値

    assert_nil silently { download_pokemon_card_image('ピカチュウ') }
  end

  def test_cardList_を持たないレスポンスなら_nil_を返す
    StubHttp.json_handler = ->(_url) { { 'result' => 1 } }

    assert_nil silently { download_pokemon_card_image('ピカチュウ') }
  end

  # result != 1 はエラー。0件（result=1, cardList=[]）と混同しないこと。
  def test_APIがエラーを返したら空配列を返す
    StubHttp.json_handler = ->(_url) { { 'result' => 0, 'errMsg' => 'なにかおかしい', 'cardList' => [] } }

    assert_equal [], silently { search_pokemon_cards('ピカチュウ') }
  end

  # エラー応答に cardList が含まれる保証は無い。cardList の検査を先にすると
  # errMsg を取り落とすので、result を先に見ていることを固定する。
  def test_cardList_が無いエラー応答でも_errMsg_を記録する
    StubHttp.json_handler = ->(_url) { { 'result' => 0, 'errMsg' => 'なにかおかしい' } }
    _out, err = capture_io { search_pokemon_cards('ピカチュウ') }

    assert_includes err, 'なにかおかしい', 'errMsg が記録されていない'
  end

  def test_検索中の例外を捕捉して空配列を返す
    StubHttp.json_handler = ->(_url) { raise Timeout::Error, 'execution expired' }

    assert_equal [], silently { search_pokemon_cards('ピカチュウ') }
  end
end

# 検索リクエストの組み立て
class TestSearchRequest < PokeTestCase
  def params(query, page: 1)
    URI.decode_www_form(URI(card_search_url(query, page: page)).query).to_h
  end

  def test_検索APIのURLに向ける
    assert card_search_url('ピカチュウ').start_with?("#{POKEMON_CARD_SEARCH_API}?"),
           "想定外のURL: #{card_search_url('ピカチュウ')}"
  end

  def test_日本語の検索語をURLエンコードして渡す
    assert_equal 'ピカチュウ', params('ピカチュウ')['keyword']
  end

  def test_アンパサンドを含む名前も壊さずに送る
    assert_equal 'ピカチュウ&ゼクロムGX', params('ピカチュウ&ゼクロムGX')['keyword']
  end

  # これが抜けると keyword が黙って無視され、全カードが返る（0件にはならない）
  def test_キーワード検索を有効にするフラグを必ず渡す
    assert_equal 'true', params('ピカチュウ')['sm_and_keyword']
  end

  # 渡さないとスタンダードのみに絞られ、旧弾のカードが出せなくなる
  def test_全レギュレーションを対象にする
    assert_equal 'all', params('ピカチュウ')['regulation_sidebar_form']
  end

  def test_ページ番号を渡す
    assert_equal '2', params('ピカチュウ', page: 2)['page']
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

  # 公式のカード画像は JPEG なので、判定できないときは .jpg に寄せる
  def test_未知の形式や_nil_は_jpg_にフォールバックする
    assert_equal '.jpg', extension_from_content_type('image/avif')
    assert_equal '.jpg', extension_from_content_type(nil)
  end

  def test_ファイル名に_content_type_由来の拡張子が付く
    stub_search [card('E1-016', 'ピカチュウ')], content_type: 'image/png'
    _, filename = silently { download_pokemon_card_image('ピカチュウ') }

    assert_equal 'pokemon_card.png', filename
  end
end

# ログの出力先（stdout=正常系 / stderr=異常系）
class TestLogRouting < PokeTestCase
  def test_正常系のログは_stdout_に出て_stderr_は空
    stub_search [card('S1-013', 'リザードン'), card('SV3-125', 'リザードンex')]
    out, err = capture_io { download_pokemon_card_image('リザードン') }

    assert_includes out, '完全一致 1 件 / 部分一致 1 件'
    assert_includes out, '完全一致から S1-013'
    assert_empty err, "正常系で stderr に出力された: #{err}"
  end

  def test_0件は正常な結果として_stdout_に出る
    stub_search []
    out, err = capture_io { download_pokemon_card_image('ぜったいにないポケモン') }

    assert_includes out, '見つかりませんでした'
    assert_empty err, "0件は異常ではないので stderr に出してはいけない: #{err}"
  end

  def test_取得したページ数を_stdout_に出す
    stub_search_pages [[card('1', 'リザードン')], [card('2', 'リザードンex')]]
    out, = capture_io { search_pokemon_cards('リザードン') }

    assert_includes out, '2/2 ページ取得'
  end

  def test_画像ダウンロード失敗は_stderr_に出る
    stub_search [card('E1-016', 'ピカチュウ')]
    StubHttp.image_handler = ->(_url) { nil }
    _, err = capture_io { download_pokemon_card_image('ピカチュウ') }

    assert_includes err, '画像のダウンロードに失敗しました'
  end

  def test_APIのエラーは_stderr_に出る
    StubHttp.json_handler = ->(_url) { { 'result' => 0, 'errMsg' => 'なにかおかしい', 'cardList' => [] } }
    _, err = capture_io { search_pokemon_cards('ピカチュウ') }

    assert_includes err, 'なにかおかしい'
  end

  # http_get_json 側でも warn するが、どの検索語のどのページで失敗したかは
  # この層でしか分からないので、両方残す
  def test_レスポンスが取れなかったことを_stderr_に出す
    StubHttp.json_handler = ->(_url) { nil }
    _, err = capture_io { search_pokemon_cards('ピカチュウ') }

    assert_includes err, 'レスポンスを取得できませんでした'
    assert_includes err, 'page=1'
  end

  def test_例外は_stderr_に出る
    StubHttp.json_handler = ->(_url) { raise Timeout::Error, 'execution expired' }
    _, err = capture_io { search_pokemon_cards('ピカチュウ') }

    assert_includes err, 'Timeout::Error'
  end
end
