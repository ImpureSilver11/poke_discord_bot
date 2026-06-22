#!/usr/bin/env ruby
# PokeAPI から No.821 以降のポケモンデータを取得して pokemon_data.json に追加するスクリプト
require 'json'
require 'net/http'
require 'uri'
require 'set'

POKEAPI  = 'https://pokeapi.co/api/v2'
DATA_FILE = File.expand_path('../../data/pokemon_data.json', __FILE__)

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

$ability_cache   = {}
$evolution_cache = {}

def api_get(url)
  uri      = URI(url)
  http     = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl      = true
  http.read_timeout = 30
  http.open_timeout = 10
  response = http.get(uri.request_uri)
  return nil if response.is_a?(Net::HTTPNotFound)
  raise "HTTP #{response.code} for #{url}" unless response.is_a?(Net::HTTPSuccess)
  JSON.parse(response.body)
rescue => e
  warn "  ERROR: #{e.message}"
  nil
end

def jp_name_from(names_array)
  entry = names_array.find { |n| n['language']['name'] == 'ja-Hrkt' }
  entry ||= names_array.find { |n| n['language']['name'] == 'ja' }
  entry&.dig('name')
end

def ability_jp_name(ability_name)
  return $ability_cache[ability_name] if $ability_cache.key?(ability_name)
  data = api_get("#{POKEAPI}/ability/#{ability_name}")
  jp   = data ? jp_name_from(data['names']) || ability_name : ability_name
  $ability_cache[ability_name] = jp
  sleep 0.2
  jp
end

def extract_evolutions(node, target_id)
  id = node['species']['url'].match(/\/(\d+)\/$/)&.[](1)&.to_i
  if id == target_id
    return node['evolves_to'].map { |e| e['species']['url'].match(/\/(\d+)\/$/)&.[](1)&.to_i }.compact
  end
  node['evolves_to'].each do |child|
    result = extract_evolutions(child, target_id)
    return result if result
  end
  nil
end

def get_evolutions(species_id, evo_chain_url)
  chain = $evolution_cache[evo_chain_url] ||= begin
    data = api_get(evo_chain_url)
    sleep 0.2
    data
  end
  return [] unless chain
  extract_evolutions(chain['chain'], species_id) || []
end

# ----------------------------------------------------------------
existing    = JSON.parse(File.read(DATA_FILE))
existing_nos = existing.map { |p| p['no'] }.to_set

# 最大 No. を PokeAPI のポケモン総数で確認
count_data = api_get("#{POKEAPI}/pokemon-species?limit=0")
max_no     = count_data ? count_data['count'] : 1025
puts "Total Pokemon in PokeAPI: #{max_no}"

start_no = existing_nos.max + 1
puts "Fetching No.#{start_no} to No.#{max_no}...\n\n"

new_entries = []
failed_nos  = []

(start_no..max_no).each do |no|
  print "##{no} "

  pokemon = api_get("#{POKEAPI}/pokemon/#{no}")
  unless pokemon
    puts "→ not found, skip"
    failed_nos << no
    next
  end
  sleep 0.3

  species = api_get("#{POKEAPI}/pokemon-species/#{no}")
  unless species
    puts "→ species not found, skip"
    failed_nos << no
    next
  end
  sleep 0.3

  jp_name = jp_name_from(species['names']) || "No.#{no}"

  types = pokemon['types']
    .sort_by { |t| t['slot'] }
    .map     { |t| TYPE_JP[t['type']['name']] }
    .compact

  regular_abilities = []
  hidden_abilities  = []
  pokemon['abilities'].each do |a|
    jp = ability_jp_name(a['ability']['name'])
    a['is_hidden'] ? hidden_abilities << jp : regular_abilities << jp
  end

  evo_chain_url = species.dig('evolution_chain', 'url')
  evolutions    = evo_chain_url ? get_evolutions(no, evo_chain_url) : []

  raw_stats = pokemon['stats']
  stats = {
    'hp'        => raw_stats.find { |s| s['stat']['name'] == 'hp'              }&.dig('base_stat'),
    'attack'    => raw_stats.find { |s| s['stat']['name'] == 'attack'          }&.dig('base_stat'),
    'defence'   => raw_stats.find { |s| s['stat']['name'] == 'defense'         }&.dig('base_stat'),
    'spAttack'  => raw_stats.find { |s| s['stat']['name'] == 'special-attack'  }&.dig('base_stat'),
    'spDefence' => raw_stats.find { |s| s['stat']['name'] == 'special-defense' }&.dig('base_stat'),
    'speed'     => raw_stats.find { |s| s['stat']['name'] == 'speed'           }&.dig('base_stat'),
  }

  entry = {
    'no'              => no,
    'name'            => jp_name,
    'form'            => '',
    'isMegaEvolution' => false,
    'evolutions'      => evolutions,
    'types'           => types,
    'abilities'       => regular_abilities,
    'hiddenAbilities' => hidden_abilities,
    'stats'           => stats,
  }
  new_entries << entry
  puts "→ #{jp_name} (#{types.join('/')})"
end

all_entries = existing + new_entries
File.write(DATA_FILE, JSON.pretty_generate(all_entries))

puts "\n=== Done ==="
puts "Added:  #{new_entries.size} Pokemon"
puts "Failed: #{failed_nos.size} (#{failed_nos.join(', ')})" unless failed_nos.empty?
puts "Total:  #{all_entries.size} entries in #{DATA_FILE}"
