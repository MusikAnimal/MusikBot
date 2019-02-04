$LOAD_PATH << '..'
require 'musikbot'
require 'cinch'
require 'em-eventsource'

module AbuseFilterIRC
  include Cinch::Plugin

  CHANNEL = '#wikipedia-en-abuse-log-all'
  UNSUBSCRIBE_MSG = 'To unsubscribe, use !unsubscribe [filter ID] or !unsubscribe all'

  def self.run
    $mb = MusikBot::Session.new(inspect)

    bot = Cinch::Bot.new do
      configure do |c|
        c.server = 'chat.freenode.org'
        c.channels = [CHANNEL]
        c.nick = $mb.app_config[:irc][:nick]
        c.password = $mb.app_config[:irc][:password]
        c.user = $mb.app_config[:irc][:user]
      end

      helpers do
        def authed(user)
          unless user.authed?
            user.send "Your IRC nick must be identified to subscribe to filters. See https://freenode.net/kb/answer/registration"
            return false
          end

          true
        end
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

              $mb.local_storage['subscriptions'].each do |user, filter_ids|
                if filter_ids.include?(data['log_params']['filter'].to_i)
                  User(user).send msg
                end
              end
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

      on :message, /!subscribe (\d+)/ do |m, filter_id|
        return unless authed(m.user)

        storage = $mb.local_storage
        storage['subscriptions'][m.user.nick] ||= []
        storage['subscriptions'][m.user.nick] |= [filter_id.to_i]
        storage['subscriptions']
        $mb.local_storage(storage)

        m.user.send "You have subscribed to filter #{filter_id}"
        m.user.send UNSUBSCRIBE_MSG
      end

      on :message, /!unsubscribe (\d+|all)/ do |m, filter_id|
        return unless authed(m.user)

        storage = $mb.local_storage
        storage['subscriptions'][m.user.nick] ||= []
        if 'all' == filter_id
          storage['subscriptions'][m.user.nick] = []
          m.user.send "You have unsubscribed to all filters"
        else
          storage['subscriptions'][m.user.nick].delete(filter_id.to_i)
          m.user.send "You have unsubscribed to filter #{filter_id}"
        end
        $mb.local_storage(storage)
      end

      on :message, /!subscriptions/ do |m|
        return unless authed(m.user)

        subscriptions = ($mb.local_storage['subscriptions'][m.user.nick] rescue []).map(&:to_i).sort.join(', ')
        m.user.send "You are subscribed to the following filters: #{subscriptions}"
        m.user.send UNSUBSCRIBE_MSG
      end
    end

    bot.start
  end
end

AbuseFilterIRC.run
