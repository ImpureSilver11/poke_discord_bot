require 'json'
require 'net/http'
require 'uri'
require 'nokogiri'

HEADERS = {
  'User-Agent'      => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Accept-Language' => 'ja,en-US;q=0.9,en;q=0.8',
}.freeze

CARD_ASPECT_RATIO     = 63.0 / 88.0
CARD_ASPECT_TOLERANCE = 0.08

PNG_SIG  = "\x89PNG\r\n\x1a\n".b.freeze
GIF87    = "GIF87a".b.freeze
GIF89    = "GIF89a".b.freeze
JPEG_SOF = [0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].freeze

def bing_pokemon_img_urls(command)
  query = "(ポケットモンスター OR ポケモン OR pokemon) (日本語版 OR 日本語 OR Japanese) #{command} カード"

  params = URI.encode_www_form(q: query, qft: '+filterui:aspect-tall', form: 'HDRSC2', first: '1')
  url    = "https://www.bing.com/images/search?#{params}"
  doc    = Nokogiri::HTML(http_get_html(url))

  Enumerator.new do |y|
    doc.css('a.iusc').each do |elem|
      next unless elem['m']
      begin
        image_url = JSON.parse(elem['m'])['murl']
      rescue JSON::ParserError
        next
      end
      y << image_url if image_url&.match?(%r{\Ahttps?://})
    end

    doc.css('img').each do |img|
      image_url = img['src'] || img['data-src']
      y << image_url if image_url&.match?(%r{\Ahttps?://})
    end
  end
end

def extension_from_content_type(content_type)
  { 'image/jpeg' => '.jpg', 'image/png' => '.png', 'image/gif' => '.gif', 'image/webp' => '.webp' }
    .fetch(content_type.split(';').first.strip, '.jpg')
end

def card_aspect_ratio?(image_bytes)
  size = read_image_size(image_bytes)
  return false unless size

  width, height = size
  return false if width <= 0 || height <= 0

  (width.to_f / height - CARD_ASPECT_RATIO).abs <= CARD_ASPECT_TOLERANCE
end

def download_first_card_like_image(image_urls)
  image_urls.each do |url|
    bytes, content_type = http_get_image(url)
    next unless bytes
    next unless card_aspect_ratio?(bytes)

    return [bytes, "pokemon_image#{extension_from_content_type(content_type)}"]
  end
  nil
end

def download_first_bing_pokemon_image(command)
  download_first_card_like_image(bing_pokemon_img_urls(command))
rescue StandardError
  nil
end

def http_get_html(url)
  uri      = URI(url)
  http     = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl      = uri.scheme == 'https'
  http.read_timeout = 15
  http.open_timeout = 10
  response = http.get(uri.request_uri, HEADERS)
  raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  response.body.force_encoding('utf-8')
end

def http_get_image(url, max_redirects: 5)
  uri = URI(url)
  max_redirects.times do
    http               = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl       = uri.scheme == 'https'
    http.read_timeout  = 20
    http.open_timeout  = 10
    response = http.get(uri.request_uri, HEADERS)
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

def read_image_size(bytes)
  b = bytes.b

  if b.start_with?(PNG_SIG) && b.bytesize >= 24
    return b.byteslice(16, 4).unpack1('N'), b.byteslice(20, 4).unpack1('N')
  end

  if (b.start_with?(GIF87) || b.start_with?(GIF89)) && b.bytesize >= 10
    return b.byteslice(6, 2).unpack1('v'), b.byteslice(8, 2).unpack1('v')
  end

  if b.getbyte(0) == 0xff && b.getbyte(1) == 0xd8
    i = 2
    while i + 9 < b.bytesize
      if b.getbyte(i) != 0xff
        i += 1
        next
      end
      marker = b.getbyte(i + 1)
      i += 2
      next if [0xd8, 0xd9].include?(marker)
      return nil if i + 2 > b.bytesize
      seg_len = b.byteslice(i, 2).unpack1('n')
      return nil if seg_len < 2 || i + seg_len > b.bytesize
      return b.byteslice(i + 5, 2).unpack1('n'), b.byteslice(i + 3, 2).unpack1('n') if JPEG_SOF.include?(marker)
      i += seg_len
    end
  end

  if b.byteslice(0, 4) == "RIFF".b && b.byteslice(8, 4) == "WEBP".b
    chunk = b.byteslice(12, 4)
    if chunk == "VP8 ".b && b.bytesize >= 30
      return b.byteslice(26, 2).unpack1('v') & 0x3fff, b.byteslice(28, 2).unpack1('v') & 0x3fff
    end
    if chunk == "VP8L".b && b.bytesize >= 25
      bits = b.byteslice(21, 4).unpack1('V')
      return (bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1
    end
    if chunk == "VP8X".b && b.bytesize >= 30
      w = (b.byteslice(24, 3) + "\x00".b).unpack1('V') + 1
      h = (b.byteslice(27, 3) + "\x00".b).unpack1('V') + 1
      return w, h
    end
  end

  nil
end
