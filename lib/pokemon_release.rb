require 'date'
require 'uri'

# ポケモンカード公式サイトの商品情報ページ（/products/）が裏で叩いている JSON を使う。
# 公開APIとして案内されているものではないため、いつ壊れてもおかしくない前提で書く。
#
# 他の候補と比較した結果ここに落ち着いた:
#   tcgdex … releaseDate は持つが更新が遅く、未発売どころか発売済みの直近弾すら入っていない
#   pokemontcg.io … 英語版セットのみで日本の発売日は扱わない
POKEMON_CARD_SITE          = 'https://www.pokemon-card.com'.freeze
POKEMON_CARD_PRODUCTS_API  = "#{POKEMON_CARD_SITE}/products/resultAPI.php".freeze
POKEMON_CARD_PRODUCTS_PAGE = "#{POKEMON_CARD_SITE}/products/".freeze

# 何ヶ月先まで見るか。発売日が未発表の弾はそもそもAPIに載らないので、
# ここを伸ばしても件数はほとんど増えない。
RELEASE_LOOKAHEAD_MONTHS = 2

# Discord に並べる最大件数。カードセット9種の同時発売のような回があるため上限を置く。
RELEASE_MAX_ITEMS = 10

# 価格での絞り込みはしないが、API が下限・上限を要求するので公式サイトの初期値を渡す
RELEASE_PRICE_LOWER = 0
RELEASE_PRICE_UPPER = 99_999

WDAY_LABELS = %w[日 月 火 水 木 金 土].freeze

# 発売日の範囲を指定して商品検索APIのURLを組み立てる。
# productType を渡さないと「すべて」= 拡張パック・構築デッキ・その他・周辺グッズが対象になる。
def products_api_url(from:, to:, page: 1)
  params = {
    'dateLowerY' => from.year, 'dateLowerM' => from.month, 'dateLowerD' => from.day,
    'dateUpperY' => to.year,   'dateUpperM' => to.month,   'dateUpperD' => to.day,
    'priceLower' => RELEASE_PRICE_LOWER,
    'priceUpper' => RELEASE_PRICE_UPPER,
    'page'       => page,
  }
  "#{POKEMON_CARD_PRODUCTS_API}?#{URI.encode_www_form(params)}"
end

# API が返す発売日は "2026年 9月16日（金）" のような表示用の文字列で、
# 月が1桁だと桁揃えの半角スペースが入る。並べ替えのために Date へ直す。
def parse_japanese_release_date(text)
  normalized = text.to_s.tr('０-９', '0-9')
  matched    = /(\d{4})年\s*(\d{1,2})月\s*(\d{1,2})日/.match(normalized)
  return nil if matched.nil?

  Date.new(matched[1].to_i, matched[2].to_i, matched[3].to_i)
rescue Date::Error
  nil
end

# link_detailPage は "/ex/m6/" のような相対パスのことも、別ドメインの絶対URLのこともある。
# どちらも無ければ商品情報ページそのものへ逃がす。
def absolute_product_url(path)
  stripped = path.to_s.strip
  return nil if stripped.empty?
  return stripped if stripped.start_with?('http://', 'https://')

  "#{POKEMON_CARD_SITE}#{stripped.start_with?('/') ? stripped : "/#{stripped}"}"
end

# Discord のマスクリンク [表示名](URL) を壊さないように、角括弧だけ潰す
def escape_link_text(text)
  text.to_s.tr('[]', '［］')
end

# 今日以降に発売される商品を、発売日の昇順で返す。
# 戻り値の nil は「取得に失敗した」、[] は「予定が無い」を表す。件数の切り詰めは表示側で行う。
def fetch_upcoming_products(today: Date.today, months: RELEASE_LOOKAHEAD_MONTHS)
  url  = products_api_url(from: today, to: today >> months)
  body = http_get_json(url)

  unless body.is_a?(Hash) && body['products'].is_a?(Array)
    warn "[fetch_upcoming_products] 想定外のレスポンスです (url=#{url})"
    return nil
  end

  if body['result'].to_i != 1
    warn "[fetch_upcoming_products] API がエラーを返しました (result=#{body['result']}, errMsg=#{body['errMsg']})"
    return nil
  end

  products = body['products'].filter_map { |raw| build_product(raw, today: today) }
                             .sort_by { |product| [product[:release_date], product[:title]] }

  puts "[fetch_upcoming_products] #{products.size} 件の発売予定を取得しました (#{today} 〜 #{today >> months})"
  products
rescue StandardError => e
  warn "[fetch_upcoming_products] #{e.class}: #{e.message}"
  nil
end

# API の1件分を表示に必要な形へ整える。発売日が読めない・過ぎているものは nil にして落とす。
def build_product(raw, today: Date.today)
  return nil unless raw.is_a?(Hash)

  release_date = parse_japanese_release_date(raw['releaseDate'])
  if release_date.nil?
    warn "[build_product] 発売日を解釈できませんでした (releaseDate=#{raw['releaseDate'].inspect})"
    return nil
  end
  # API の日付範囲は下限を含むが、境界の扱いが変わっても今日より前が混ざらないようにする
  return nil if release_date < today

  {
    release_date: release_date,
    title:        raw['productTitle'].to_s.strip,
    type:         raw['productType'].to_s.strip,
    price:        raw['priceTxt'].to_s.strip,
    url:          absolute_product_url(raw['link_detailPage']) || POKEMON_CARD_PRODUCTS_PAGE,
  }
end

def format_release_date(date)
  "#{date.year}年#{date.month}月#{date.day}日（#{WDAY_LABELS[date.wday]}）"
end

# 発売日ごとにまとめた本文を作る。products が nil なら取得失敗、[] なら予定なし。
def format_upcoming_products(products, limit: RELEASE_MAX_ITEMS, months: RELEASE_LOOKAHEAD_MONTHS)
  return "公式サイトから発売予定を取れなかったジュラー…… #{POKEMON_CARD_PRODUCTS_PAGE}" if products.nil?

  if products.empty?
    return "#{months}ヶ月先までに発売予定の商品はまだ発表されてないジュラー\n#{POKEMON_CARD_PRODUCTS_PAGE}"
  end

  shown   = products.first(limit)
  omitted = products.size - shown.size

  body = shown.group_by { |product| product[:release_date] }.map do |date, group|
    lines = ["**#{format_release_date(date)}**"]
    group.each do |product|
      detail = [product[:type], product[:price]].reject(&:empty?).join(' / ')
      lines << "　[#{escape_link_text(product[:title])}](#{product[:url]})#{detail.empty? ? '' : " — #{detail}"}"
    end
    lines.join("\n")
  end

  text = +"**これから#{months}ヶ月以内に発売されるポケカ商品ジュラー**\n\n#{body.join("\n\n")}"
  text << "\n\nほか#{omitted}件あるジュラー → #{POKEMON_CARD_PRODUCTS_PAGE}" if omitted.positive?

  text = "#{text[0, 1_997]}..." if text.length > 2_000
  text
end
