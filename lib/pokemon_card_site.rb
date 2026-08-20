# ポケモンカード公式サイト (www.pokemon-card.com) を叩くための共通定義。
#
# 商品情報 (pokemon_release.rb) とカード検索 (pokemon_image.rb) の両方が、同じホストの
# ドキュメント化されていないエンドポイント（どちらも resultAPI.php）を使っている。
# ホスト名と URL の組み立てを2箇所に持つとずれるため、ここに集約する。
POKEMON_CARD_SITE = 'https://www.pokemon-card.com'.freeze

# API が返すパスは "/ex/m6/" や "/assets/images/..." のような相対パスのことも、
# 別ドメインの絶対URLのこともある。どちらも扱えるようにする。
def absolute_pokemon_card_url(path)
  stripped = path.to_s.strip
  return nil if stripped.empty?
  return stripped if stripped.start_with?('http://', 'https://')

  "#{POKEMON_CARD_SITE}#{stripped.start_with?('/') ? stripped : "/#{stripped}"}"
end
