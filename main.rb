require 'dotenv'
require 'discordrb'
require_relative 'lib/pokemon_image'
require_relative 'lib/pokemon_stats'
require_relative 'lib/discord_helper'
require_relative 'lib/commands'

Dotenv.load

TOKEN = ENV['TOKEN']
raise '.env に TOKEN=DiscordのBotトークン を設定してください' if TOKEN.nil?

bot = Discordrb::Bot.new(token: TOKEN, intents: [:server_messages, :direct_messages])

register_commands(bot)

bot.run
