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
  # 公式のカード画像はこの形のパスで返る:
  #   /assets/images/card_images/large/MC/050034_P_MRIZADONYEX.jpg
  # テストでは弾のディレクトリを X に固定して、末尾から cardID を取り出せるようにする。
  IMAGE_DIR = '/assets/images/card_images/large/X'.freeze

  def setup
    StubHttp.reset!
  end

  def teardown
    StubHttp.reset!
  end

  # 公式のカード検索APIが返すカード1件分のレスポンス形状を模した Hash を作る。
  # image: false は「API にカードは存在するが画像が未整備」なケース（旧弾に多い）。
  def card(id, name, image: true)
    h = { 'cardID' => id, 'cardNameAltText' => name, 'cardNameViewText' => name }
    h['cardThumbFile'] = "#{IMAGE_DIR}/#{id}.jpg" if image
    h
  end

  # 検索APIの1ページ分のレスポンスを組み立てる
  def search_response(cards, page: 1, max_page: 1)
    {
      'result' => 1, 'errMsg' => '', 'thisPage' => page, 'maxPage' => max_page,
      'hitCnt' => cards.size, 'cardStart' => 1, 'cardEnd' => cards.size,
      'searchCondition' => ['キーワード：テスト', 'レギュレーション：すべてのカード'],
      'regulation' => 'all', 'cardList' => cards
    }
  end

  # 1ページで収まる検索結果を返し、画像取得は URL が分かる形のダミーバイト列を返すようにする
  def stub_search(cards, content_type: 'image/jpeg')
    stub_search_pages([cards], content_type: content_type)
  end

  # 複数ページの検索結果を返す。pages は「ページごとのカード配列」の配列。
  # maxPage を超える page を投げられたら、本物と同じく最終ページを返す。
  def stub_search_pages(pages, content_type: 'image/jpeg')
    StubHttp.json_handler = lambda do |url|
      requested = URI.decode_www_form(URI(url).query).to_h['page'].to_i
      page      = requested.clamp(1, pages.size)
      search_response(pages[page - 1], page: page, max_page: pages.size)
    end
    StubHttp.image_handler = ->(url) { ["BYTES:#{url}", content_type] }
  end

  # 返却されたバイト列から、どのカードが選ばれたかを取り出す
  def picked_id(bytes)
    bytes.to_s[%r{#{Regexp.escape(IMAGE_DIR)}/(.+)\.jpg\z}, 1]
  end

  # ログ出力を捨てて実行する（各テストで明示的に検証する場合以外）
  def silently
    capture_io { return yield }
  end
end
