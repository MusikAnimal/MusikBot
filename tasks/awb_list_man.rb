$LOAD_PATH << '..'
require 'musikbot'

module AWBListMan
  AWB_CHECKPAGE = 'Wikipedia:AutoWikiBrowser/CheckPageJSON'.freeze
  REPORT_PAGE = 'User:MusikBot II/AWBListMan/Report'.freeze

  def self.run
    @mb = MusikBot::Session.new(inspect)

    @disk_cache = @mb.local_storage || {
      'enabled_users' => [],
      'last_run' => @mb.now.to_s,
      'report' => {},
      'notified_users' => {}
    }
    @old_users = @disk_cache['enabled_users'] || []
    @last_run = @mb.parse_date(@disk_cache['last_run'])
    @old_report = @disk_cache['report']
    @new_report = {}
    @notified_users = {}
    @current_users = get_users()
    @new_users = {}

    # List of users to actually be saved to the CheckPage
    checkpage_users = {}

    all_new_users = []

    edit_summaries = []

    [:bot, :user].each do |user_type|
      config = @mb.config[user_type]
      @removed_users = {
        admins: [],
        indefinitely_blocked: [],
        inactive: []
      }
      @renamed_users = []
      @new_users[user_type] = process_users(@current_users, user_type)

      # which list of users to go off of based on whether we're editing the CheckPage
      # or just making a report of those who would be revoked as if we were editing the page
      if config[:enabled]
        users_list = @new_users[user_type]
        edit_summaries << edit_summary()
      else
        users_list = @current_users[user_type]
      end

      all_new_users += users_list
      checkpage_users[user_type] = users_list

      user_type_str = user_type.to_s.capitalize_first
      @mb.edit("#{REPORT_PAGE}/#{user_type_str}",
        content: report_page(user_type),
        summary: "#{user_type_str}s: #{edit_summary(true)}"
      )

      @mb.edit("User:MusikBot II/AWBListMan/#{user_type_str} count",
        content: users_list.length,
        summary: "Reporting #{user_type.to_s.pluralize_num(users_list.length)} with AWB access"
      )
    end

    @mb.edit(REPORT_PAGE,
      content: "<div style='font-size:24px'>AWB CheckPage report as of #{@mb.today} <sup>({{purge}})</sup></div>",
      section: 0,
      summary: 'Updating heading of report page'
    )

    # Update the actual CheckPage
    @mb.edit(AWB_CHECKPAGE,
      content: {
        'enabledusers' => checkpage_users[:user],
        'enabledbots' => checkpage_users[:bot]
      }.to_json,
      summary: edit_summaries.join('; ')
    )

    @mb.local_storage(
      'last_run' => @mb.now.to_s,
      'enabled_users' => all_new_users.uniq,
      'report' => @new_report,
      'notified_users' => @notified_users
    )
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.get_users
    content = JSON.parse(@mb.get(AWB_CHECKPAGE))
    {
      bot: content['enabledbots'],
      user: content['enabledusers']
    }
  end

  def self.process_users(users, user_type)
    new_users = []

    current_users = users[user_type].uniq.sort

    current_users.each do |user_name|
      moved_info = moved_user_info(user_name)

      if moved_info && moved_info[:timestamp] > @last_run && @old_users.include?(user_name)
        new_user_name = moved_info[:new_user_name].force_encoding('utf-8')
        puts "#{user_name} - renamed to #{new_user_name}"
        @renamed_users << new_user_name
        user_name = new_user_name
      end

      info = user_info(user_name)

      if info[:user_groups].include?('sysop')
        puts user_name + ' - is sysop'
        @removed_users[:admins] << user_name
      elsif info[:block_time] && info[:block_time] < @mb.today - @mb.config[user_type][:block_offset] && info[:indefinite]
        puts user_name + ' - is blocked'
        @removed_users[:indefinitely_blocked] << user_name
      elsif info[:last_edit] && info[:last_edit] < @mb.today - @mb.config[user_type][:edit_offset]
        notified_users = (@disk_cache['notified_users'] || {})

        if notified_users[user_name].present? && @mb.parse_date(notified_users[user_name]) <= @mb.today - 7
          puts user_name + ' - is inactive'
          @removed_users[:inactive] << user_name
        elsif notified_users[user_name].blank?
          puts user_name + ' - Notifying that access may be revoked'
          @notified_users[user_name] = @mb.today
          notify_inactive_user(user_name) if @mb.config[user_type][:enabled]
          new_users << user_name.force_encoding('utf-8')
        end
      else
        new_users << user_name.force_encoding('utf-8')
      end
    end

    new_users.sort_by(&:downcase)
  end

  def self.user_info(user_name, throttle = 0)
    api_obj = @mb.gateway.custom_query(
      list: 'users|usercontribs',
      uclimit: '1',
      ucprop: 'timestamp',
      ucuser: user_name,
      usprop: 'groups|blockinfo',
      ususers: user_name
    )

    users_hash = api_obj.elements['users'][0]
    contribs = api_obj.elements['usercontribs'][0]
    last_edit = contribs ? contribs.attributes['timestamp'] : nil

    {
      block_time: @mb.parse_date(users_hash.attributes['blockedtimestamp']),
      indefinite: users_hash.attributes['blockexpiry'] == 'infinity',
      last_edit: @mb.parse_date(last_edit),
      user_groups: users_hash.elements['groups'].to_a.collect { |g| g[0].to_s }
    }
  rescue => e
    if throttle > 3
      @mb.report_error('Throttle hit', e)
    else
      user_info(user_name, throttle + 1)
    end
  end

  def self.moved_user_info(user_name)
    log_entry = meta_repl.query(
      "SELECT log_timestamp, log_params FROM metawiki_p.logging " \
      "WHERE log_type = 'gblrename' AND log_params LIKE '%\"#{user_name.sub("'"){ "\\'" }}\"%'"
    ).to_a.first

    # make sure there was a result and it was for the old username
    if log_entry.nil? || user_name != log_entry['log_params'].scan(/olduser";s:\d*:"(.*?)";/).flatten.first
      return nil
    end

    {
      timestamp: @mb.parse_date(log_entry['log_timestamp']),
      new_user_name: log_entry['log_params'].scan(/newuser";s:\d*:"(.*?)";/).flatten.first
    }
  end

  def self.meta_repl
    return @meta_repl if @meta_repl
    credentials = @mb.app_config[:replica]
    credentials[:host].sub!('*', 'metawiki')
    credentials[:database] = 'metawiki_p'
    @meta_repl = Repl::Session.new(credentials)
  end

  def self.edit_summary(report = false)
    summary = report ? [] : ['General cleanup']
    removed_users = []

    puts '==== BUILDING EDIT SUMMARY ===='

    if @removed_users[:admins].any?
      puts "...#{@removed_users[:admins].length} admins"
      removed_users << 'admin'.pluralize_num(@removed_users[:admins].length)
    end
    if @removed_users[:indefinitely_blocked].any?
      puts "...#{@removed_users[:indefinitely_blocked].length} indefinitely blocked"
      removed_users << 'indefinitely blocked user'.pluralize_num(@removed_users[:indefinitely_blocked].length)
    end
    if @removed_users[:inactive].any?
      puts "...#{@removed_users[:inactive].length} inactive"
      removed_users << 'inactive user'.pluralize_num(@removed_users[:inactive].length)
    end

    # we've removed users
    summary << "#{report ? 'reporting' : 'removed'} #{removed_users.join(', ')}" if removed_users.any?

    if @renamed_users.any?
      summary << 'user'.pluralize(@renamed_users.length) + ' renamed'
    end

    summary.join(', ')
  end

  def self.report_page(user_type)
    markup = ''
    total = 0

    [:admins, :indefinitely_blocked, :inactive].each do |section|
      title = section.to_s.tr('_', ' ').capitalize_first
      if [:indefinitely_blocked, :inactive].include?(section)
        key = section == :inactive ? :edit_offset : :block_offset
        title += " for #{@mb.config[user_type][key]} days"
      end

      # subtract @current_users to remove any in the old report that have been re-added
      old_report = (@old_report[user_type.to_s] || {})[section.to_s] || []
      removed_users = (@removed_users[section] + old_report) - @new_users[user_type]
      removed_users.sort!.uniq!

      # update local report cache
      @new_report[user_type.to_s] ||= {}
      @new_report[user_type.to_s][section.to_s] = removed_users

      markup += "\n=== #{title} ===\n"
      markup += "#{removed_users.length} total\n"
      markup += removed_users.map { |username| "* {{no ping|#{username}}}\n" }.join
      total += removed_users.length
    end

    checkpage = '[[Wikipedia:AutoWikiBrowser/CheckPageJSON|CheckPage]]'
    preface = if @mb.config[user_type][:enabled]
                "#{total} #{user_type}s have been automatically removed from the #{checkpage}. If they are re-added, they will automatically be removed from this report.\n"
              else
                "#{total} #{user_type}s potentially eligible to be removed from the #{checkpage}.{{pb}}" \
                "'''These users have not been automatically removed from the CheckPage'''. To enable this feature, set <code>enable</code> to " \
                "<code>true</code> in the <code>#{user_type}</code> hash of the [[User:MusikBot II/AWBListMan/config|config]].\n"
              end

    preface + markup
  end

  def self.notify_inactive_user(user_name)
    message = "Hello '''#{user_name}'''! This message is to inform you that due to editing inactivity, your access to " \
      "[[Wikipedia:AutoWikiBrowser|AutoWikiBrowser]] may be temporarily removed. If you do not resume editing within " \
      "the next week, your username will be removed from the [[Wikipedia:AutoWikiBrowser/CheckPageJSON|CheckPage]]. " \
      "This is purely for routine maintenance and is not indicative of wrongdoing on your part. " \
      "You may regain access at any time by simply requesting it at [[WP:PERM/AWB]]. Thank you! ~~~~"

    @mb.edit("User talk:#{user_name}",
      content: message,
      section: 'new',
      sectiontitle: 'Your access to AWB may be temporarily removed',
      summary: "Notification that access to [[WP:AWB|AutoWikiBrowser]] may be temporarily removed due to inactivity",
      redirect: true
    )
  end
end

AWBListMan.run
