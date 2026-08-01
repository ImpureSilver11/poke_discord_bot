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

BAR_LENGTH = 15

# 種族値 10 ごとに 1 マス。BAR_LENGTH マス（= 150）を超える値は振り切れ扱いにする。
# clamp しないと 160 以上（メガハガネールの防御 230、ラッキーの HP 250 など）で
# '░' * 負数 になり ArgumentError で落ちる。
def stat_bar(value)
  filled = (value.to_i / 10).clamp(0, BAR_LENGTH)
  '█' * filled + '░' * (BAR_LENGTH - filled)
end

def format_stats(pokemon)
  s     = pokemon['stats']
  total = s.values.sum

  lines = STAT_LABELS.map do |key, label|
    v = s[key]
    "#{label}  #{stat_bar(v)} #{v.to_s.rjust(3)}"
  end

  label      = pokemon['isMegaEvolution'] ? ' (メガ)' : ''
  header     = "**No.#{pokemon['no']} #{pokemon['name']}#{label}**"
  types      = pokemon['types'].join(' / ')
  # メガディメンションの一部は PokeAPI に特性が未収録のため空になりうる
  abilities  = pokemon['abilities'].empty? ? '不明' : pokemon['abilities'].join(' / ')
  hidden     = pokemon['hiddenAbilities'].empty? ? 'なし' : pokemon['hiddenAbilities'].join(' / ')
  footer     = "タイプ: #{types}　合計: **#{total}**\n特性: #{abilities}　夢特性: #{hidden}"

  "#{header}\n```\n#{lines.join("\n")}\n```#{footer}"
end
