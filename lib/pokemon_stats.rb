require 'json'

POKEMON_DATA = JSON.parse(
  File.read(File.expand_path('../../data/pokemon_data.json', __FILE__))
).freeze

STAT_LABELS = {
  'hp'        => 'HP ',
  'attack'    => '攻撃',
  'defence'   => '防御',
  'spAttack'  => '特攻',
  'spDefence' => '特防',
  'speed'     => '素早',
}.freeze

def find_pokemon(input)
  POKEMON_DATA.select { |p| p['name'] == input }
end

def format_stats(pokemon)
  s     = pokemon['stats']
  total = s.values.sum

  bar = ->(v) { '█' * (v / 10) + '░' * (15 - v / 10) }

  lines = STAT_LABELS.map do |key, label|
    v = s[key]
    "#{label}  #{bar.(v)} #{v.to_s.rjust(3)}"
  end

  label      = pokemon['isMegaEvolution'] ? ' (メガ)' : ''
  header     = "**No.#{pokemon['no']} #{pokemon['name']}#{label}**"
  types      = pokemon['types'].join(' / ')
  abilities  = pokemon['abilities'].join(' / ')
  hidden     = pokemon['hiddenAbilities'].empty? ? 'なし' : pokemon['hiddenAbilities'].join(' / ')
  footer     = "タイプ: #{types}　合計: **#{total}**\n特性: #{abilities}　夢特性: #{hidden}"

  "#{header}\n```\n#{lines.join("\n")}\n```#{footer}"
end
