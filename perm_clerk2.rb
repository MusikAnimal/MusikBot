$LOAD_PATH << '.'
require 'musikbot'

module PermClerk
  COMMENT_INDENT = "\n::"
  AWB_COMMENT_INDENT = "\n*:"
  COMMENT_PREFIX = '{{comment|Automated comment}} '
  EDIT_THROTTLE = 3
  SPLIT_KEY = '====[[User:'
  AWB_SPLIT_KEY = '*{{AWBUser|'

  def self.run
    @mb = MusikBot::Session.new(inspect)

    @denied_cache = {}
    @user_info_cache = {}
    @user_links_cache = {}
    @archive_changes = {}
    @errors = {}
    @total_user_count = 0

    permissions.each do |permission|
      @permission = permission
      @edit_throttle = 0
      @edit_summaries = []
      @headers_removed = {}
      @users_count = 0

      begin
        process(permission)
        @run_status[permission] = @mb.now.to_s
        @total_user_count += @users_count
      rescue => e
        @mb.report_error("Failed to process #{permission}", e)
      end
    end

    run_file = File.open('lastrun', 'r+')
    run_file.write(run_status.inspect)
    run_file.close
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.process
    info("Processing #{@permission}...")
    @split_key = @permission == 'AWB' ? AWB_SPLIT_KEY : SPLIT_KEY
    page_name = @permission == 'AWB' ? 'Wikipedia talk:AutoWikiBrowser/CheckPage' : "Wikipedia:Requests for permissions/#{@permission}"

    old_wikitext = page_props(page_name)
    return unless formatting_check(old_wikitext)

    last_run = parse_date_time(@run_status[@permission]) rescue DateTime.new

    if prereqs # if prereqs enabled for this permission
      has_prereq_data = old_wikitext.match(/\<!-- mb-\w*(?:Count|Age) --\>/)
      should_check_prereq_data = config['prerequisites'] ? has_prereq_data.present? : false
    else
      should_check_prereq_data = false
    end

    # only process if there's data to update or the page has changed since the last run
    if !should_check_prereq_data && last_run > @last_edit
      return info('  Less than 90 minutes since last run without changes, and no prerequisites to update')
    end

    if config['autoformat']
      debug('Checking for extraneous headers')
      old_wikitext = remove_headers(old_wikitext)
    end

    # first make fixes to confirm to what split_key looks for
    old_wikitext.gsub!(/\*\s+{{AWBUser\|/, '*{{AWBUser|')
    old_wikitext.gsub(/\=\=\=\=\s+\[\[User:/, '====[[User:')

    @new_wikitext = []
    sections = old_wikitext.split(@split_key)
    @new_wikitext << sections.shift

    @num_open_requests = 0

    sections.each do |section|
      @new_wikitext << process_section(section)
    end

    archive_requests if @archive_changes.length
    generate_report

    info("#{'~' * 25} Task complete #{'~' * 25}")
  end

  def self.process_section(section)
    @section = section
    @bot_section = ''
    if @permission == 'AWB'
      bot_split = @section.split(/====\s*Bots/i)
      @section = bot_split[0]
      @bot_section = '==== Bots' + bot_split[1] if bot_split[1]
    end

    @request_changes = []

    if @permission == 'AWB'
      username = @section.scan(/^(.*?)}}/).flatten[0]
    else
      username = @section.scan(/{{(?:template\:)?rfplinks\|1=(.*?)}}/i).flatten[0]
    end

    if !username || username == 'username' || username == 'bot username'
      return @split_key + @section + @bot_section
    end

    @username = username.first.capitalize.gsub('_', ' ')

    info("Checking section for User:#{@username}...")

    timestamps = @section.scan(/(?<!\<!-- mbdate --\> )\d\d:\d\d.*\d{4} \(UTC\)/)
    @newest_timestamp = timestamps.min { |a, b| parse_date_time(b) <=> parse_date_time(a) }
    if overriden_resolution = @section.match(/\{\{User:MusikBot\/override\|d\}\}/i) ? 'done' : @section.match(/\{\{User:MusikBot\/override\|nd\}\}/i) ? 'notdone' : false
      info('  Resolution override found')
    end
    resolution = overriden_resolution || (@section.match(/(?:#{config["regex_done"]})/i) ? 'done' : @section.match(/(?:#{config["regex_notdone"]})/i) ? 'notdone' : false)
    resolution_timestamp = Date.parse(@section.scan(/(?:#{config["regex_#{resolution}"]}).*(\d\d:\d\d, \d+ \w+ \d{4} \(UTC\))/i).flatten.drop(1).last) rescue nil

    # use newest timestamp when forcing resolution and no resolution template exists
    if resolution_timestamp.nil? && overriden_resolution
      resolution_timestamp = Date.parse(@newest_timestamp)
    end

    @num_open_requests += 1 unless resolution

    @should_update_prereq_data = should_update_prereq_data

    # archiving has precedence; e.g. if we are archiving, we don't do anything else for this section
    next unless archiving(resolution, overriden_resolution, resolution_timestamp)

    # determine if there's any else to be done
    if resolution
      info("  #{@username}'s request already responded to")
      @new_wikitext << @split_key + @section + @bot_section and next
    elsif @section.match(/{{comment|Automated comment}}.*MusikBot/) && !should_update_prereq_data
      info("  MusikBot has already commented on #{username}'s request and no prerequisite data to update")
      @new_wikitext << @split_key + @section + @bot_section and next
    end

    # these tasks have already been ran if we're just updating prereq data
    unless @should_update_prereq_data
      autorespond
      autoformat
      fetch_declined
    end
    prerequisites

    queue_changes

    edit_permission_page(CGI.unescapeHTML(@new_wikitext.join))
  end

  # Core tasks
  def self.fetch_declined
    return unless config['fetch_declined']
  end

  def self.autorespond
    # only runs for Confirmed and AWB
    return unless config['autorespond'] && %w(Confirmed AWB).include?(@permission) && !has_permission?(@username)
    info("    User has permission #{@permission}")

    @request_changes << {
      type: :autorespond,
      permission: @permission.downcase,
      resolution: '{{already done}}',
      sysop: get_user_info[:userGroups].include?('sysop')
    }
    @num_open_requests -= 1
    @edit_summaries << :autorespond
  end

  def self.autoformat
    return unless config['autoformat'] && @permission != 'AWB'

    fragmented_regex = /{{rfplinks.*}}\n:(Reason for requesting (?:#{@PERMISSIONS.join("|").downcase}) rights) .*\(UTC\)(?m:(.*?)(?:\n\=\=|\z))/
    fragmented_match = @section.scan(fragmented_regex)

    return unless fragmented_match.length > 0

    if @headers_removed[@username] && @headers_removed[@username].length > 0
      @request_changes << { type: :autoformat }
      @edit_summaries << :autoformat
      return
    end

    info("    Found improperly formatted request for #{@username}, repairing")

    actual_reason = fragmented_match.flatten[1]
    if actual_reason.length == 0 && @headers_removed[@username]
      actual_reason = @headers_removed[@username]
    else
      @section.gsub!(actual_reason, '')
      loop do
        frag_match = section.match(fragmented_regex)
        if frag_match && frag_match[2] != '' && !(frag_match[2].include?('UTC') && !frag_match[2].include?(@username))
          reason_part = frag_match[2]
          actual_reason += "\n:#{reason_part}"
          @section.gsub!(reason_part, '')
        else
          break
        end
      end
    end

    @section.gsub!(fragmented_match.flatten[0], actual_reason.gsub(/^\n+/, '').gsub(/\n+$/, ''))

    duplicate_sig = @section.scan(/.*\(UTC\)(.*\(UTC\))/)
    if duplicate_sig.length > 0
      info('    Duplicate signature found, repairing')
      sig = duplicate_sig.flatten[0]
      @section = @section.sub(sig, '')
    end

    @request_changes << { type: :autoformat }
    @edit_summaries << :autoformat
  end

  def self.prerequisites
    return unless config['prerequisites'] && !@prereqs.empty? && @permission != 'Confirmed' && !@username.downcase.match(/bot$/)
    debug("  Checking if #{username} meets configured prerequisites...")

    updating_prereq = @section.match(/\<!-- mb-\w*(?:Count|Age) --\>/)

    user_info = get_user_info(@username, prereqs.keys)

    prereqs.each do |key, value|
      pass = user_info[key.to_sym] >= value rescue nil
      next if pass.nil? && user_info && user_info[:editCount] > 50_000

      if pass.nil?
        record_error(
          group: 'prerequisites',
          message: "Failed to fetch data <tt>#{key}</tt> for User:#{@username}",
          log_message: "      failed to fetch prerequisite data: #{key}"
        )
      elsif pass
        info('      User meets criteria')
      elsif updating_prereq
        prereq_count_regex = @section.scan(/(\<!-- mb-#{key} --\>(.*)\<!-- mb-#{key}-end --\>)/)
        prereq_text = prereq_count_regex.flatten[0]
        prereq_count = prereq_count_regex.flatten[1].to_i rescue 0

        if !user_info[key.to_sym].nil? && user_info[key.to_sym].to_i > prereq_count && prereq_count > 0
          @section.gsub!(prereq_text, "<!-- mb-#{key} -->#{user_info[key.to_sym].to_i}<!-- mb-#{key}-end -->")
          @section.gsub!(prereq_signature, '~~~~')

          info('    Prerequisite data updated')
          @request_changes << { type: :prerequisitesUpdated }
          @edit_summaries << :prerequisitesUpdated
        else
          debug('      Update not needed')
        end
      elsif !pass
        info("      Found unmet prerequisite: #{key}")
        @request_changes << { type: key }.merge(user_info)
        @edit_summaries << :prerequisites
      end
    end
  end

  def self.archiving(resolution, overriden_resolution, resolution_timestamp)
    return true unless config['archive']
    should_archive_now = @section.match(/\{\{User:MusikBot\/archivenow\}\}/)

    if resolution && @config['archive'] && resolution_timestamp.nil?
      record_error(
        group: 'archive',
        message: "User:#{@username} - Resolution template not dated",
        log_message: "    User:#{@username}: Resolution template not dated"
      ) and return false
    end

    return false unless resolution && (should_archive_now || parse_date_time(@newest_timestamp) + Rational(config['archive_offset'], 24) < @mb.now)

    if should_archive_now
      info('  Found request for immediate archiving')
    else
      info('  Time to archive!')
    end

    # if we're archiving as done, check if they have the said permission and act accordingly (skip if overriding resolution)
    if resolution == 'done' && !overriden_resolution
      if @section.include?('><!-- mbNoPerm -->')
        # unless has_permission?
        warn("    MusikBot already reported that #{@username} does not have the permission #{@permission}")
        @new_wikitext << @split_key + @section and return false
        # end
      elsif !has_permission?
        @request_changes << {
          type: :noSaidPermission,
          permission: @permission.downcase
        }
        @edit_summaries << :noSaidPermission

        queue_changes

        if @permission == 'AWB'
          message = 'has not been added to the [[Wikipedia:AutoWikiBrowser/CheckPage|check page]]'
        else
          message = "does not have the permission #{@permission}"
        end

        record_error(
          group: 'archive',
          message: "User:#{@username} #{message}. " \
            'Use <code><nowiki>{{subst:User:MusikBot/override|d}}</nowiki></code> to archive as approved or ' \
            '<code><nowiki>{{subst:User:MusikBot/override|nd}}</nowiki></code> to archive as declined',
          log_message: "    #{@username} #{message}"
        ) and return false
      end
    end

    resolution_page_name = resolution == 'done' ? 'Approved' : 'Denied'
    info("    archiving as #{resolution_page_name.upcase}")
    archive_key = "#{resolution_page_name}/#{Date::MONTHNAMES[resolution_timestamp.month]} #{resolution_timestamp.year}"
    archive_set = @archive_changes[archive_key].to_a << {
      username: @username,
      permission: @permission,
      revision_id: @revision_id,
      date: resolution_timestamp
    }
    @archive_changes[archive_key] = archive_set

    @users_count += 1
    @edit_summaries << "archive#{resolution_page_name}".to_sym

    @new_wikitext << @bot_section

    true
  end

  # Extensions to tasks
  def self.queue_changes
    if @request_changes.length > 0
      info('***** Commentable data found *****')
      @users_count += 1

      @new_section = @split_key + @section.gsub(/\n+$/, '')

      if @request_changes.index { |obj| obj[:type] == :prerequisitesUpdated }
        @new_section += "\n"
      else
        @new_section += message_compiler(@request_changes)
      end
      @new_wikitext << @new_section + @bot_section
    else
      info('  ~~ No commentable data found ~~')
      @new_wikitext << @split_key + @section + @bot_section
    end
  end

  def self.archive_requests
    num_requests = @archive_changes.values.flatten.length

    info("***** Archiving #{num_requests} requests *****")

    @archive_changes.keys.each do |key|
      page_to_edit = "Wikipedia:Requests for permissions/#{key}"
      month_name = key.scan(/\/(\w+)/).flatten[0]
      year = key.scan(/\d{4}/).flatten[0]

      unless page_wikitext = @mb.get(page_to_edit)
        record_error(
          group: 'archive',
          message: "Unable to fetch archive page for #{key}. Some requests may not have been saved to archives.",
          log_message: "  unable to fetch archive page for #{key}, aborting",
          error_set: 'Fatal'
        ) and return false
      end

      new_page = page_wikitext.empty?

      edit_summary = "Archiving #{@archive_changes[key].length} request#{'s' if @archive_changes[key].length > 1}:"

      # ensure there's a newline at the end
      page_wikitext = page_wikitext.chomp('') + "\n"

      # convert sections as a hash of format {"Month day" => "content"}
      sections = Hash[*page_wikitext.split(/\=\=\s*(\w+ \d+)\s*\=\=/).drop(1).flatten(1)]

      @archive_changes[key].each do |request|
        edit_summary += " #{request[:username]} (#{request[:permission].downcase});"
        archive_page_name = request[:permission] == 'AWB' ? 'Wikipedia talk:AutoWikiBrowser/CheckPage' : "Wikipedia:Requests for permissions/#{request[:permission]}"
        link_markup = "*{{Usercheck-short|#{request[:username]}}} [[#{archive_page_name}]] " \
          "<sup>[http://en.wikipedia.org/wiki/Special:PermaLink/#{request[:revision_id]}#User:#{request[:username].gsub(' ', '_')} link]</sup>"

        # add link_markup to section
        section_key = "#{month_name} #{request[:date].day}"
        sections[section_key] = sections[section_key].to_s.gsub(/^\n|\n$/, '') + "\n" + link_markup + "\n"
      end
      edit_summary.chomp!(';')

      # construct back to single wikitext string, sorted by day
      new_wikitext = ''
      sorted_keys = sections.keys.sort_by { |k| k.scan(/\d+/)[0].to_i }
      sorted_keys.each do |sortKey|
        new_wikitext += "\n== " + sortKey + " ==\n" + sections[sortKey].gsub(/^\n/, '')
      end

      # we're done archiving for this month

      # first see if it's a new page and if so add it to the log page
      if new_page
        log_page_name = "Wikipedia:Requests for permissions/#{key.scan(/(.*)\//).flatten[0]}"
        info("  Adding new page [[#{page_to_edit}]] to log [[#{log_page_name}]]")

        unless log_page = @mb.get(log_page_name)
          record_error(
            group: 'archive',
            message: "Unable to fetch log page [[#{log_page_name}]], archiving aborted",
            log_message: "  unable to fetch log page [[#{log_page_name}]], aborting",
            error_set: 'Fatal'
          ) and return false
        end

        # convert to {"year" => "requests"}
        year_sections = Hash[*log_page.split(/\=\=\=\s*(\d{4})\s*\=\=\=/).drop(1)]
        year_sections[year] = "\n*[[#{page_to_edit}]]" + year_sections[year].to_s

        log_page_wikitext = ''
        year_sections.sort { |a, b| b <=> a }.to_h.keys.each do |yearSectionKey|
          log_page_wikitext += "\n=== " + yearSectionKey + " ===\n" + year_sections[yearSectionKey].gsub(/^\n/, '')
        end

        info("    Attempting to write to page [[#{log_page_name}]]")
        log_page_wikitext = log_page.split('===')[0] + log_page_wikitext

        return false unless @mb.edit(log_page_name,
          content: log_page_wikitext,
          summary: "Adding entry for [[#{page_to_edit}]]"
        )
      end

      info("  Attempting to write to page [[#{page_to_edit}]]")
      return false unless @mb.edt(page_to_edit,
        content: new_wikitext,
        summary: edit_summary
      )
    end
  end

  def self.generate_report
    errors_digest = Digest::MD5.hexdigest(@errors.values.join)
    return unless @run_status['report_errors'] != errors_digest || parse_date_time(@run_status['report']) < @mb.now - Rational(6, 24)

    if @errors.keys.length > 0
      num_errors = @errors.values.flatten.length
      content = '{{hidden|style=display:inline-block;background:transparent|headerstyle=padding-right:3.5em|header=' \
        "<span style='color:red;font-weight:bold'>#{num_errors} error#{'s' if num_errors > 1} as of ~~~~~</span>|content="
      @errors.keys.each do |permissionGroup|
        content += "\n;[[Wikipedia:Requests for permissions/#{permissionGroup}|#{permissionGroup}]]\n"
        @errors[permissionGroup].each do |error|
          content += "* '''#{error[:group].capitalize}''': #{error[:message]}\n"
        end
      end
      content += '}}'
    else
      content = "<span style='color:green; font-weight:bold'>No errors!</span> Report generated at ~~~~~"
    end

    info('Updating report...')
    edit_page('User:MusikBot/PermClerk/Report',
      content: content,
      summary: 'Updating [[User:MusikBot/PermClerk|PermClerk]] report'
    )
  end

  # Helpers
  def self.should_update_prereq_data
    if @section.scan(/\<!-- mb-/).length > 0
      prereq_sig_regex = @section.scan(/(\<!-- mbsig --\>.*\<!-- mbdate --\> (\d\d:\d\d.*\d{4} \(UTC\)))/)
      @prereq_signature = prereq_sig_regex.flatten[0]
      @prereq_timestamp = prereq_sig_regex.flatten[1]
      if @mb.now > parse_date_time(prereq_timestamp) + Rational(config['prereq_exipry'], 1440)
        debug('  Found expired prerequisite data')
        return true
      else
        debug("  Prerequisite data under #{config['prereq_exipry']} minutes old")
      end
    end
    false
  end

  def self.formatting_check(old_wikitext)
    ret = true

    split_key_match = old_wikitext.scan(/\n(.*)[^\n]#{Regexp.escape(@split_key)}(.*)\n/).flatten
    if split_key_match.length > 0
      error("A request heading is not on its own line: #{split_key_match[0]}")
      @errors[@permission] = @errors[@permission].to_a << {
        group: 'formatting',
        message: "Unable to process page! A request heading is not on its own line:\n*:" \
          "<code style='color:red'><nowiki>#{split_key_match[0]}</nowiki></code><code><nowiki>#{@split_key}#{split_key_match[1]}</nowiki></code>"
      }
      ret = false
    end

    ret
  end

  def self.remove_headers(old_wikitext)
    return old_wikitext if @permission != 'AWB'

    headers_match = old_wikitext.scan(/(^\=\=[^\=]*\=\=([^\=]*)(\=\=\=\=[^\=]*\=\=\=\=\n\*.*rfplinks\|1=(.*)\}\}\n))/)

    if headers_match.length > 0
      info('Extraneous headers detected')

      headers_match.each do |match|
        next unless name = match[3]

        original_markup = match[0]
        level_two_text = match[1].gsub("\n", '')
        rfp_links_part = match[2]

        old_wikitext.sub!(original_markup, rfp_links_part)
        header_text = original_markup.scan(/\=\=\s*([^\=]*)\s*\=\=/)[0][0]
        if level_two_text.length > header_text.length
          @headers_removed[name] = level_two_text.gsub(/^\n*/, '').gsub(/\n$/, '')
        else
          @headers_removed[name] = header_text
        end
      end
    end

    old_wikitext
  end

  # Config-related
  def self.config
    return @config if @config

    pages_to_fetch = [
      'Archive/Run', 'Archive/Offset', 'Autoformat/Run', 'Autorespond/Run',
      'FetchDeclined/Run', 'FetchDeclined/Offset',
      'Prerequisites/Run', 'Prerequisites/config.js',
      'Regex/Done', 'Regex/Notdone'
    ].map { |p| "User:MusikBot/PermClerk/#{p}" }.join('|')

    config_pages = mw.custom_query(prop: 'revisions', titles: pages_to_fetch, rvprop: 'content')[0]

    @config = {}
    config_pages.each do |config_page|
      config_name = config_page.attributes['title'].gsub(%r{User\:MusikBot/PermClerk/?}, '').gsub('/', '_').downcase.chomp('_run').chomp('.js')

      if %w(fetchdeclined_offset archive_offset).include?(config_name)
        @config[config_name] = config_page.elements['revisions'][0][0].to_s.to_i
      elsif config_name == 'prerequisites_config'
        @config[config_name] = JSON.parse(CGI.unescapeHTML(config_page.elements['revisions'][0][0].to_s))
      elsif config_name =~ /^regex_/
        @config[config_name] = config_page.elements['revisions'][0][0].to_s
      else
        @config[config_name] = config_page.elements['revisions'][0][0].to_s == 'true'
      end
    end

    @config['prereq_expiry'] = @mb.env == :production ? 90 : 0

    @config
  end

  def self.run_status
    @run_status ||= eval(File.open('lastrun', 'r').read) rescue {}
  end

  def self.permissions
    {
      'Account creator' => 'accountcreator',
      'Autopatrolled' => 'autoreviewer',
      'AWB' => 'awb',
      'Confirmed' => '(?=>auto)?confirmed',
      'File mover' => 'filemover',
      'Mass message sender' => 'massmessage-sender',
      'Pending changes reviewer' => 'reviewer',
      'Rollback' => 'rollbacker',
      'Template editor' => 'templateeditor'
    }
  end

  def self.prereqs
    config['prerequisites'] ? config['prerequisites_config'][@permission.downcase.gsub(/ /, '_')] : nil
  end

  # Utility
  def self.parse_date_time(datetime)
    DateTime.parse(datetime).new_offset(0)
  end

  # API-related
  def self.has_permission?
    if @permission == 'AWB'
      @mb.get('Wikipedia:AutoWikiBrowser/CheckPage') =~ /\n\*\s*#{@username}/ || get_user_info[:userGroups].include?('sysop')
    else
      get_user_info[:userGroups].grep(/#{PERMISSION_KEYS[@permission]}/).length > 0 || get_user_info[:userGroups].include?('sysop')
    end
  end

  def self.get_user_info(username, *data_attrs)
    data_attrs = data_attrs.flatten

    # return cache if there's nothing new to fetch
    if @user_info_cache[username] && data_attrs.all? { |da| @user_info_cache[username].keys.include?(da) }
      debug("  cache hit for #{username}")
      return @user_info_cache[username]
    end

    data_fetch_str = data_attrs.join(', ')
    debug("    Fetching data for: #{data_fetch_str.length > 0 ? data_fetch_str : 'basic info'}")

    # get basic info if we haven't already and query the repl database as needed for other info
    unless @user_info_cache[username] && @user_info_cache[username][:editCount]
      api_query = api_user_info(username)
      api_info = api_query[0][0].attributes
      registration_date = api_info['registration'] ? Date.parse(api_info['registration']) : nil

      @user_info_cache[username] = {
        accountAge: registration_date ? (Date.today - registration_date).to_i : 0,
        editCount: api_info['editcount'].to_i,
        registration: registration_date,
        userGroups: api_query[0][0][0].to_a.collect { |g| g[0].to_s },
        username: username
      }
    end

    # FIXME: more of this method missing...
  end

  def self.page_props(page)
    page_obj = @mb.get_page_props(page, full_response: true)
    @revision_id = page_obj.attributes['lastrevid']
    page_obj.elements['revisions'][0][0].to_s
  end
end

PermClerk.run
