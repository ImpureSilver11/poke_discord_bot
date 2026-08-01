#!/usr/bin/env ruby
# PokeAPI からメガシンカ / ゲンシカイキのフォームを取得して pokemon_data.json に追加するスクリプト。
#
#   DRY_RUN=1 ruby scripts/fetch_mega_evolutions.rb   # 書き込まずに差分だけ表示
#   ruby scripts/fetch_mega_evolutions.rb             # 追加して保存
#
# 日本語名は PokeAPI の pokemon-form の form_names（ゲーム内のローカライズ由来）を使う。
# 種族値を記憶で書くと誤りが混入するため、必ず API の値をそのまま入れる。
require 'json'
require 'net/http'
require 'uri'
require 'set'

POKEAPI   = 'https://pokeapi.co/api/v2'
DATA_FILE = File.expand_path('../../data/pokemon_data.json', __FILE__)
DRY_RUN   = ENV['DRY_RUN'] == '1'
# 既存エントリが PokeAPI と食い違っていた場合に上書きするか。
# 既定では報告のみ。誤りを確認したうえで FIX_EXISTING=1 を付けて実行する。
FIX_EXISTING = ENV['FIX_EXISTING'] == '1'

TYPE_JP = {
  'normal'   => 'ノーマル',
  'fire'     => 'ほのお',
  'water'    => 'みず',
  'electric' => 'でんき',
  'grass'    => 'くさ',
  'ice'      => 'こおり',
  'fighting' => 'かくとう',
  'poison'   => 'どく',
  'ground'   => 'じめん',
  'flying'   => 'ひこう',
  'psychic'  => 'エスパー',
  'bug'      => 'むし',
  'rock'     => 'いわ',
  'ghost'    => 'ゴースト',
  'dragon'   => 'ドラゴン',
  'dark'     => 'あく',
  'steel'    => 'はがね',
  'fairy'    => 'フェアリー',
  'stellar'  => 'ステラ',
}.freeze

$ability_cache = {}

def api_get(url)
  uri  = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl      = true
  http.read_timeout = 30
  http.open_timeout = 10
  response = http.get(uri.request_uri)
  return nil if response.is_a?(Net::HTTPNotFound)
  raise "HTTP #{response.code} for #{url}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
rescue StandardError => e
  warn "  ERROR: #{e.message}"
  nil
end

# PokeAPI の言語コードは 'ja-hrkt' / 'ja' で、大小表記が揺れることがあるため downcase で比較する
def jp_name_from(names_array)
  entry   = names_array.find { |n| n['language']['name'].to_s.downcase == 'ja-hrkt' }
  entry ||= names_array.find { |n| n['language']['name'].to_s.downcase == 'ja' }
  normalize_name(entry&.dig('name'))
end

# PokeAPI は「メガリザードンＸ」のように英数を全角で返すことがある。
# 既存データは半角（メガリザードンX）なので、半角に寄せて表記を統一する。
def normalize_name(name)
  return nil if name.nil?

  name.gsub(/[！-～]/) { |c| (c.ord - 0xFEE0).chr(Encoding::UTF_8) }
end

def ability_jp_name(ability_name)
  return $ability_cache[ability_name] if $ability_cache.key?(ability_name)

  data = api_get("#{POKEAPI}/ability/#{ability_name}")
  jp   = data ? jp_name_from(data['names']) || ability_name : ability_name
  $ability_cache[ability_name] = jp
  sleep 0.2
  jp
end

def id_from_url(url)
  url.to_s.match(%r{/(\d+)/?\z})&.[](1)&.to_i
end

def build_stats(raw_stats)
  {
    'hp'        => raw_stats.find { |s| s['stat']['name'] == 'hp'              }&.dig('base_stat'),
    'attack'    => raw_stats.find { |s| s['stat']['name'] == 'attack'          }&.dig('base_stat'),
    'defence'   => raw_stats.find { |s| s['stat']['name'] == 'defense'         }&.dig('base_stat'),
    'spAttack'  => raw_stats.find { |s| s['stat']['name'] == 'special-attack'  }&.dig('base_stat'),
    'spDefence' => raw_stats.find { |s| s['stat']['name'] == 'special-defense' }&.dig('base_stat'),
    'speed'     => raw_stats.find { |s| s['stat']['name'] == 'speed'           }&.dig('base_stat'),
  }
end

# ----------------------------------------------------------------
existing       = JSON.parse(File.read(DATA_FILE))
existing_names = existing.map { |p| p['name'] }.to_set

puts "既存エントリ: #{existing.size}件（うちメガ扱い #{existing.count { |p| p['isMegaEvolution'] }}件）"
puts DRY_RUN ? '*** DRY_RUN: ファイルは書き換えません ***' : '*** 書き込みモード ***'
puts

index = api_get("#{POKEAPI}/pokemon?limit=100000")
abort 'PokeAPI からフォーム一覧を取得できませんでした' unless index

form_names = index['results']
  .map { |r| r['name'] }
  .select { |n| n.include?('-mega') || n.include?('-primal') }
  .sort

puts "PokeAPI 上のメガ/ゲンシ候補: #{form_names.size}件"
puts

fetched   = []
skipped   = []
no_jp     = []
no_ability = []

form_names.each do |form_name|
  print "#{form_name} "

  form = api_get("#{POKEAPI}/pokemon-form/#{form_name}")
  unless form
    puts '→ form 取得失敗、skip'
    skipped << [form_name, 'form 取得失敗']
    next
  end
  sleep 0.2

  pokemon = api_get("#{POKEAPI}/pokemon/#{form_name}")
  unless pokemon
    puts '→ pokemon 取得失敗、skip'
    skipped << [form_name, 'pokemon 取得失敗']
    next
  end
  sleep 0.2

  no = id_from_url(pokemon.dig('species', 'url'))
  if no.nil?
    puts '→ species id 不明、skip'
    skipped << [form_name, 'species id 不明']
    next
  end

  # ゲンシカイキは form_names が「ゲンシカイキのすがた」という汎用ラベルで、
  # カイオーガとグラードンで区別できない。種族名から「ゲンシ+種族名」を組み立てる
  # （既存データの ゲンシカイオーガ / ゲンシグラードン と同じ規約）。
  if form_name.include?('-primal')
    species = api_get("#{POKEAPI}/pokemon-species/#{no}")
    sleep 0.2
    species_jp = species ? jp_name_from(species['names'].to_a) : nil
    jp_name    = species_jp ? "ゲンシ#{species_jp}" : nil
  else
    jp_name = jp_name_from(form['form_names'].to_a)
  end

  if jp_name.nil? || jp_name.empty?
    puts '→ 日本語名なし、skip'
    no_jp << form_name
    next
  end

  types = pokemon['types'].sort_by { |t| t['slot'] }.map do |t|
    TYPE_JP[t['type']['name']] || (warn "  未知のタイプ: #{t['type']['name']}"; nil)
  end.compact

  regular = []
  hidden  = []
  pokemon['abilities'].each do |a|
    jp = ability_jp_name(a['ability']['name'])
    a['is_hidden'] ? hidden << jp : regular << jp
  end
  fetched << {
    'source'          => form_name,
    'versionGroup'    => form.dig('version_group', 'name'),
    'entry'           => {
      'no'              => no,
      'name'            => jp_name,
      'form'            => '',
      'isMegaEvolution' => true,
      'evolutions'      => [],
      'types'           => types,
      'abilities'       => regular,
      'hiddenAbilities' => hidden,
      'stats'           => build_stats(pokemon['stats']),
    },
  }
  puts "→ No.#{no} #{jp_name} (#{types.join('/')}) #{build_stats(pokemon['stats']).values.join('-')}"
end

puts
puts '=' * 60

# 同名フォーム（シャリタツの3形態など）は種族値も同一なので1件に統合する
by_name = {}
duplicates = []
fetched.each do |f|
  key = [f['entry']['no'], f['entry']['name']]
  if by_name.key?(key)
    if by_name[key]['entry'] == f['entry']
      duplicates << f['source']
    else
      warn "!! 同名だが内容が異なる: #{f['entry']['name']} (#{by_name[key]['source']} vs #{f['source']})"
    end
    next
  end
  by_name[key] = f
end
unique = by_name.values

# PokeAPI 側に特性が入っていないもの（Mega Dimension の一部はまだ未収録）
no_ability = unique
  .select { |f| f['entry']['abilities'].empty? && f['entry']['hiddenAbilities'].empty? }
  .map    { |f| f['entry']['name'] }

# 既存にある名前は追加しない。ただし内容が食い違っていないか検証する。
# PokeAPI 側の特性が空のときは「欠落」であって「相違」ではないので比較対象から外す
# （FIX_EXISTING で既存の正しい特性を消してしまわないようにするため）。
new_entries = []
conflicts   = []
unique.each do |f|
  name = f['entry']['name']
  unless existing_names.include?(name)
    new_entries << f
    next
  end
  old  = existing.find { |p| p['name'] == name }
  keys = %w[types stats]
  keys += %w[abilities hiddenAbilities] unless f['entry']['abilities'].empty? && f['entry']['hiddenAbilities'].empty?
  diff = keys.reject { |k| old[k] == f['entry'][k] }
  conflicts << [name, diff, old, f['entry']] unless diff.empty?
end

puts "取得成功: #{fetched.size}件"
puts "同名統合で除外: #{duplicates.size}件 #{duplicates.inspect}" unless duplicates.empty?
puts "日本語名なしで除外: #{no_jp.size}件 #{no_jp.inspect}" unless no_jp.empty?
puts "取得失敗: #{skipped.size}件 #{skipped.inspect}" unless skipped.empty?
puts "特性が空（PokeAPI 側のデータ欠落）: #{no_ability.size}件 #{no_ability.inspect}" unless no_ability.empty?
puts
puts "既存と重複していて追加しないもの: #{unique.size - new_entries.size}件"
unless conflicts.empty?
  puts "!! 既存データと PokeAPI が食い違うもの: #{conflicts.size}件"
  conflicts.each do |name, diff, old, api|
    puts "   #{name}: #{diff.join(', ')} が異なる"
    diff.each do |k|
      puts "     既存    : #{(old[k].is_a?(Hash) ? old[k].values.join('-') : old[k].inspect)}"
      puts "     PokeAPI : #{(api[k].is_a?(Hash) ? api[k].values.join('-') : api[k].inspect)}"
    end
  end
  puts FIX_EXISTING ? '   → FIX_EXISTING=1 のため PokeAPI の値で上書きします' : '   → 報告のみ（上書きするには FIX_EXISTING=1）'
end
puts
puts "新規追加: #{new_entries.size}件"
new_entries.group_by { |f| f['versionGroup'] }.each do |vg, list|
  puts "  [#{vg}] #{list.size}件"
  list.sort_by { |f| f['entry']['no'] }.each { |f| puts "    No.#{f['entry']['no'].to_s.rjust(4)} #{f['entry']['name']}" }
end

if DRY_RUN
  puts
  puts 'DRY_RUN のため書き込みませんでした。'
  exit 0
end

fixes = FIX_EXISTING ? conflicts : []
if new_entries.empty? && fixes.empty?
  puts
  puts '追加・修正するものがないため書き込みません。'
  exit 0
end

# 既存エントリの修正（FIX_EXISTING=1 のときのみ）
updated = existing.map do |p|
  fix = fixes.find { |name, _diff, _old, _api| name == p['name'] }
  next p unless fix

  _name, diff, _old, api = fix
  p.merge(diff.to_h { |k| [k, api[k]] })
end

# no で安定ソートする。既存配列は no 昇順なので、新規は同じ no の既存エントリの
# 後ろ（= 基本形やすでにあるメガの後）に入り、既存の並びは一切変わらない。
merged = (updated + new_entries.map { |f| f['entry'] })
  .each_with_index
  .sort_by { |p, i| [p['no'], i] }
  .map(&:first)

File.write(DATA_FILE, JSON.pretty_generate(merged))

puts
puts '=== 完了 ==='
puts "#{existing.size}件 → #{merged.size}件（+#{merged.size - existing.size}）"
puts "既存エントリの修正: #{fixes.size}件" unless fixes.empty?
puts DATA_FILE
