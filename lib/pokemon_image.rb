require 'json'
require 'net/http'
require 'uri'

TCGDEX_API_BASE = 'https://api.tcgdex.net/v2/ja'

def tcgdex_search_cards(query)
  params = URI.encode_www_form('name' => query)
  url    = "#{TCGDEX_API_BASE}/cards?#{params}"
  result = http_get_json(url)
  result.is_a?(Array) ? result : []
rescue StandardError
  []
end

def download_first_tcg_pokemon_image(query)
  cards = tcgdex_search_cards(query)
  return nil if cards.empty?

  card       = cards.sample
  image_base = card['image']
  return nil unless image_base

  bytes, content_type = http_get_image("#{image_base}/high.webp")
  return nil unless bytes

  [bytes, "pokemon_card#{extension_from_content_type(content_type)}"]
rescue StandardError
  nil
end

def http_get_json(url)
  uri  = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl      = true
  http.read_timeout = 15
  http.open_timeout = 10

  response = http.get(uri.request_uri, 'Accept' => 'application/json')
  return nil unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
rescue StandardError
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
      return nil unless content_type.start_with?('image/')
      return [response.body.b, content_type]
    when Net::HTTPRedirection
      uri = URI(response['location'])
    else
      return nil
    end
  end
  nil
rescue StandardError
  nil
end
