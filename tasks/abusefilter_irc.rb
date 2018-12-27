$LOAD_PATH << '..'
require 'musikbot'
require 'cinch'
require 'em-eventsource'

module AbuseFilterIRC
  include Cinch::Plugin

  CHANNEL = '#wikipedia-en-abuse-log-all'

  def self.run
    credentials = YAML.load(
        File.open(
            File.dirname(__FILE__) + '/../config/application.yml'
        ).read
    ).symbolize_keys

    bot = Cinch::Bot.new do
      configure do |c|
        c.server = 'chat.freenode.org'
        c.channels = [CHANNEL]
        c.nick = credentials[:irc][:nick]
        c.password = credentials[:irc][:password]
        c.user = credentials[:irc][:user]
      end

      on :connect do
        EM.run do
          source = EventMachine::EventSource.new('https://stream.wikimedia.org/v2/stream/recentchange')

          source.on "message" do |message|
            data = JSON.parse(message)
            if data['wiki'] == 'enwiki' && data['log_action'] == 'hit'
              msg = "User:#{data['user'].tr(' ', '_')} tripped *filter-#{data['log_params']['filter']}* on [[#{data['title']}]]: " \
              "https://en.wikipedia.org/wiki/Special:AbuseLog/#{data['log_params']['log']}"

              Channel(CHANNEL).send(msg)
            end
          end

          source.error do |error|
            puts "EventStreams error: #{error}"
          end

          source.open do
            puts "EventStreams connection opened"
          end

          source.start
        end
      end

      on :message, "!ping" do |m|
        m.reply 'Pong.'
      end
    end

    bot.start
  end
end

AbuseFilterIRC.run
