require 'json'

POKEMON_DATA = JSON.parse(File.read(File.expand_path('../../data/pokemon_data.json', __FILE__))).freeze

def find_pokemon(input)
  exact = POKEMON_DATA.select { |p| p['name'] == input }
  return exact unless exact.empty?
  POKEMON_DATA.select { |p| p['name'].include?(input) }
end

STAT_LABELS = {
  'hp'        => 'HP ',
  'attack'    => '攻撃',
  'defence'   => '防御',
  'spAttack'  => '特攻',
  'spDefence' => '特防',
  'speed'     => '素早',
}.freeze

def format_stats(pokemon)
  s     = pokemon['stats']
  total = s.values.sum
  bar   = ->(v) { '█' * (v / 10) + '░' * (15 - v / 10) }
  lines = STAT_LABELS.map { |key, label| v = s[key]; "#{label}  #{bar.(v)} #{v.to_s.rjust(3)}" }
  label  = pokemon['isMegaEvolution'] ? ' (メガ)' : ''
  header = "No.#{pokemon['no']} #{pokemon['name']}#{label}"
  types  = pokemon['types'].join(' / ')
  footer = "タイプ: #{types}　合計: #{total}"
  "#{header}\n#{lines.join("\n")}\n#{footer}"
end

puts '=== ピカチュウ ==='
find_pokemon('ピカチュウ').each { |p| puts format_stats(p); puts }

puts '=== リザードン (メガ含む) ==='
find_pokemon('リザードン').each { |p| puts format_stats(p); puts }

puts '=== 部分一致: ドン ==='
find_pokemon('ドン').first(3).each { |p| puts format_stats(p); puts }

puts '=== 存在しない ==='
result = find_pokemon('あいうえお')
puts result.empty? ? '見つかりませんでした ✓' : 'found'
