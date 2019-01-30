$LOAD_PATH << '..'
require 'musikbot'
require 'cinch'
require 'em-eventsource'

###
# Schema for the database:
#
# CREATE TABLE subscriptions (
#   id INT NOT NULL PRIMARY KEY AUTO_INCREMENT,
#   project VARCHAR(30) NOT NULL,
#   user VARCHAR(255) NOT NULL,
#   filter_id INT NOT NULL
# );
# CREATE UNIQUE INDEX proj_user_sub ON subscriptions (project, user, filter_id);
###

module AbuseFilterIRC
  include Cinch::Plugin

  CHANNELS = {
    # 'enwiki' => '#wikipedia-en-abuse-log-all',
    # 'enwiki' => '##MusikBot',
    'commons.wikimedia.org' => '#wikimedia-commons-abuse-log',
    'en.wikipedia.org' => '##MusikBot'
  }

  UNSUBSCRIBE_MSG = 'To unsubscribe, use !unsubscribe [filter ID] or !unsubscribe all'

  def self.run
    $mb = MusikBot::Session.new(inspect, true, true)
    $client = $mb.repl_client(credentials: :toolsdb, log: false)
    $subscriptions = nil

    bot = Cinch::Bot.new do
      configure do |c|
        c.server = 'chat.freenode.org'
        c.channels = CHANNELS.values
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

        def load_subscriptions
          $subscriptions = {}

          $client.query('SELECT * FROM subscriptions').to_a.each do |row|
            $subscriptions[row['project']] ||= {}
            $subscriptions[row['project']][row['user']] ||= []
            $subscriptions[row['project']][row['user']] << row['filter_id']
          end
        end

        def validate_project(user, project)
          if !CHANNELS.keys.include?(project)
            user.send "#{project} is an invalid project or is currently unsupported."
            user.send "Supported projects include: " + CHANNELS.keys.join(', ')
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
            if CHANNELS.keys.include?(data['server_name']) && data['log_action'] == 'hit'
              msg = "User:#{data['user'].tr(' ', '_')} tripped *filter-#{data['log_params']['filter']}* on [[#{data['title']}]]: " \
                "https://#{data['server_name']}/wiki/Special:AbuseLog/#{data['log_params']['log']}"

              Channel(CHANNELS[data['server_name']]).send(msg)

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

      on :message, /!subscribe (\w+\.\w+\.org) (\d+)/ do |m, project, filter_id|
        return unless authed(m.user)
        return unless validate_project(m.user, project)

        statement = $client.prepare('INSERT INTO subscriptions VALUES(NULL, ?, ?, ?)')
        statement.execute(project, m.user.nick, filter_id.to_i)

        load_subscriptions

        m.user.send "You have subscribed to filter #{filter_id}"
        m.user.send UNSUBSCRIBE_MSG
      end

      on :message, /!unsubscribe (\w+\.\w+\.org) (\d+|all)/ do |m, project, filter_id|
        return unless authed(m.user)
        return unless validate_project(m.user, project)

        statement = $client.prepare('DELETE FROM subscriptions WHERE project = ? AND user = ? AND filter_id = ?')
        statement.execute(project, m.user.nick, filter_id.to_i)

        load_subscriptions

        if 'all' == filter_id
          storage['subscriptions'][m.user.nick] = []
          m.user.send "You have unsubscribed to all filters"
        else
          storage['subscriptions'][m.user.nick].delete(filter_id.to_i)
          m.user.send "You have unsubscribed to filter #{filter_id}"
        end
        $mb.local_storage(storage)
      end

      on :message, /!subscriptions (\w+\.\w+\.org)/ do |m, project|
        return unless authed(m.user)

        if project.present?
          return unless validate_project(m.user, project)

          statement = $client.prepare('SELECT filter_id FROM subscriptions WHERE project = ? AND user = ?')
          subscriptions = statement.execute(project, m.user.nick).to_a.collect { |row| row['filter_id'] }.join(', ')
        else
          statement = $client.prepare('SELECT project, filter_id FROM subscriptions WHERE user = ?')

          data = {}
          statement.execute(project, m.user.nick).to_a.each do |row|
            data[row['project']] ||= {}
            data[row['project']] << row['filter_id']
          end

          subscriptions = ''
          data.each do |proj, filter_ids|
            subscriptions += proj + ' = ' + filter_ids.join(', ') + '; '
          end
          subscriptions.chomp!('; ')
        end

        m.user.send "You are subscribed to the following filters: #{subscriptions}"
        m.user.send UNSUBSCRIBE_MSG
      end
    end

    bot.start
  end
end

AbuseFilterIRC.run
