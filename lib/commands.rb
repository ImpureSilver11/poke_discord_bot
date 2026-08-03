require 'stringio'

# details の文面を RELEASE_* 定数から組み立てるため、COMMAND_SPECS の評価時点で必要になる
require_relative 'pokemon_release'

# 新しいスラッシュコマンドを追加する場合:
#   1. COMMAND_SPECS に定義を足す（登録と @メンション時のヘルプは両方ここから生成される）
#   2. bot.application_command でハンドラを定義する
#
# ヘルプを別に手書きすると必ず実装とずれるため、COMMAND_SPECS を唯一の定義元にしている。
#
# description は Discord のスラッシュコマンド登録にそのまま渡すため、
# **1〜100文字の1行**でなければ登録が拒否される。長い説明は details に書く。
# details は @メンション時のヘルプにだけ出るので、行数・長さの制約はゆるい。
COMMAND_SPECS = [
  {
    name: :pokemon_card,
    description: 'ポケモンカードの画像を検索して表示するジュラー',
    details: [
      '検索は完全一致->部分一致の順で行われるジュラー(サンド -> 0件ならサンドパンもヒット)',
      '見つからなかったら倒れるジュラー',
    ],
    options: [
      { type: :string, name: 'query', description: '検索ワード（ポケモン名・トレーナー名など）', required: true },
    ],
    example: '/pokemon_card query:サンドパン',
  },
  {
    name: :pokemon_stats,
    description: 'ポケモンの種族値を表示するジュラー',
    details: [
      'メガシンカポケモンも表示できるジュラー',
      '下のメッセージ欄に入力するジュラー',
    ],
    options: [
      { type: :string, name: 'pokemon_name', description: 'ポケモン名', required: true },
    ],
    example: '/pokemon_stats pokemon_name:メガリザードンX',
  },
  {
    name: :pokemon_release,
    description: 'これから発売されるポケモンカード商品の発売日とリンクを表示するジュラー',
    details: [
      "今日から#{RELEASE_LOOKAHEAD_MONTHS}ヶ月先までの発売予定を、発売日の早い順に最大#{RELEASE_MAX_ITEMS}件出すジュラー",
      '拡張パック・構築デッキ・グッズまで全部が対象ジュラー',
      '公式サイトの商品情報から取ってくるので、発売日が未発表の弾は出てこないジュラー',
    ],
    options: [],
    example: '/pokemon_release',
  },
].freeze

# Discord のスラッシュコマンド description の制約（1〜100文字）
COMMAND_DESCRIPTION_MAX = 100

# @メンションされたときに返すヘルプ本文を組み立てる。
# Discord のメッセージ上限は 2000 文字なので、超える場合は打ち切る。
def help_message(specs = COMMAND_SPECS)
  body = specs.map do |spec|
    lines = ["**/#{spec[:name]}** — #{spec[:description]}"]
    spec[:details].to_a.each { |line| lines << "　#{line}" }
    spec[:options].to_a.each do |opt|
      required = opt[:required] ? '必須' : '任意'
      lines << "　`#{opt[:name]}`（#{required}）: #{opt[:description]}"
    end
    lines << "　例: `#{spec[:example]}`" if spec[:example]
    lines.join("\n")
  end

  text = <<~HELP
    **ポケモンBot の使い方**
    以下のスラッシュコマンドが使えるジュラー

    #{body.join("\n\n")}

    このヘルプは @メンション で表示するジュラー。スラッシュコマンドの詳細は Discord の入力補完で確認できるジュラー。
  HELP

  text = "#{text[0, 1_997]}..." if text.length > 2_000
  text
end

def register_commands(bot)
  # ----------------------------------------
  # スラッシュコマンドの登録（定義は COMMAND_SPECS）
  # ----------------------------------------
  COMMAND_SPECS.each do |spec|
    bot.register_application_command(spec[:name], spec[:description]) do |t|
      spec[:options].to_a.each do |opt|
        t.public_send(opt[:type] || :string, opt[:name], opt[:description], required: opt[:required])
      end
    end
  end

  # ----------------------------------------
  # @メンション → ヘルプ
  # ----------------------------------------
  # MentionEvent は payload の mentions 配列で判定されるため、
  # 特権 intent (MESSAGE_CONTENT) がなくても発火する。
  bot.mention do |event|
    # 他の bot に反応してループするのを防ぐ
    if event.author.respond_to?(:bot_account?) && event.author.bot_account?
      puts '[mention] bot からのメンションなので無視しました'
      next
    end

    puts "[mention] ヘルプを返しました (user=#{event.author&.name})"
    event.send_message(help_message)
  end

  # ----------------------------------------
  # /pokemon_card
  # ----------------------------------------
  bot.application_command(:pokemon_card) do |event|
    pokemon_name = event.options['query']
    event.defer(ephemeral: false)
    puts "[pokemon_card] 実行 (query=#{pokemon_name})"

    result = download_first_tcg_pokemon_image(pokemon_name)

    if result.nil?
      # 失敗理由は下位のレイヤーが puts/warn 済みなので、ここは応答内容だけ記録する
      puts "[pokemon_card] 画像なしの応答を返しました (query=#{pokemon_name})"
      event.send_message(content: 'ティロンティロンティロティロロティロンティロ＞＜')
      next
    end

    image_bytes, filename = result
    send_interaction_followup_file(
      event.interaction.application_id,
      event.interaction.token,
      image_bytes,
      filename
    )
  end

  # ----------------------------------------
  # /pokemon_stats
  # ----------------------------------------
  bot.application_command(:pokemon_stats) do |event|
    input   = event.options['pokemon_name']
    matches = find_pokemon(input)

    if matches.empty?
      event.respond(content: "「#{input}」に一致するポケモンが見つかりませんでした。")
      next
    end

    event.respond(content: matches.map { |p| format_stats(p) }.join("\n\n"))
  end

  # ----------------------------------------
  # /pokemon_release
  # ----------------------------------------
  bot.application_command(:pokemon_release) do |event|
    # 公式サイトへの問い合わせが Discord の応答期限（3秒）に間に合わない可能性があるため defer する
    event.defer(ephemeral: false)
    puts '[pokemon_release] 実行'

    products = fetch_upcoming_products
    puts "[pokemon_release] #{products.nil? ? '取得失敗' : "#{products.size} 件"}の応答を返しました"
    event.send_message(content: format_upcoming_products(products))
  end
end
