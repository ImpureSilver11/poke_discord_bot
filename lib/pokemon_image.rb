require 'json'
require 'net/http'
require 'uri'

TCGDEX_API_BASE = 'https://api.tcgdex.net/v2/ja'

# ログの使い分け:
#   puts (stdout) … 正常系の進行状況。「該当0件」も検索の正常な結果なのでこちら
#   warn (stderr) … 異常系。HTTP エラー・例外・想定外のレスポンスなど、運用者が対処すべきもの

def tcgdex_search_cards(query)
  params = URI.encode_www_form('name' => query)
  url    = "#{TCGDEX_API_BASE}/cards?#{params}"
  result = http_get_json(url)
  return [] unless result.is_a?(Array)

  puts "[tcgdex_search_cards] #{result.size} 件ヒット (query=#{query})"
  result
rescue StandardError => e
  warn "[tcgdex_search_cards] #{e.class}: #{e.message} (query=#{query})"
  []
end

# カード名の比較用に正規化する。前後の空白と英字の大小差を無視する。
def normalize_card_name(name)
  name.to_s.strip.downcase
end

# tcgdex の ?name= は部分一致検索なので、完全一致とそれ以外に分けて返す。
#   例) query="リザードン" → 完全一致 "リザードン" / 部分一致 "リザードンex" "メガリザードンXex" など
def partition_cards_by_match(cards, query)
  target = normalize_card_name(query)
  cards.partition { |c| normalize_card_name(c['name']) == target }
end

def download_first_tcg_pokemon_image(query)
  cards = tcgdex_search_cards(query).select { |c| c['image'] }
  if cards.empty?
    puts "[download_first_tcg_pokemon_image] 画像付きのカードが見つかりませんでした (query=#{query})"
    return nil
  end

  exact, partial = partition_cards_by_match(cards, query)
  puts "[download_first_tcg_pokemon_image] 完全一致 #{exact.size} 件 / 部分一致 #{partial.size} 件 (query=#{query})"

  # 完全一致があればそちらを優先し、無い場合のみ部分一致にフォールバックする
  candidates, match_type = exact.empty? ? [partial, '部分一致'] : [exact, '完全一致']

  card       = candidates.sample
  image_url  = "#{card['image']}/high.webp"
  puts "[download_first_tcg_pokemon_image] #{match_type}から #{card['id']} (#{card['name']}) を選択: #{image_url}"

  bytes, content_type = http_get_image(image_url)
  if bytes.nil?
    warn "[download_first_tcg_pokemon_image] 画像のダウンロードに失敗しました: #{image_url}"
    return nil
  end

  puts "[download_first_tcg_pokemon_image] 取得成功 #{bytes.bytesize} bytes (#{content_type})"
  [bytes, "pokemon_card#{extension_from_content_type(content_type)}"]
rescue StandardError => e
  warn "[download_first_tcg_pokemon_image] #{e.class}: #{e.message} (query=#{query})"
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

def extension_from_content_type(content_type)
  { 'image/jpeg' => '.jpg', 'image/png' => '.png', 'image/gif' => '.gif', 'image/webp' => '.webp' }
    .fetch(content_type.to_s.split(';').first.to_s.strip, '.webp')
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
