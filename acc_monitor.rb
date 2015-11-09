$LOAD_PATH << '.'
require 'mysql2'
require 'mediawiki-gateway'
require 'repl'
require 'httparty'
require 'auth.rb'
require 'date'
require 'pry-byebug'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'

class Object
  def present?
    !blank?
  end

  def blank?
    respond_to?(:empty?) ? empty? : !self
  end
end

module ACCMonitor
  def self.run
    @mw = MediaWiki::Gateway.new('https://en.wikipedia.org/w/api.php', bot: true)
    Auth.login(@mw)

    @env = eval(File.open('env').read)

    exit 1 unless @env == :test || get_page('User:MusikBot/ACCMonitor/Run') == 'true'

    un, pw, host, db, port = Auth.db_credentials(@env)
    @repl_client = Repl::Session.new(un, pw, host, db, port)
    @getter = HTTParty

    normal_header = "{| class='wikitable sortable'\n! Username\n! Total actions\n! style='min-width:100px' " \
      "| Last action\n! Reason granted\n! style='min-width:85px' | Rights log\n|-\n"
    @acc_markup = "==Account creation team==\n{| class='wikitable sortable'\n! Username\n! Total actions\n! style='min-width:100px' " \
      "| Last ACC action\n! Reason granted\n! style='min-width:85px' | Rights log\n|-\n"
    @educators_markup = "==Education program==\n{| class='wikitable sortable'\n! Username\n! EP rights\n! Total actions\n" \
      "! style='min-width:100px' | Last action\n! Reason granted\n! style='min-width:85px' | Rights log\n|-\n"
    @event_coordinators_markup = "==Event coordinators==\n{| class='wikitable sortable'\n! Username\n! Event date\n! Total actions\n" \
      "! style='min-width:100px' | Last action\n! Reason granted\n! style='min-width:85px' | Rights log\n|-\n"
    @other_users_markup = "==Other==\n" + normal_header

    @user_count = 0
    process_accounts

    @coordinator_count = 0
    process_event_coordinators

    issue_report
  end

  def self.process_accounts
    account_creators.each_with_index do |account_creator, index|
      username = account_creator['user_name']
      puts "Checking #{account_creator}, index #{index} of #{account_creators.to_a.length}"

      next if whitelisted_users.include?(username)

      # queries
      user_actions = logged_actions(username).reject { |la| la['log_title'] == username }
      rights_log = rights_changes(username).select { |rc| rc['log_params'].scan(/accountcreator/).length == 1 }
      last_action = Date.parse(user_actions.first['log_timestamp']) rescue nil
      permissions = user_groups(username).collect { |ug| ug['ug_group'] }
      acc_info = acc_stats(username)

      if acc_info
        acc_last_action = Date.parse(acc_info['lastactive']) rescue nil
        acc_active = acc_last_action > Date.today - num_days rescue nil
      end

      next if acc_active || (last_action && last_action > Date.today - num_days)
      # next unless acc_inactive || last_action.nil? || (last_action < Date.today - num_days && acc_info.nil?)

      puts '  meets inactivity threshold'
      @user_count += 1

      user = {
        username: username,
        rights_log: rights_log.reverse,
        num_actions: user_actions.length,
        last_action: last_action ? last_action.strftime('%Y %B %-d') : '-'
      }

      if (ep_groups & permissions).any?
        user[:user_groups] = permissions
        @educators_markup += ep_entry(user)
      elsif acc_info.present?
        user[:acc_type] = acc_info['status']
        user[:acc_last_action] = acc_last_action ? acc_last_action.strftime('%Y %B %-d') : '-'
        @acc_markup += acc_entry(user)
      elsif acc_info.nil?
        @other_users_markup += normal_entry(user)
      end
    end
  rescue => e
    if @env == :test
      raise e
    else
      report_error(e.message)
    end
  end

  def self.process_event_coordinators
    usernames = []

    event_coordinators.each do |user|
      next if user[:event_date] > Date.today || whitelisted_users.include?(user[:username])
      usernames << user[:username]
      permissions = user_groups(user[:username]).collect { |ug| ug['ug_group'] }

      if permissions.include?('accountcreator') || ['Example', 'Test', 'Test user'].include?(user[:username])
        user[:num_actions] = logged_actions(user[:username]).reject { |la| la['log_title'] == user[:username] }.length
        user[:last_action] = Date.parse(user_actions.first['log_timestamp']).strftime('%Y %B %-d') rescue '-'
        user[:rights_log] = rights_changes(user[:username]).select { |rc| rc['log_params'].scan(/accountcreator/).length == 1 }.reverse

        @coordinator_count += 1
        @event_coordinators_markup += ec_entry(user)
      end

      @event_coordinators_text.gsub!("\n#{@event_coordinator_entries[user[:index]]}", '')
    end

    edit_page('User:MusikBot/ACCMonitor/Event coordinators', @event_coordinators_text, "Removing event coordinators: #{usernames.join(', ')}")
  end

  def self.issue_report
    total = @user_count + @coordinator_count
    percentage = ((total.to_f / account_creators.to_a.length.to_f) * 100).round
    content = "<div style='font-size:24px'>Inactive account creators as of #{Date.today.strftime('%-d %B %Y')}</div>\n" \
      "'''#{total}''' out of #{account_creators.to_a.length} (#{percentage}%) account creators eligible for revocation\n\n" \
      "'''{{User:MusikBot/ACCMonitor/Count}}''' users with no account creation activity in the past {{User:MusikBot/ACCMonitor/Offset}} days\n\n" \
      "'''{{User:MusikBot/ACCMonitor/Coordinator count}}''' event coordinators with expired account creator privileges\n\n" \
      "<small>''NOTE: Total actions excludes creation of their own account. " \
      "Rights log only shows entries where {{mono|accountcreator}} was granted or revoked.''\n\n" \
      "''If an account creator is inactive but not eligible for revocation of the right (such as an alternate account), they can be added to the [[User:MusikBot/ACCMonitor/Whitelist|whitelist]].''</small>\n\n"

    content += @acc_markup.chomp("|-\n") + "|}\n\n"
    content += @educators_markup.chomp("|-\n") + "|}\n\n"
    content += @event_coordinators_markup.chomp("|-\n") + "|}\n\n"
    content += @other_users_markup.chomp("|-\n") + "|}\n\n"

    edit_page('User:MusikBot/ACCMonitor/Tracking', content, "Reporting account creation inactivity of #{@user_count} users")
    edit_page('User:MusikBot/ACCMonitor/Count', @user_count.to_s, "Reporting #{@user_count} inactive account creators")
    edit_page('User:MusikBot/ACCMonitor/Coordinator count', @coordinator_count.to_s, "Reporting #{@coordinator_count} event coordinators with expired account creator privileges")
  end

  def self.normal_entry(user)
    most_recent_reason = user[:rights_log].first['log_comment'] rescue ''
    rights_log_content = rights_log_markup(user[:username], user[:rights_log])
    "| {{user-multi|user=#{user[:username]}|t|cr}}\n| #{user[:num_actions]}\n| #{user[:last_action]}\n| #{most_recent_reason}\n| #{rights_log_content}\n|-\n"
  end

  def self.acc_entry(user)
    most_recent_reason = user[:rights_log].first['log_comment'] rescue ''
    rights_log_content = rights_log_markup(user[:username], user[:rights_log])
    "| {{user-multi|user=#{user[:username]}|t|cr}}\n| #{user[:num_actions]}\n| #{user[:acc_last_action]}\n| #{most_recent_reason}\n| #{rights_log_content}\n|-\n"
  end

  def self.ep_entry(user)
    most_recent_reason = user[:rights_log].first['log_comment'] rescue ''
    rights_log_content = rights_log_markup(user[:username], user[:rights_log])
    ep_rights = user[:user_groups].select { |ug| ep_groups.include?(ug) }
    "| {{user-multi|user=#{user[:username]}|t|cr}}\n| #{ep_rights.join(', ')}\n| #{user[:num_actions]}\n| #{user[:last_action]}\n| #{most_recent_reason}\n| #{rights_log_content}\n|-\n"
  end

  def self.ec_entry(user)
    most_recent_reason = user[:rights_log].first['log_comment'] rescue ''
    rights_log_content = rights_log_markup(user[:username], user[:rights_log])
    "| {{user-multi|user=#{user[:username]}|t|cr}}\n| #{user[:event_date]}\n| #{user[:num_actions]}\n| #{user[:last_action]}\n| #{most_recent_reason}\n| #{rights_log_content}\n|-\n"
  end

  def self.rights_log_markup(username, rights_log)
    markup = "{{collapse top|bg=transparent|bg2=transparent|border=0|border2=transparent|padding=0|title={{/Log link|#{username}}}}}\n"
    rights_log.each do |entry|
      date = Date.parse(entry['log_timestamp']).strftime('%-d %B %Y')
      userlinks = "{{u|#{entry['log_user_text']}}}"
      granted = entry['log_params'] =~ /oldgroups.*accountcreator.*newgroups/ ? 'Revoked' : 'Granted'
      markup += "* #{date} - #{granted} by #{userlinks} - ''#{entry['log_comment']}''\n"
    end
    markup += '{{collapse bottom}}'
  end

  def self.ep_groups
    %w(epcampus epinstructor eponline epcoordinator)
  end

  def self.event_coordinators
    return @event_coordinators if @event_coordinators
    @event_coordinator_entries = event_coordinators_text.split(/\=\=\s*Event\s+coordinators\s*\=\=/)[1].split(/\n/).drop(2)
    @event_coordinators = []
    @event_coordinator_entries.each_with_index do |entry, index|
      matches = entry.scan(/{{\s*no\s*ping\s*\|(.*?)}}(.*)/i).flatten
      @event_coordinators << {
        username: matches[0].strip,
        event_date: Date.parse(matches[1]),
        index: index
      }
    end
    @event_coordinators
  rescue => e
    report_error("Unable to parse event coordinators page! Error: #{e.message}")
  end

  # API related
  def self.event_coordinators_text
    @event_coordinators_text ||= get_page('User:MusikBot/ACCMonitor/Event coordinators')
  end

  def self.whitelisted_users
    @whitelisted_users ||= get_page('User:MusikBot/ACCMonitor/Whitelist').split(/^\*/).drop(1).map { |u| u.chomp("\n") }
  end

  def self.num_days
    @num_days ||= get_page('User:MusikBot/ACCMonitor/Offset').to_i
  end

  def self.get_page(page, throttle = 0)
    sleep throttle * 5
    @mw.get(page)
  rescue MediaWiki::APIError => e
    raise e and return false if throttle > 5
    get_page(page, throttle + 1)
  end

  def self.edit_page(page, content, summary, throttle = 0)
    sleep throttle * 5
    opts = {
      contentformat: 'text/x-wiki',
      summary: summary
    }
    @mw.edit(page, CGI.unescapeHTML(content), opts)
    return true
  rescue MediaWiki::APIError => e
    raise e and return false if throttle > 5
    edit_page(page, content, summary, throttle + 1)
  end

  def self.report_error(message)
    content = get_page('User:MusikBot/ACCMonitor/Error log') + "\n\n#{message} &mdash; ~~~~~\n\n"
    edit('User:MusikBot/ACCMonitor/Error log', content, 'Reporting ACCMonitor errors')
  end

  private

  # Replication database related
  def self.account_creators
    return @account_creators if @account_creators

    @repl_client.query('SELECT user_name FROM enwiki_p.user JOIN user_groups ' \
      "WHERE ug_group = 'accountcreator' AND ug_user = user_id;")
  end

  def self.user_groups(username)
    @repl_client.query('SELECT ug_group FROM enwiki_p.user_groups ' \
      "JOIN user WHERE user_name = '#{username}' AND ug_user = user_id;")
  end

  def self.rights_changes(username)
    @repl_client.query('SELECT log_timestamp, log_comment, log_user_text, log_params ' \
      "FROM logging_logindex WHERE log_title = '#{username}' AND log_type = 'rights';")
  end

  def self.logged_actions(username)
    @repl_client.query('SELECT log_timestamp, log_title FROM logging_userindex ' \
      "WHERE log_user_text = '#{username}' AND log_type = 'newusers' " \
      'ORDER BY log_timestamp DESC;')
  end

  # HTTParty
  def self.acc_stats(username)
    res = @getter.get('http://accounts.wmflabs.org/api.php', query: {
      action: 'stats',
      user: username
    })['api']['user']
    res['missing'] ? nil : res
  end
end

ACCMonitor.run
