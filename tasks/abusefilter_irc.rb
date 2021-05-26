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
# ) ENGINE=InnoDB DEFAULT CHARSET=utf8 ROW_FORMAT=DYNAMIC;
# CREATE UNIQUE INDEX proj_user_sub ON subscriptions (project, user, filter_id);
###

module AbuseFilterIRC
  include Cinch::Plugin

  CHANNELS = {
    'commons.wikimedia.org' => '#wikimedia-commons-abuse-log',
    'en.wikipedia.org' => '#wikipedia-en-abuse-log-all',
    'meta.wikimedia.org' => '#wikimedia-meta-abuse-log'
  }

  UNSUBSCRIBE_MSG = 'To unsubscribe, use `!unsubscribe [lang.project.org] [filter ID]` or `!unsubscribe [lang.project.org] all`'

  def self.run
    $mb = MusikBot::Session.new(inspect)
    $client = $mb.repl_client(credentials: :abusefilter_irc, log: false)
    $subscriptions = nil

    bot = Cinch::Bot.new do
      configure do |c|
        c.server = 'irc.libera.chat'
        c.port = 6667
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
            user.send "'#{project}' is an invalid project or is currently unsupported."
            user.send "Supported projects include: " + CHANNELS.keys.join(', ')
            user.send "Contact musikanimal about requesting new projects."
            return false
          end

          true
        end
      end

      on :connect do
        load_subscriptions

        EM.run do
          source = EventMachine::EventSource.new('https://stream.wikimedia.org/v2/stream/recentchange')

          source.on "message" do |message|
            data = JSON.parse(message)
            if data['log_action'] == 'hit' && (CHANNELS.keys.include?(data['server_name']) || data['log_params']['filter'].to_s.include?('global'))
              irc_wiki = data['log_params']['filter'].to_s.include?('global') ? 'meta.wikimedia.org' : data['server_name']
              msg = "User:#{data['user'].score} tripped *filter-#{data['log_params']['filter']}* on [[#{data['title']}]]: " \
                "https://#{data['server_name']}/wiki/Special:AbuseLog/#{data['log_params']['log']}"

              Channel(CHANNELS[irc_wiki]).send(msg)

              $subscriptions[irc_wiki] ||= {}
              $subscriptions[irc_wiki].each do |user, filter_ids|
                if filter_ids.include?(data['log_params']['filter'].to_s.scan(/\d+/)[0].to_i)
                  if user =~ /^#.*/
                    Channel(user).join
                    Channel(user).send(msg)
                  else
                    User(user).send(msg)
                  end
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

      # Channel subscribe
      on :message, /^!subscribe (\w+\.\w+\.org) (\d+|all) #([#\w\-]+)$/ do |m, project, filter_id, channel|
        return unless authed(m.user)
        return unless validate_project(m.user, project)

        channel = '#' + channel
        Channel(channel).join

        m.user.send "Please wait..."

        # FIXME: Huge hack... need to somehow know when the bot actually joined.
        sleep 2

        unless Channel(channel).opped?(m.user)
          Channel(channel).part
          return m.user.send "You must be opped in #{channel} to subscribe filters to it."
        end

        statement = $client.prepare('INSERT IGNORE INTO subscriptions VALUES(NULL, ?, ?, ?)')
        statement.execute(project, channel, filter_id.to_i)

        load_subscriptions

        m.user.send "#{channel} has been subscribed to filter #{filter_id} on #{project}"

        Channel(channel).send("This channel has been subscribed to filter #{filter_id} on #{project}")
        Channel(channel).send("To unsubscribe, ops can run `!unsubscribe [lang.project.org] [filter ID] [channel name]` or `!unsubscribe [lang.project.org] [channel name] all`")
      end

      # User subscribe
      on :message, /^!subscribe (\w+\.\w+\.org) (\d+)$/ do |m, project, filter_id|
        return unless authed(m.user)
        return unless validate_project(m.user, project)

        statement = $client.prepare('INSERT IGNORE INTO subscriptions VALUES(NULL, ?, ?, ?)')
        statement.execute(project, m.user.nick, filter_id.to_i)

        load_subscriptions

        m.user.send "You have subscribed to filter #{filter_id} on #{project}"
        m.user.send UNSUBSCRIBE_MSG
      end

      # Channel unsubscribe
      on :message, /^!unsubscribe (\w+\.\w+\.org) (\d+|all) #([#\w\-]+)$/ do |m, project, filter_id, channel|
        return unless authed(m.user)
        return unless validate_project(m.user, project)

        channel = '#' + channel
        Channel(channel).join

        m.user.send "Please wait..."

        # FIXME: Huge hack... need to somehow know when the bot actually joined.
        sleep 2

        unless Channel(channel).opped?(m.user)
          return m.user.send "You must be opped in #{channel} to manage subscriptions."
        end

        if 'all' == filter_id
          statement = $client.prepare('DELETE FROM subscriptions WHERE project = ? AND user = ?')
          statement.execute(project, channel)
          m.user.send "#{channel} has unsubscribed to all filters on #{project}"
        else
          statement = $client.prepare('DELETE FROM subscriptions WHERE project = ? AND user = ? AND filter_id = ?')
          statement.execute(project, channel, filter_id.to_i)
          m.user.send "#{channel} has unsubscribed to filter #{filter_id} on #{project}"
        end

        load_subscriptions

        Channel(channel).send("This channel has been unsubscribed to filter #{filter_id} on #{project}")
      end

      # User unsubscribe
      on :message, /^!unsubscribe (\w+\.\w+\.org) (\d+|all)$/ do |m, project, filter_id|
        return unless authed(m.user)
        return unless validate_project(m.user, project)

        if 'all' == filter_id
          statement = $client.prepare('DELETE FROM subscriptions WHERE project = ? AND user = ?')
          statement.execute(project, m.user.nick)
          m.user.send "You have unsubscribed to all filters on #{project}"
        else
          statement = $client.prepare('DELETE FROM subscriptions WHERE project = ? AND user = ? AND filter_id = ?')
          statement.execute(project, m.user.nick, filter_id.to_i)
          m.user.send "You have unsubscribed to filter #{filter_id}"
        end

        load_subscriptions
      end

      on :message, /^!subscriptions( \w+\.\w+\.org)?/ do |m, project|
        return unless authed(m.user)

        if project.present?
          project = project.strip
          return unless validate_project(m.user, project)

          statement = $client.prepare('SELECT filter_id FROM subscriptions WHERE project = ? AND user = ?')
          subscriptions = statement.execute(project, m.user.nick).to_a.collect { |row| row['filter_id'] }.join(', ')
        else
          statement = $client.prepare('SELECT project, filter_id FROM subscriptions WHERE user = ?')

          data = {}
          statement.execute(m.user.nick).to_a.each do |row|
            data[row['project']] ||= []
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
