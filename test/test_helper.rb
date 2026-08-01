# Gemfile.lock で固定した gem を使う。`bundle exec` の有無に依らず同じ構成になる。
require 'bundler/setup'

require 'minitest/autorun'
require 'uri'
require 'pokemon_image'

# HTTP 層をテストから差し替えるための仕組み。
#
# lib/pokemon_image.rb の http_get_json / http_get_image をここで上書きし、
# StubHttp に登録したハンドラへ委譲させる。これにより外部 API に繋がずに
# 「完全一致 / 部分一致」の分岐や失敗時のログを決定的に検証できる。
module StubHttp
  # StandardError を継承しない。download_first_tcg_pokemon_image などの
  # rescue StandardError に飲み込まれて、スタブ漏れが警告ログとして
  # 見逃されるのを防ぐため。
  class NotConfigured < Exception; end

  class << self
    attr_accessor :json_handler, :image_handler

    def json(url)
      raise NotConfigured, "http_get_json が未スタブです (url=#{url})" if json_handler.nil?

      json_handler.call(url)
    end

    def image(url)
      raise NotConfigured, "http_get_image が未スタブです (url=#{url})" if image_handler.nil?

      image_handler.call(url)
    end

    def reset!
      self.json_handler  = nil
      self.image_handler = nil
    end
  end
end

# 実物を後から使えるように退避しておく（LIVE=1 の疎通テスト用）
REAL_HTTP_GET_JSON  = method(:http_get_json)
REAL_HTTP_GET_IMAGE = method(:http_get_image)

def http_get_json(url)
  StubHttp.json(url)
end

def http_get_image(url, max_redirects: 5)
  StubHttp.image(url)
end

class PokeTestCase < Minitest::Test
  IMAGE_HOST = 'https://assets.tcgdex.net/ja/X'.freeze

  def setup
    StubHttp.reset!
  end

  def teardown
    StubHttp.reset!
  end

  # tcgdex のカード1件分のレスポンス形状を模した Hash を作る。
  # image: false は「API にカードは存在するが画像が未整備」なケース（旧弾に多い）。
  def card(id, name, image: true)
    h = { 'id' => id, 'name' => name }
    h['image'] = "#{IMAGE_HOST}/#{id}" if image
    h
  end

  # 検索 API が cards を返し、画像取得は URL が分かる形のダミーバイト列を返すようにする
  def stub_search(cards, content_type: 'image/webp')
    StubHttp.json_handler  = ->(_url) { cards }
    StubHttp.image_handler = ->(url) { ["BYTES:#{url}", content_type] }
  end

  # 返却されたバイト列から、どのカードが選ばれたかを取り出す
  def picked_id(bytes)
    bytes.to_s[%r{#{Regexp.escape(IMAGE_HOST)}/([^/]+)/}, 1]
  end

  # ログ出力を捨てて実行する（各テストで明示的に検証する場合以外）
  def silently
    capture_io { return yield }
  end
end
