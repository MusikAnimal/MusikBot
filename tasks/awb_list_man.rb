$LOAD_PATH << '..'
require 'musikbot'
require 'nokogiri'
require 'uri'

module AWBListMan
  AWB_CHECKPAGE = 'User:MusikBot/AWBListMan/CheckPage'.freeze
  REPORT_PAGE = 'User:MusikBot/AWBListMan/Report'.freeze

  def self.run
    @mb = MusikBot::Session.new(inspect)

    disk_cache = @mb.local_storage
    @old_users = disk_cache['users'] || []
    @last_run = @mb.parse_date(disk_cache['last_run'])

    all_new_users = []

    %w(bot user).each do |user_type|
      config = @mb.config[user_type]
      users = @mb.get(AWB_CHECKPAGE, rvsection: config['section']).split("\n")
      @removed_users = {
        admins: [],
        indefinitely_blocked: [],
        inactive: [],
        renamed: []
      }
      @old_users = []
      new_users, section_text = process_users(users, user_type)

      next unless new_users.present?

      # which list of users to go off of based on whether we're editing that section on the AWB CheckPage
      #   or just making a report of those who would be revoked if we were editing the page
      users_list = config['enabled'] ? new_users : @old_users

      all_new_users += users_list

      user_type_str = user_type.clone.capitalize_first

      if config['enabled']
        @mb.edit(AWB_CHECKPAGE,
          content: section_text,
          section: config['section'],
          summary: "#{user_type_str}s: #{edit_summary}"
        )
      end

      @mb.edit("#{REPORT_PAGE}/#{user_type_str}",
        content: report_page(user_type),
        summary: "#{user_type_str}s: #{edit_summary(false)}"
      )

      @mb.edit(REPORT_PAGE,
        content: "<div style='font-size:24px'>AWB CheckPage report as of #{@mb.today} <sup>({{purge}})</sup></div>",
        section: 0,
        summary: 'Updating heading of report page'
      )

      @mb.edit("User:MusikBot/AWBListMan/#{user_type_str} count",
        content: users_list.length,
        summary: "Reporting #{pluralize_num(user_type, users_list.length)} with AWB access"
      )
    end

    @mb.local_storage(
      'users' => all_new_users,
      'last_run' => @mb.now.to_s
    )
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.process_users(list, user_type)
    user_names = []
    before_lines = []
    after_lines = []

    list.each do |line|
      user_name = line.scan(/^\*\s*(.*?)\s*$/).first

      if user_name
        @old_users << user_name.first
      elsif user_names.any? # hit the end of the list
        after_lines << line
      else # before the list
        before_lines << line
      end
    end

    new_list = []
    @old_users.uniq.sort.each do |user_name|
      # moved_info = moved_user_info(user_name)

      # if moved_info && moved_info[:timestamp] > @last_run && @old_users.include?(user_name)
      #   @renamed << new_user_name
      #   user_name = new_user_name
      # end

      info = user_info(user_name)

      if info[:user_groups].include?('sysop')
        puts user_name + ' is sysop'
        @removed_users[:admins] << user_name
      elsif info[:block_time] && info[:block_time] < @mb.today - @mb.config[user_type]['block_offset'] && info[:indefinite]
        puts user_name + ' is blocked'
        @removed_users[:indefinitely_blocked] << user_name
      elsif info[:last_edit] && info[:last_edit] < @mb.today - @mb.config[user_type]['edit_offset']
        puts user_name + ' is inactive'
        @removed_users[:inactive] << user_name
      else
        puts user_name
        new_list << user_name
      end
    end

    # alphabetize
    new_list.sort!
    @old_users.sort!.uniq!

    new_list_text = "\n" + new_list.map { |user| "* #{user}\n" }.join
    new_text = before_lines.join("\n") + new_list_text + after_lines.join("\n")
    [new_list, new_text]
  end

  def self.user_info(user_name)
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
  end

  # FIXME: needs to use global rename log on meta
  def self.moved_user_info(user_name)
    events = @mb.gateway.custom_query(
      list: 'logevents',
      letype: 'move',
      leprop: 'timestamp|comment|details',
      letitle: "User:#{user_name}"
    ).elements['logevents']

    events.each do |event|
      new_user_name = event.attributes['comment'].scan(
        /renaming the user ".*?" to "\[\[Special:CentralAuth\/(.*?)\|/
      ).flatten.first

      if new_user_name
        return {
          user_name: new_user_name,
          timestamp: @mb.parse_date(event.attributes['timestamp'])
        }
      end
    end

    nil
  end

  def self.edit_summary(report = false)
    summary = report ? [] : ['General cleanup']
    removed_users = []

    if @removed_users[:admins].any?
      removed_users << pluralize_num('admin', @removed_users[:admins].length)
    end
    if @removed_users[:indefinitely_blocked].any?
      removed_users << pluralize_num('indefinitely blocked user', @removed_users[:indefinitely_blocked].length)
    end
    if @removed_users[:inactive].any?
      removed_users << pluralize_num('inactive user', @removed_users[:inactive].length)
    end

    # we've removed users
    summary << "#{report ? 'reporting' : 'removed'} #{removed_users.join(', ')}" if removed_users.any?

    if @removed_users[:renamed].any?
      summary << pluralize('user', @removed_users[:renamed].length) + ' renamed'
    end

    summary.join('; ')
  end

  def self.report_page(user_type)
    markup = ''
    total = 0

    [:admins, :renamed, :indefinitely_blocked, :inactive].each do |section|
      title = section.to_s.tr('_', ' ').capitalize_first
      if [:indefinitely_blocked, :inactive].include?(section)
        key = section == :inactive ? 'edit_offset' : 'block_offset'
        title += " for #{@mb.config[user_type][key]} days"
      end
      markup += "\n=== #{title} ===\n"
      markup += "#{@removed_users[section].length} total\n"
      markup += @removed_users[section].map { |username| "* {{no ping|#{username}}}\n" }.join
      total += @removed_users[section].length
    end

    checkpage = '[[Wikipedia:AutoWikiBrowser/CheckPage|CheckPage]]'
    preface = if @mb.config[user_type]['enabled']
                "#{total} #{user_type}s have been automatically removed from the #{checkpage}. If they are re-added, they will automatically be removed from this report.\n"
              else
                "#{total} #{user_type}s potentially eligible to be removed from the #{checkpage}.{{pb}}" \
                "'''These users have not been automatically removed from the CheckPage'''. To enable this feature, set <code>enable</code> to " \
                "<code>true</code> in the <code>#{user_type}</code> hash of the [[User:MusikBot/AWBListMan/config|config]].\n"
              end

    preface + markup
  end

  def self.pluralize(string, count)
    "#{string}#{count > 1 ? 's' : ''}"
  end

  def self.pluralize_num(string, count)
    "#{count} #{pluralize(string, count)}"
  end

  def self.query(sql, *values)
    puts sql
    statement = @client.prepare(sql)
    statement.execute(*values)
  end
end

AWBListMan.run
