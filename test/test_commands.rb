require_relative 'test_helper'
require 'discordrb'
require 'commands'

# register_commands / mention ハンドラを Discord に繋がずに検証するための代用オブジェクト。
# オプション組み立てだけは discordrb の本物の OptionBuilder を使う。
# ここを自作の偽物にすると、gem 側の API が変わったときに気付けなくなるため。
class FakeBot
  attr_reader :commands, :handlers, :mention_handlers

  def initialize
    @commands         = []
    @handlers         = {}
    @mention_handlers = []
  end

  def register_application_command(name, description, **_kwargs)
    builder = Discordrb::Interactions::OptionBuilder.new
    yield(builder) if block_given?
    @commands << { name: name, description: description, options: builder.to_a }
  end

  def application_command(name, &block)
    @handlers[name] = block
  end

  def mention(&block)
    @mention_handlers << block
  end
end

class FakeAuthor
  attr_reader :name

  def initialize(name, bot_account)
    @name        = name
    @bot_account = bot_account
  end

  def bot_account?
    @bot_account
  end
end

class FakeMentionEvent
  attr_reader :author, :sent

  def initialize(author)
    @author = author
    @sent   = []
  end

  def send_message(content)
    @sent << content
  end
end

# スラッシュコマンドの登録
class TestRegisterCommands < PokeTestCase
  def setup
    super
    @bot = FakeBot.new
    silently { register_commands(@bot) }
  end

  def test_COMMAND_SPECS_の全コマンドを登録する
    assert_equal COMMAND_SPECS.map { |s| s[:name] }, @bot.commands.map { |c| c[:name] }
  end

  def test_説明文を定義どおりに登録する
    COMMAND_SPECS.each do |spec|
      registered = @bot.commands.find { |c| c[:name] == spec[:name] }
      assert_equal spec[:description], registered[:description]
    end
  end

  # 宣言的な定義から組み立てても、従来の t.string(...) と同じ payload になること
  def test_オプションが正しいpayloadになる
    card = @bot.commands.find { |c| c[:name] == :pokemon_card }
    assert_equal(
      [{ type: 3, name: 'query', description: '検索ワード（ポケモン名・トレーナー名など）', required: true }],
      card[:options]
    )
  end

  def test_全コマンドのオプションが定義と一致する
    COMMAND_SPECS.each do |spec|
      registered = @bot.commands.find { |c| c[:name] == spec[:name] }
      assert_equal spec[:options].size, registered[:options].size, "#{spec[:name]} のオプション数が違う"
      spec[:options].each_with_index do |opt, i|
        assert_equal opt[:name].to_s,        registered[:options][i][:name]
        assert_equal opt[:description],      registered[:options][i][:description]
        assert_equal opt[:required],         registered[:options][i][:required]
      end
    end
  end

  def test_各コマンドのハンドラが登録される
    COMMAND_SPECS.each { |spec| assert @bot.handlers.key?(spec[:name]), "#{spec[:name]} のハンドラがない" }
  end

  def test_メンションハンドラが登録される
    assert_equal 1, @bot.mention_handlers.size
  end
end

# @メンション時の挙動
class TestMentionHandler < PokeTestCase
  def setup
    super
    @bot = FakeBot.new
    silently { register_commands(@bot) }
    @handler = @bot.mention_handlers.first
  end

  def test_人間からのメンションにヘルプを返す
    event = FakeMentionEvent.new(FakeAuthor.new('takahashi', false))
    silently { @handler.call(event) }

    assert_equal 1, event.sent.size
    assert_equal help_message, event.sent.first
  end

  # 他の bot に反応すると相互に反応し合って無限ループになりうる
  def test_bot_からのメンションは無視する
    event = FakeMentionEvent.new(FakeAuthor.new('other-bot', true))
    silently { @handler.call(event) }

    assert_empty event.sent
  end

  def test_ヘルプ送信は_stdout_に記録され_stderr_は空
    event = FakeMentionEvent.new(FakeAuthor.new('takahashi', false))
    out, err = capture_io { @handler.call(event) }

    assert_includes out, '[mention]'
    assert_empty err
  end
end

# ヘルプ本文
class TestHelpMessage < PokeTestCase
  def test_全コマンドの名前と説明を含む
    text = help_message
    COMMAND_SPECS.each do |spec|
      assert_includes text, "/#{spec[:name]}",     "#{spec[:name]} がヘルプに載っていない"
      assert_includes text, spec[:description],    "#{spec[:name]} の説明がヘルプに載っていない"
    end
  end

  def test_全オプションの名前と説明を含む
    text = help_message
    COMMAND_SPECS.flat_map { |s| s[:options].to_a }.each do |opt|
      assert_includes text, opt[:name]
      assert_includes text, opt[:description]
    end
  end

  def test_必須と任意を出し分ける
    specs = [{ name: :dummy, description: 'd', options: [
      { name: 'a', description: 'A', required: true },
      { name: 'b', description: 'B', required: false },
    ] }]
    text = help_message(specs)

    assert_includes text, '`a`（必須）: A'
    assert_includes text, '`b`（任意）: B'
  end

  def test_例があれば載せる
    assert_includes help_message, '例: `/pokemon_card query:ピカチュウ`'
  end

  def test_例が無くても落ちない
    text = help_message([{ name: :dummy, description: 'せつめい', options: [] }])

    assert_includes text, '/dummy'
    refute_includes text, '例:'
  end

  def test_オプションが無いコマンドも扱える
    assert_includes help_message([{ name: :noopt, description: 'せつめい' }]), '**/noopt** — せつめい'
  end

  def test_メンションで表示できることを案内する
    assert_includes help_message, '@メンション'
  end

  # Discord のメッセージ上限は 2000 文字
  def test_現在のヘルプは上限内
    assert_operator help_message.length, :<=, 2_000
  end

  def test_上限を超える場合は打ち切る
    many = Array.new(200) do |i|
      { name: :"cmd#{i}", description: 'せつめい' * 10, options: [{ name: 'opt', description: 'x' * 50, required: true }] }
    end
    text = help_message(many)

    assert_operator text.length, :<=, 2_000
    assert text.end_with?('...'), '打ち切りの目印がない'
  end
end
