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

def download_first_tcg_pokemon_image(query)
  cards = tcgdex_search_cards(query).select { |c| c['image'] }
  if cards.empty?
    puts "[download_first_tcg_pokemon_image] 画像付きのカードが見つかりませんでした (query=#{query})"
    return nil
  end

  card       = cards.sample
  image_url  = "#{card['image']}/high.webp"
  puts "[download_first_tcg_pokemon_image] #{card['id']} (#{card['name']}) を選択: #{image_url}"

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
