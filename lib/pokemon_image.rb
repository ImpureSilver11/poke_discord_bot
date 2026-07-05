require 'json'
require 'net/http'
require 'uri'

TCG_API_BASE = 'https://api.pokemontcg.io/v2'

POKEMON_NAME_TO_DEX = begin
  data = JSON.parse(File.read(File.expand_path('../../data/pokemon_data.json', __FILE__)))
  data.each_with_object({}) { |p, h| h[p['name']] = p['no'] }
end.freeze

# Order matters: VSTAR/VMAX must be checked before V
TCG_SUBTYPES = [
  [/VSTAR/i,    'VSTAR'],
  [/VMAX/i,     'VMAX'],
  [/MEGA|メガ/, 'MEGA'],
  [/\bGX\b/,    'GX'],
  [/\bex\b/,    'ex'],
  [/\bEX\b/,    'EX'],
  [/\bV\b/,     'V'],
].freeze

def build_tcg_query(query)
  dex_no = POKEMON_NAME_TO_DEX[query]
  unless dex_no
    matched = POKEMON_NAME_TO_DEX.keys.select { |name| query.include?(name) }.max_by(&:length)
    dex_no  = POKEMON_NAME_TO_DEX[matched] if matched
  end

  if dex_no
    parts   = ["nationalPokedexNumbers:#{dex_no}"]
    subtype = TCG_SUBTYPES.find { |pat, _| query.match?(pat) }
    parts << "subtypes:#{subtype[1]}" if subtype
    parts.join(' ')
  else
    "name:#{query}"
  end
end

def tcg_api_cards(query)
  params = URI.encode_www_form(q: query, pageSize: 20, orderBy: '-set.releaseDate')
  url    = "#{TCG_API_BASE}/cards?#{params}"

  uri  = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl      = true
  http.read_timeout = 15
  http.open_timeout = 10

  headers = { 'Accept' => 'application/json' }
  api_key = ENV['POKEMON_TCG_API_KEY']
  headers['X-Api-Key'] = api_key if api_key

  response = http.get(uri.request_uri, headers)
  return nil unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)['data']
rescue StandardError
  nil
end

def download_first_tcg_pokemon_image(query)
  tcg_query = build_tcg_query(query)
  cards     = tcg_api_cards(tcg_query)
  return nil if cards.nil? || cards.empty?

  card      = cards.find { |c| c.dig('images', 'large') } || cards.first
  image_url = card.dig('images', 'large') || card.dig('images', 'small')
  return nil unless image_url

  bytes, content_type = http_get_image(image_url)
  return nil unless bytes

  [bytes, "pokemon_image#{extension_from_content_type(content_type)}"]
rescue StandardError
  nil
end

def extension_from_content_type(content_type)
  { 'image/jpeg' => '.jpg', 'image/png' => '.png', 'image/gif' => '.gif', 'image/webp' => '.webp' }
    .fetch(content_type.split(';').first.strip, '.jpg')
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
