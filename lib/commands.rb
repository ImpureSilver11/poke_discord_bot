require 'stringio'

# 新しいスラッシュコマンドを追加する場合:
#   1. bot.register_application_command でコマンドを登録する
#   2. bot.application_command でハンドラを定義する

def register_commands(bot)
  # ----------------------------------------
  # /pokemon_card
  # ----------------------------------------
  bot.register_application_command(:pokemon_card, 'ポケモンカードの画像を検索して表示します') do |t|
    t.string('query', '検索ワード（ポケモン名・トレーナー名など）', required: true)
  end

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
  bot.register_application_command(:pokemon_stats, 'ポケモンの種族値を表示します') do |t|
    t.string('pokemon_name', 'ポケモン名', required: true)
  end

  bot.application_command(:pokemon_stats) do |event|
    input   = event.options['pokemon_name']
    matches = find_pokemon(input)

    if matches.empty?
      event.respond(content: "「#{input}」に一致するポケモンが見つかりませんでした。")
      next
    end

    event.respond(content: matches.map { |p| format_stats(p) }.join("\n\n"))
  end
end
