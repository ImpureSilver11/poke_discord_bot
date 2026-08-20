require 'json'
require 'net/http'
require 'uri'

require_relative 'pokemon_card_site'

# ポケモンカード公式サイトのカード検索ページ（/card-search/）が裏で叩いている JSON を使う。
# 公開APIとして案内されているものではないため、いつ壊れてもおかしくない前提で書く。
#
# 第三者のカードDB（tcgdex など）は新しい弾のカードに画像が付かないため使えない。
# 公式サイトは画像の無断転載を禁じているので、画像を出すのはこのカード検索だけに留める。
# 発売予定 (pokemon_release.rb) は画像を出さない。
POKEMON_CARD_SEARCH_API = "#{POKEMON_CARD_SITE}/card-search/resultAPI.php".freeze

# 何ページまで取得するか。1ページ 39 件。
#
# 完全一致のカードは1ページ目に固まらず散らばる（「リザードン」は全93件・3ページで、
# 完全一致が page1 に3件 / page2 に6件 / page3 に9件）ため、1ページだけでは足りない。
# 一方で「ピカチュウ」は全レギュレーションで8ページあるので、上限を置いて打ち切る。
CARD_SEARCH_MAX_PAGES = 3

# ログの使い分け:
#   puts (stdout) … 正常系の進行状況。「該当0件」も検索の正常な結果なのでこちら
#   warn (stderr) … 異常系。HTTP エラー・例外・想定外のレスポンスなど、運用者が対処すべきもの

# 検索APIのURLを組み立てる。
#
# sm_and_keyword は必須。**これが無いと keyword が黙って無視され、全カード（2万件超）が
# 返ってくる。** 「0件になる」ではなく「無関係なカードが返る」という壊れ方をするので、
# HTTP ステータスや result では検知できない。効いているかは searchCondition に
# 「キーワード：」が含まれるかで判定できる（test_pokemon_card_search_live.rb で確認）。
#
# regulation_sidebar_form=all を渡さないとスタンダードレギュレーションのみに絞られる
# （「ピカチュウ」が 290件 → 24件になり、旧弾のカードが出せなくなる）。
# illust は検索フォームが常に送っているので合わせておく。
def card_search_url(query, page: 1)
  params = {
    'keyword'                 => query,
    'sm_and_keyword'          => 'true',
    'regulation_sidebar_form' => 'all',
    'illust'                  => '',
    'page'                    => page,
  }
  "#{POKEMON_CARD_SEARCH_API}?#{URI.encode_www_form(params)}"
end

# 検索APIの1ページ分をそのまま返す。取れなければ nil。
# ページングの終端判定に maxPage が要るので、パース済みの Hash を返している。
def card_search_page(query, page: 1)
  url  = card_search_url(query, page: page)
  body = http_get_json(url)

  unless body.is_a?(Hash)
    # nil は HTTP エラーや例外（http_get_json 側でも warn 済み）。
    # どの検索語のどのページで失敗したかをこの層でも残しておく。
    warn "[card_search_page] レスポンスを取得できませんでした (query=#{query}, page=#{page})"
    return nil
  end

  # エラー応答に cardList が含まれる保証は無いので、cardList より先に result を見る。
  # 順序を逆にすると errMsg を取り落として「形が違う」に丸めてしまい、原因が分からなくなる。
  if body['result'].to_i != 1
    warn "[card_search_page] API がエラーを返しました (result=#{body['result']}, errMsg=#{body['errMsg']})"
    return nil
  end

  unless body['cardList'].is_a?(Array)
    warn "[card_search_page] cardList がありません (query=#{query}, page=#{page})"
    return nil
  end

  body
end

# API の1件分を、表示に必要な形へ整える。
# 画像を持たないカードはここで落とす（旧弾には画像が未整備のものがある）。
def build_card(raw)
  return nil unless raw.is_a?(Hash)

  # cardNameViewText は旧メガ表記で '<span class="pcg pcg-megamark"></span>リザードンEX'
  # のように HTML を含む。名前の比較に使えないので、プレーンな cardNameAltText を使う。
  name  = raw['cardNameAltText'].to_s.strip
  image = absolute_pokemon_card_url(raw['cardThumbFile'])
  return nil if name.empty? || image.nil?

  { 'id' => raw['cardID'].to_s, 'name' => name, 'image' => image }
end

# 検索結果を maxPage まで（max_pages を上限に）集める。
# 画像を持つカードだけを、build_card で正規化した形で返す。
def search_pokemon_cards(query, max_pages: CARD_SEARCH_MAX_PAGES)
  cards    = []
  max_page = 1
  page     = 1

  while page <= max_page && page <= max_pages
    body = card_search_page(query, page: page)
    break if body.nil?

    # maxPage を超える page を投げると空ではなく最終ページが返ってくる。
    # 終端は必ず maxPage で判定する（空判定にすると同じページを延々と取り続ける）。
    max_page = body['maxPage'].to_i
    cards.concat(body['cardList'].filter_map { |raw| build_card(raw) })
    page += 1
  end

  fetched = page - 1
  puts "[search_pokemon_cards] 画像付き #{cards.size} 件 (query=#{query}, #{fetched}/#{max_page} ページ取得)"
  cards
rescue StandardError => e
  warn "[search_pokemon_cards] #{e.class}: #{e.message} (query=#{query})"
  []
end

# カード名の比較用に正規化する。前後の空白と英字の大小差を無視する。
def normalize_card_name(name)
  name.to_s.strip.downcase
end

# 空白だけの検索語は、検索する前に弾く必要がある。
#
# 空白だけを渡すと公式APIは keyword を無視して全カード（2万件超）を返す。
# 全角スペースも API 側でトリムされるので同じ結果になる（String#strip では落ちない）。
# さらに正規化後が空文字になると `''.include?` が常に真になり、
# select_cards_by_name による絞り込みまで効かなくなって無関係なカードが出る。
#
# Discord の required 指定は空文字を防ぐが、スペース1個の入力は通ってしまう。
def blank_search_query?(query)
  query.to_s.match?(/\A[[:space:]]*\z/)
end

# 公式の keyword はカード名だけでなく**カードテキストも**検索対象にしている。
#   例) "サンド" で ホーホー・カバルドン（ワザの説明文に「サンド」を含む）まで返る
# 名前に検索語を含まないものはここで落とす。これをしないと、無関係なカードの画像が出る。
def select_cards_by_name(cards, query)
  target = normalize_card_name(query)
  cards.select { |card| normalize_card_name(card['name']).include?(target) }
end

# 名前で絞った結果を、完全一致とそれ以外に分けて返す。
#   例) query="リザードン" → 完全一致 "リザードン" / 部分一致 "リザードンex" "メガリザードンXex" など
def partition_cards_by_match(cards, query)
  target = normalize_card_name(query)
  cards.partition { |c| normalize_card_name(c['name']) == target }
end

def download_pokemon_card_image(query)
  if blank_search_query?(query)
    puts "[download_pokemon_card_image] 検索語が空なので検索しません (query=#{query.inspect})"
    return nil
  end

  cards = select_cards_by_name(search_pokemon_cards(query), query)
  if cards.empty?
    puts "[download_pokemon_card_image] 名前が一致する画像付きのカードが見つかりませんでした (query=#{query})"
    return nil
  end

  # 振り分けは「画像を持つカードで絞った後」に行う（build_card が画像なしを落としている）。
  # 完全一致カードが存在しても画像が未整備な弾があるため、先に振り分けると画像を出せずに失敗する。
  exact, partial = partition_cards_by_match(cards, query)
  puts "[download_pokemon_card_image] 完全一致 #{exact.size} 件 / 部分一致 #{partial.size} 件 (query=#{query})"

  # 完全一致があればそちらを優先し、無い場合のみ部分一致にフォールバックする
  candidates, match_type = exact.empty? ? [partial, '部分一致'] : [exact, '完全一致']

  card = candidates.sample
  puts "[download_pokemon_card_image] #{match_type}から #{card['id']} (#{card['name']}) を選択: #{card['image']}"

  bytes, content_type = http_get_image(card['image'])
  if bytes.nil?
    warn "[download_pokemon_card_image] 画像のダウンロードに失敗しました: #{card['image']}"
    return nil
  end

  puts "[download_pokemon_card_image] 取得成功 #{bytes.bytesize} bytes (#{content_type})"
  [bytes, "pokemon_card#{extension_from_content_type(content_type)}"]
rescue StandardError => e
  warn "[download_pokemon_card_image] #{e.class}: #{e.message} (query=#{query})"
  nil
end

def http_get_json(url)
  uri  = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl      = true
  http.read_timeout = 15
  http.open_timeout = 10

  response = http.get(uri.request_uri, 'Accept' => 'application/json')
  unless response.is_a?(Net::HTTPSuccess)
    warn "[http_get_json] HTTP #{response.code}: #{url}"
    return nil
  end

  JSON.parse(response.body)
rescue StandardError => e
  warn "[http_get_json] #{e.class}: #{e.message} (url=#{url})"
  nil
end

# 公式のカード画像は JPEG なので、content-type が読めないときは .jpg に寄せる。
def extension_from_content_type(content_type)
  { 'image/jpeg' => '.jpg', 'image/png' => '.png', 'image/gif' => '.gif', 'image/webp' => '.webp' }
    .fetch(content_type.to_s.split(';').first.to_s.strip, '.jpg')
end

def http_get_image(url, max_redirects: 5)
  uri = URI(url)
  max_redirects.times do
    http              = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = uri.scheme == 'https'
    http.read_timeout = 20
    http.open_timeout = 10
    response = http.get(uri.request_uri)
    case response
    when Net::HTTPSuccess
      content_type = response['content-type'] || ''
      unless content_type.start_with?('image/')
        warn "[http_get_image] 画像ではないレスポンス (content-type=#{content_type.inspect}): #{url}"
        return nil
      end
      return [response.body.b, content_type]
    when Net::HTTPRedirection
      uri = URI(response['location'])
    else
      warn "[http_get_image] HTTP #{response.code}: #{url}"
      return nil
    end
  end
  warn "[http_get_image] リダイレクトが多すぎます (max=#{max_redirects}): #{url}"
  nil
rescue StandardError => e
  warn "[http_get_image] #{e.class}: #{e.message} (url=#{url})"
  nil
end
