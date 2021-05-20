$LOAD_PATH << '..'
require 'musikbot'

module AWBListMan
  AWB_CHECKPAGE = 'Wikipedia:AutoWikiBrowser/CheckPage'.freeze
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

    all_new_users = []

    [:bot, :user].each do |user_type|
      config = @mb.config[user_type]
      users = @mb.get(AWB_CHECKPAGE, rvsection: config[:section]).split("\n")
      @removed_users = {
        admins: [],
        indefinitely_blocked: [],
        inactive: []
      }
      @renamed_users = []
      @current_users = []
      @new_users, section_text = process_users(users, user_type)

      next unless @new_users.present?

      # which list of users to go off of based on whether we're editing that section on the AWB CheckPage
      #   or just making a report of those who would be revoked if we were editing the page
      users_list = config[:enabled] ? @new_users : @current_users

      all_new_users += users_list

      user_type_str = user_type.to_s.capitalize_first

      if config[:enabled]
        @mb.edit(AWB_CHECKPAGE,
          content: section_text,
          section: config[:section],
          summary: "#{user_type_str}s: #{edit_summary}"
        )
      end

      @mb.edit("#{REPORT_PAGE}/#{user_type_str}",
        content: report_page(user_type),
        summary: "#{user_type_str}s: #{edit_summary(true)}"
      )

      @mb.edit(REPORT_PAGE,
        content: "<div style='font-size:24px'>AWB CheckPage report as of #{@mb.today} <sup>({{purge}})</sup></div>",
        section: 0,
        summary: 'Updating heading of report page'
      )

      @mb.edit("User:MusikBot II/AWBListMan/#{user_type_str} count",
        content: users_list.length,
        summary: "Reporting #{user_type.to_s.pluralize_num(users_list.length)} with AWB access"
      )
    end

    @mb.local_storage(
      'last_run' => @mb.now.to_s,
      'enabled_users' => all_new_users.uniq,
      'report' => @new_report,
      'notified_users' => @notified_users
    )
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.process_users(list, user_type)
    new_users = []
    before_lines = []
    after_lines = []

    list.each do |line|
      user_name = line.scan(/^\*\s*(.*?)\s*$/).flatten.first

      if user_name
        @current_users << user_name
      elsif @current_users.any? # hit the end of the list
        after_lines << line
      else # before the list
        before_lines << line
      end
    end

    @current_users.uniq!
    @current_users.sort!.each do |user_name|
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
          new_users << user_name
        end
      else
        new_users << user_name
      end
    end

    # alphabetize
    new_users.sort!

    new_users_text = "\n" + new_users.map { |user| "* #{user.force_encoding('utf-8')}\n" }.join
    new_text = before_lines.join("\n") + new_users_text + after_lines.join("\n")
    [new_users, new_text]
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
      @mb.report_error('Edit throttle hit', e)
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
    credentials[:host].sub!('*', 'metawiki_p')
    @meta_repl = Repl::Session.new({
      database: 'metawiki_p',
      host: @mb.app_config[:replica]
    })
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

    summary.join('; ')
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
      removed_users = (@removed_users[section] + old_report) - @new_users
      removed_users.sort!.uniq!

      # update local report cache
      @new_report[user_type.to_s] ||= {}
      @new_report[user_type.to_s][section.to_s] = removed_users

      markup += "\n=== #{title} ===\n"
      markup += "#{removed_users.length} total\n"
      markup += removed_users.map { |username| "* {{no ping|#{username}}}\n" }.join
      total += removed_users.length
    end

    checkpage = '[[Wikipedia:AutoWikiBrowser/CheckPage|CheckPage]]'
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
      "the next week, your username will be removed from the [[Wikipedia:AutoWikiBrowser/CheckPage|CheckPage]]. " \
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
