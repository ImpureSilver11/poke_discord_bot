require_relative 'test_helper'
require 'pokemon_stats'

# 種族値バーの描画
class TestStatBar < PokeTestCase
  def test_常に_BAR_LENGTH_マスになる
    [0, 5, 50, 100, 150, 151, 230, 255].each do |v|
      assert_equal BAR_LENGTH, stat_bar(v).length, "value=#{v} でマス数が違う"
    end
  end

  def test_10ごとに1マス埋まる
    assert_equal '░' * 15,             stat_bar(0)
    assert_equal '█' * 5  + '░' * 10,  stat_bar(50)
    assert_equal '█' * 10 + '░' * 5,   stat_bar(100)
  end

  # 回帰テスト: 修正前は '░' * (15 - v/10) が負数になり ArgumentError で落ちていた。
  # メガハガネールの防御 230 やラッキーの HP 250 など、実データに 160 以上が 55 件ある。
  def test_160以上でも例外にならず振り切れる
    [160, 180, 230, 250, 255].each do |v|
      assert_equal '█' * BAR_LENGTH, stat_bar(v), "value=#{v} で振り切れていない"
    end
  end

  def test_実データ全件を描画しても例外にならない
    POKEMON_DATA.each do |p|
      format_stats(p)
    rescue StandardError => e
      flunk "#{p['name']} の描画で例外: #{e.class}: #{e.message}"
    end
  end
end

# 特性の表示
class TestFormatStatsAbilities < PokeTestCase
  def base
    {
      'no' => 1, 'name' => 'テスト', 'form' => '', 'isMegaEvolution' => false,
      'evolutions' => [], 'types' => ['ノーマル'],
      'abilities' => ['とくせいA'], 'hiddenAbilities' => [],
      'stats' => { 'hp' => 50, 'attack' => 50, 'defence' => 50, 'spAttack' => 50, 'spDefence' => 50, 'speed' => 50 },
    }
  end

  def test_特性を_スラッシュ区切りで表示する
    assert_includes format_stats(base.merge('abilities' => %w[とくせいA とくせいB])), '特性: とくせいA / とくせいB'
  end

  # PokeAPI にメガディメンションの一部の特性が未収録で abilities が空になる。
  # 修正前は「特性: 」と空欄になっていた。
  def test_特性が空なら不明と表示する
    assert_includes format_stats(base.merge('abilities' => [])), '特性: 不明'
  end

  def test_夢特性が空ならなしと表示する
    assert_includes format_stats(base.merge('hiddenAbilities' => [])), '夢特性: なし'
  end
end

# データファイルの整合性
class TestPokemonDataIntegrity < PokeTestCase
  REQUIRED_KEYS = %w[no name form isMegaEvolution evolutions types abilities hiddenAbilities stats].freeze
  STAT_KEYS     = %w[hp attack defence spAttack spDefence speed].freeze

  def test_全エントリが必須キーを持つ
    POKEMON_DATA.each do |p|
      missing = REQUIRED_KEYS.reject { |k| p.key?(k) }
      assert_empty missing, "#{p['name']} に #{missing.inspect} がない"
    end
  end

  def test_種族値が全て正の整数
    POKEMON_DATA.each do |p|
      STAT_KEYS.each do |k|
        v = p['stats'][k]
        assert_kind_of Integer, v, "#{p['name']} の #{k} が整数でない: #{v.inspect}"
        assert_operator v, :>, 0, "#{p['name']} の #{k} が 0 以下"
      end
    end
  end

  def test_タイプが空でない
    POKEMON_DATA.each { |p| refute_empty p['types'], "#{p['name']} のタイプが空" }
  end

  def test_no_で昇順に並んでいる
    nos = POKEMON_DATA.map { |p| p['no'] }
    assert_equal nos.sort, nos
  end

  def test_メガシンカは基本形と同じ_no_を持つ
    by_no = POKEMON_DATA.group_by { |p| p['no'] }
    POKEMON_DATA.select { |p| p['isMegaEvolution'] }.each do |mega|
      assert by_no[mega['no']].any? { |p| !p['isMegaEvolution'] },
             "#{mega['name']} (No.#{mega['no']}) に対応する基本形がない"
    end
  end

  def test_メガシンカは基本形より後ろに配置されている
    POKEMON_DATA.each_with_index do |p, i|
      next unless p['isMegaEvolution']

      base_index = POKEMON_DATA.index { |q| q['no'] == p['no'] && !q['isMegaEvolution'] }
      assert_operator base_index, :<, i, "#{p['name']} が基本形より前にある"
    end
  end

  def test_同一の_no_と名前の組み合わせが重複しない
    dup = POKEMON_DATA.map { |p| [p['no'], p['name'], p['form']] }.tally.select { |_, v| v > 1 }
    assert_empty dup, "重複エントリ: #{dup.keys.inspect}"
  end
end
