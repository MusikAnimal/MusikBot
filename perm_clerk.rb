module PermClerk
  require 'date'
  require 'logger'
  require 'uri'

  COMMENT_INDENT = "\n::"
  AWB_COMMENT_INDENT = "\n*:"
  COMMENT_PREFIX = '{{comment|Automated comment}} '
  EDIT_THROTTLE = 3
  SPLIT_KEY = '====[[User:'
  AWB_SPLIT_KEY = '*{{AWBUser|'

  PERMISSION_KEYS = {
    'Account creator' => 'accountcreator',
    'Autopatrolled' => 'autoreviewer',
    'Confirmed' => '(?=>auto)?confirmed',
    'File mover' => 'filemover',
    'Mass message sender' => 'massmessage-sender',
    'Pending changes reviewer' => 'reviewer',
    'Rollback' => 'rollbacker',
    'Template editor' => 'templateeditor',
    'AWB' => 'awb'
  }

  def self.init(mw, repl_client, config)
    @mw = mw
    @repl_client = repl_client
    @config = config

    @denied_cache = {}
    @user_info_cache = {}
    @user_links_cache = {}

    `stat perm_clerk.log`
    @logger = Logger.new('perm_clerk.log')
    @logger.level = Logger::DEBUG

    @run_status = eval(File.open('lastrun', 'r').read) rescue {}
    @run_file = File.open('lastrun', 'r+')

    @archive_changes = {}
    @errors = {}

    if @config[:env] == :production
      @PREREQ_EXPIRY = 90
      @PERMISSIONS = [
        'Account creator',
        'Autopatrolled',
        'AWB',
        'Confirmed',
        'File mover',
        'Mass message sender',
        'Pending changes reviewer',
        'Rollback',
        'Template editor'
      ]
    else
      @PREREQ_EXPIRY = 0
      @PERMISSIONS = ['Rollback']
    end

    start

    @run_file.write(@run_status.inspect)
    @run_file.close
  end

  def self.start
    total_user_count = 0
    for @permission in @PERMISSIONS
      sleep 2

      @base_timestamp = nil
      @perm_edit_throttle = 0
      @edit_summaries = []
      @headers_removed = {}
      @users_count = 0
      if process
        info("Processing of #{@permission} complete")
        @run_status[@permission] = current_time.to_s
        total_user_count += @users_count
      else
        error('Failed to process')
      end
    end

    @permission = ''
    archive_requests if @archive_changes.length

    report_errors

    info("#{'~' * 25} Task complete #{'~' * 25}")
  end

  def self.process
    info("Processing #{@permission}...")

    if @permission == 'AWB'
      @page_name = 'Wikipedia talk:AutoWikiBrowser/CheckPage'
    else
      @page_name = "Wikipedia:Requests for permissions/#{@permission}"
    end

    @fetch_throtte = 0
    old_wikitext = set_page_props

    return false unless old_wikitext

    @last_edit = parse_date_time(@base_timestamp)
    @last_run = parse_date_time(@run_status[@permission]) rescue DateTime.new

    prereqs = @config['prerequisites_config'][@permission.downcase.gsub(/ /, '_')]
    if @config['prerequisites'] && prereqs # if prereqs enabled for this permission
      has_prereq_data = old_wikitext.match(/&lt;!-- mb-\w*(?:Count|Age) --&gt;/)
      should_update_prereq_data = @config['prerequisites'] ? !!has_prereq_data : false
    else
      should_update_prereq_data = false
    end

    # only process if there's data to update, the page has changed since the last run or it's been 90 minutes since the last run
    if @config[:env] == :production && !should_update_prereq_data && @last_run > @last_edit && @last_run + Rational(90, 1440) > current_time
      info('  Less than 90 minutes since last run without changes, and no prerequisites to update')
      return false
    end

    new_wikitext = []

    if @config['autoformat'] && @permission != 'AWB'
      debug('Checking for extraneous headers')
      old_wikitext = remove_headers(old_wikitext)
    end

    @split_key = @permission == 'AWB' ? AWB_SPLIT_KEY : SPLIT_KEY
    @num_open_requests = 0

    return false unless formatting_check(old_wikitext)

    # first make fixes to confirm to what split_key looks for
    old_wikitext.gsub!(/\*\s+{{AWBUser\|/, '*{{AWBUser|')
    old_wikitext.gsub(/\=\=\=\=\s+\[\[User:/, '====[[User:')

    sections = old_wikitext.split(@split_key)
    new_wikitext << sections.shift

    sections.each do |section|
      bot_section = ''
      if @permission == 'AWB'
        bot_split = section.split(/====\s*Bots/i)
        section = bot_split[0]
        bot_section = '==== Bots' + bot_split[1] if bot_split[1]
      end

      request_changes = []

      if @permission == 'AWB'
        username = section.scan(/^(.*?)}}/).flatten[0]
      else
        username = section.scan(/{{(?:template\:)?rfplinks\|1=(.*?)}}/i).flatten[0]
      end

      if !username || username == 'username' || username == 'bot username'
        new_wikitext << @split_key + section + bot_section
        next
      end

      info("Checking section for User:#{username}...")

      username[0] = username[0].capitalize
      username.gsub!('_', ' ')
      # TODO: if capitalization happens, update page as part of autoformat task

      timestamps = section.scan(/(?<!&lt;!-- mbdate --&gt; )\d\d:\d\d.*\d{4} \(UTC\)/)
      newest_timestamp = timestamps.min { |a, b| parse_date_time(b) <=> parse_date_time(a) }
      if overriden_resolution = section.match(/\{\{User:MusikBot\/override\|d\}\}/i) ? 'done' : section.match(/\{\{User:MusikBot\/override\|nd\}\}/i) ? 'notdone' : false
        info('  Resolution override found')
      end
      resolution = overriden_resolution || (section.match(/#{@config["regex_done"]}/i) ? 'done' : section.match(/#{@config["regex_notdone"]}/i) ? 'notdone' : false)
      resolution_date = Date.parse(section.scan(/#{@config["regex_#{resolution}"]}.*?(\d\d:\d\d.*\d{4} \(UTC\))/i).flatten[1]) rescue nil

      # use newest timestamp when forcing resolution and no resolution template exists
      if resolution_date.nil? && overriden_resolution
        resolution_date = Date.parse(newest_timestamp)
      end

      @num_open_requests += 1 unless resolution

      if should_update_prereq_data = section.scan(/&lt;!-- mb-/).length > 0
        prereq_sig_regex = section.scan(/(&lt;!-- mbsig --&gt;.*&lt;!-- mbdate --&gt; (\d\d:\d\d.*\d{4} \(UTC\)))/)
        prereq_signature = prereq_sig_regex.flatten[0]
        prereq_timestamp = prereq_sig_regex.flatten[1]
        if should_update_prereq_data = current_time > parse_date_time(prereq_timestamp) + Rational(@PREREQ_EXPIRY, 1440) rescue false
          debug('  Found expired prerequisite data')
        else
          debug("  Prerequisite data under #{@PREREQ_EXPIRY} minutes old")
        end
      end

      should_archive_now = section.match(/\{\{User:MusikBot\/archivenow\}\}/)

      # <ARCHIVING>
      if resolution && @config['archive'] && resolution_date.nil?
        record_error(
          group: 'archive',
          message: "User:#{username} - Resolution template not dated",
          log_message: "    User:#{username}: Resolution template not dated"
        ) and next
      elsif resolution && @config['archive'] && (should_archive_now || parse_date_time(newest_timestamp) + Rational(@config['archive_offset'], 24) < current_time)
        if should_archive_now
          info('  Found request for immediate archiving')
        else
          info('  Time to archive!')
        end

        # if we're archiving as done, check if they have the said permission and act accordingly (skip if overriding resolution)
        if resolution == 'done' && !overriden_resolution
          user_info = get_user_info(username)

          # make sure they have the permission
          # TODO: actually check the checkpage to see if they've been added
          if @permission != 'AWB'
            has_permission = user_info[:userGroups].grep(/#{PERMISSION_KEYS[@permission]}/).length > 0
          end

          if section.include?('&gt;&lt;!-- mbNoPerm --&gt;')
            unless has_permission
              warn("    MusikBot already reported that #{username} does not have the permission #{@permission}")
              new_wikitext << @split_key + section
              next
            end
          elsif !has_permission && @permission != 'AWB'
            request_changes << {
              type: :noSaidPermission,
              permission: @permission.downcase
            }
            @edit_summaries << :noSaidPermission

            new_wikitext = queue_changes(request_changes, section, bot_section, new_wikitext)

            record_error(
              group: 'archive',
              message: "User:#{username} does not have the permission #{@permission}. " \
                'Use <code><nowiki>{{subst:User:MusikBot/override|d}}</nowiki></code> to archive as approved or ' \
                '<code><nowiki>{{subst:User:MusikBot/override|nd}}</nowiki></code> to archive as declined',
              log_message: "    #{username} does not have the permission #{@permission}"
            ) and next
          end
        end

        resolution_page_name = resolution == 'done' ? 'Approved' : 'Denied'
        info("    archiving as #{resolution_page_name.upcase}")
        archive_key = "#{resolution_page_name}/#{Date::MONTHNAMES[resolution_date.month]} #{resolution_date.year}"
        archive_set = @archive_changes[archive_key].to_a << {
          username: username,
          permission: @permission,
          revision_id: @revision_id,
          date: resolution_date
        }
        @archive_changes[archive_key] = archive_set

        @users_count += 1
        @edit_summaries << "archive#{resolution_page_name}".to_sym

        new_wikitext << bot_section
        # absence of new_wikitext << @split + section == remove entry from page
        next
      end
      # </ARCHIVING>

      if resolution
        info("  #{username}'s request already responded to")
        new_wikitext << @split_key + section + bot_section
      elsif section.match(/{{comment|Automated comment}}.*MusikBot/) && !should_update_prereq_data
        info("  MusikBot has already commented on #{username}'s request and no prerequisite data to update")
        new_wikitext << @split_key + section + bot_section
      else
        have_responded = false

        # NOTE: the && !should_update_prereq_data is just a way to see if the request has already been assessed by MusikBot.
        #       We still need this check individually as during the first pass it will be false so that all tasks run, including prereqs

        # <AUTORESPOND>
        if @config['autorespond'] && !should_update_prereq_data && @permission == 'Confirmed'
          debug("  Checking if #{username} already has permission #{@permission}...")

          # TODO: check for sysop on AWB requests
          sleep 1
          if user_info = get_user_info(username)
            if user_info[:userGroups].grep(/#{PERMISSION_KEYS[@permission]}/).length > 0
              info('    Found matching user group')
              request_changes << {
                type: :autorespond,
                permission: @permission.downcase,
                resolution: '{{already done}}'
              }
              have_responded = true
              @num_open_requests -= 1
              @edit_summaries << :autorespond
            end
          end
        end
        # </AUTORESPOND>

        # <AUTOFORMAT>
        if @config['autoformat'] && !should_update_prereq_data && @permission != 'AWB'
          debug('  Checking if request is fragmented...')

          fragmented_regex = /{{rfplinks.*}}\n:(Reason for requesting (?:#{@PERMISSIONS.join("|").downcase}) rights) .*\(UTC\)\n*(.*)/
          fragmented_match = section.scan(fragmented_regex)

          if fragmented_match.length > 0
            info("    Found improperly formatted request for #{username}, repairing")

            actual_reason = fragmented_match.flatten[1]

            if actual_reason.length == 0 && @headers_removed[username]
              actual_reason = @headers_removed[username]
            else
              section.gsub!(actual_reason, '')
              loop do
                frag_match = section.match(fragmented_regex)
                if frag_match && frag_match[2] != '' && !(frag_match[2].include?('UTC') && !frag_match[2].include?(username))
                  reason_part = frag_match[2]
                  actual_reason += "\n:#{reason_part}"
                  section.gsub!(reason_part, '')
                else
                  break
                end
              end
            end

            section.gsub!(fragmented_match.flatten[0], actual_reason)

            duplicate_sig = section.scan(/.*\(UTC\)(.*\(UTC\))/)
            if duplicate_sig.length > 0
              info('    Duplicate signature found, repairing')
              sig = duplicate_sig.flatten[0]
              section = section.sub(sig, '')
            end

            request_changes << { type: :autoformat }
            @edit_summaries << :autoformat
          elsif @headers_removed[username] && @headers_removed[username].length > 0
            request_changes << { type: :autoformat }
            @edit_summaries << :autoformat
          end
        end
        # </AUTOFORMAT>

        if !have_responded && @permission != 'Confirmed' && !username.downcase.match(/bot$/)
          # <PREREQUISTES>
          if @config['prerequisites'] && !prereqs.empty?
            if updating_prereq = section.match(/&lt;!-- mb-\w*(?:Count|Age) --&gt;/)
              debug('  Checking if prerequisite update is needed...')
            else
              debug("  Checking if #{username} meets configured prerequisites...")
            end

            sleep 1
            user_info = get_user_info(username, prereqs.keys)

            prereqs.each do |key, value|
              pass = user_info[key.to_sym] >= value rescue nil

              next if pass.nil? && user_info && user_info[:editCount] > 50_000

              if pass.nil?
                record_error(
                  group: 'prerequisites',
                  message: "Failed to fetch data <tt>#{key}</tt> for User:#{username}",
                  log_message: "      failed to fetch prerequisite data: #{key}"
                )
              elsif pass
                info('      User meets criteria')
                # if updating_prereq
                #   info("      Removing prereq comment")

                #   # FIXME: either check if this prereq is part of a string of other prereqs and only remove that part,
                #   #   or find a way to remove the comment altogether before looping through prereq array
                #   section.gsub!(/\\n::{{comment\|Automated comment}}.*&lt;!-- mbdate --&gt; \d\d:\d\d, \d+ \w+ \d{4} \(UTC\)/, "")
                #   should_update_prereq_data = false
                # end
              elsif updating_prereq
                prereq_count_regex = section.scan(/(&lt;!-- mb-#{key} --&gt;(.*)&lt;!-- mb-#{key}-end --&gt;)/)
                prereq_text = prereq_count_regex.flatten[0]
                prereq_count = prereq_count_regex.flatten[1].to_i rescue 0

                if !user_info[key.to_sym].nil? && user_info[key.to_sym].to_i > prereq_count && prereq_count > 0
                  section.gsub!(prereq_text, "&lt;!-- mb-#{key} --&gt;#{user_info[key.to_sym].to_i}&lt;!-- mb-#{key}-end --&gt;")
                  section.gsub!(prereq_signature, '~~~~')

                  info('    Prerequisite data updated')
                  request_changes << { type: :prerequisitesUpdated }
                  @edit_summaries << :prerequisitesUpdated
                else
                  debug('      Update not needed')
                end
              elsif !pass
                info("      Found unmet prerequisite: #{key}")
                request_changes << { type: key }.merge(user_info)
                @edit_summaries << :prerequisites
              end
            end
          end
          # </PREREQUISTES>

          # <FETCH DECLINED>
          if @config['fetchdeclined'] && !should_update_prereq_data
            debug("  Searching for declined #{@permission} requests by #{username}...")

            begin
              links = find_links(username)

              if links.length > 0
                info('    Found previously declined requests')
                links_message = links.map { |l| "[#{l}]" }.join

                request_changes << {
                  type: :fetchdeclined,
                  numDeclined: links.length,
                  declinedLinks: links_message
                }
                @edit_summaries << :fetchdeclined
              end
            rescue => e
              warn("    Unknown exception when finding links: #{e.message}")
            end
          end
          # </FETCH DECLINED>
        end

        new_wikitext = queue_changes(request_changes, section, bot_section, new_wikitext)
      end
    end

    edit_permission_page(CGI.unescapeHTML(new_wikitext.join))
  end

  def self.queue_changes(request_changes, section, bot_section, new_wikitext)
    if request_changes.length > 0
      info('***** Commentable data found *****')
      @users_count += 1

      new_section = @split_key + section.gsub(/\n+$/, '')

      if request_changes.index { |obj| obj[:type] == :prerequisitesUpdated }
        new_section += "\n"
      else
        new_section += message_compiler(request_changes)
      end
      new_wikitext << new_section + bot_section
    else
      info('  ~~ No commentable data found ~~')
      new_wikitext << @split_key + section + bot_section
    end
  end

  def self.archive_requests
    return nil unless @archive_changes.length > 0

    num_requests = @archive_changes.values.flatten.length

    info("***** Archiving #{num_requests} requests *****")

    @archive_changes.keys.each do |key|
      page_to_edit = "Wikipedia:Requests for permissions/#{key}"
      month_name = key.scan(/\/(\w+)/).flatten[0]
      year = key.scan(/\d{4}/).flatten[0]

      @archive_fetch_throtte = 0
      unless page_wikitext = fetch_archive_page(page_to_edit)
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
        # month_name = Date::MONTHNAMES[request[:date].month]
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

        @archive_fetch_throtte = 0
        unless log_page = fetch_archive_page(log_page_name)
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

        @edit_throttle = 0
        info("    Attempting to write to page [[#{log_page_name}]]")
        log_page_wikitext = log_page.split('===')[0] + log_page_wikitext
        return false unless edit_page(log_page_name, log_page_wikitext, "Adding entry for [[#{page_to_edit}]]")
      end

      @edit_throttle = 0
      info("  Attempting to write to page [[#{page_to_edit}]]")
      return false unless edit_page(page_to_edit, new_wikitext, edit_summary)
    end
  end

  def self.edit_page(page_name, content, edit_summary)
    if @edit_throttle < EDIT_THROTTLE
      sleep @edit_throttle
      @edit_throttle += 1

      begin
        opts = {
          contentformat: 'text/x-wiki',
          summary: edit_summary,
          text: content
        }
        @mw.edit(page_name, CGI.unescapeHTML(content), opts)
      rescue MediaWiki::APIError => e
        warn("API error when writing to page: #{e.code}, trying again")
        return edit_page(page_name, content, edit_summary)
      rescue => e
        error("Unknown exception when writing to page: #{e.message}") and return false
      end
    else
      error('Throttle hit for edit page operation, aborting') and return false
    end
  end

  def self.fetch_archive_page(page_name)
    if @archive_fetch_throtte < 3
      sleep @archive_fetch_throtte
      @archive_fetch_throtte += 1
      info("Fetching page [[#{page_name}]]")
      begin
        opts = {
          prop: 'revisions',
          rvprop: 'content',
          titles: page_name
        }

        page_obj = @mw.custom_query(opts)[0][0].elements['revisions']

        return page_obj[0][0].to_s rescue ''
      rescue => e
        warn("Unable to fetch page properties, reattmpt ##{@archive_fetch_throtte}. Error: #{e.message}")
        return fetch_archive_page(page_name)
      end
    else
      error('Unable to fetch page properties, continuing to process next permission') and return false
    end
  end

  def self.report_errors
    errors_digest = Digest::MD5.hexdigest(@errors.values.join)
    if @run_status['report_errors'] != errors_digest || parse_date_time(@run_status['report']) < current_time - Rational(6, 24)
      unless generate_report
        @run_status['report'] = current_time.to_s
        @run_status['report_errors'] = errors_digest
      end
    end
  end

  def self.generate_report
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

    @edit_throttle = 0
    info('Updating report...')
    unless edit_page('User:MusikBot/PermClerk/Report', content, 'Updating [[User:MusikBot/PermClerk|PermClerk]] report')
      error('  Unable to update report') and return false
    end
  end

  def self.edit_permission_page(new_wikitext, e = nil)
    admin_backlog = !!(new_wikitext =~ /\{\{admin\s*backlog(?:\|bot=MusikBot)?\}\}/)

    fixes = []

    if @num_open_requests > 0
      request_count_msg = "#{@num_open_requests} open request#{'s' if @num_open_requests > 1} remaining"
      new_wikitext.gsub!(/\{\{no\s*admin\s*backlog(?:\|bot=MusikBot)?\}\}/, '{{admin backlog|bot=MusikBot}}')
      @edit_summaries << :admin_backlog if backlog_change = !admin_backlog
    else
      request_count_msg = '0 open requests remaining'
      new_wikitext.gsub!(/\{\{admin\s*backlog(?:\|bot=MusikBot)?\}\}/, '{{no admin backlog|bot=MusikBot}}')
      @edit_summaries << :noAdminBacklog if backlog_change = admin_backlog
    end

    unless @users_count > 0 || headers_removed? || backlog_change
      info('Nothing to do this time around') and return true
    end

    info('  updating {{adminbacklog}}') if backlog_change

    # get approved/denied counts
    approved = @edit_summaries.count(:archiveApproved)
    denied = @edit_summaries.count(:archiveDenied)
    if approved + denied > 0
      archive_msg = []
      archive_msg << "#{approved} approved" if approved > 0
      archive_msg << "#{denied} denied" if denied > 0
      archive_msg = archive_msg.join(', ')
    end

    plural = @users_count > 1

    fixes << "archiving (#{archive_msg})" if approved.to_i + denied.to_i > 0
    fixes << 'marked request as already done' if @edit_summaries.include?(:autorespond)
    fixes << "repaired malformed request#{'s' if plural}" if @edit_summaries.include?(:autoformat)
    fixes << 'prerequisite data updated' if @edit_summaries.include?(:prerequisitesUpdated)
    fixes << 'unmet prerequisites' if @edit_summaries.include?(:prerequisites)
    fixes << 'found previously declined requests' if @edit_summaries.include?(:fetchdeclined)
    fixes << 'unable to archive one or more requests' if @edit_summaries.include?(:noSaidPermission)

    if fixes.length == 0
      fixes << '{{admin backlog}}' if @edit_summaries.include?(:admin_backlog)
      fixes << '{{no admin backlog}}' if @edit_summaries.include?(:noAdminBacklog)
    end

    if @perm_edit_throttle < EDIT_THROTTLE
      sleep @perm_edit_throttle
      @perm_edit_throttle += 1

      info("Attempting to write to page [[#{@page_name}]]")

      # attempt to save
      begin
        opts = {
          basetimestamp: @base_timestamp,
          contentformat: 'text/x-wiki',
          starttimestamp: @start_timestamp,
          summary: "Bot clerking#{" on #{@users_count} requests" if plural}: #{fixes.join(', ')} (#{request_count_msg})",
          text: new_wikitext
        }

        @mw.edit(@page_name, new_wikitext, opts)
      rescue MediaWiki::APIError => e
        if e.code.to_s == 'editconflict'
          warn('Edit conflict, trying again')
          return process(@permission)
        else
          warn("API error when writing to page: #{e.code}, trying again")
          return edit_permission_page(new_wikitext, e)
        end
      rescue => e
        record_error(
          group: 'Saving',
          message: "Exception thrown when writing to page. Error: <tt>#{e.message}</tt>",
          log_message: "Unknown exception when writing to page: #{e.message}"
        ) and return false
      end
    else
      record_error(
        group: 'Saving',
        message: 'Throtte hit for edit page operation. ' + lastError ? "Error: <tt>#{e.message}</tt>. " : '',
        log_message: 'Throttle hit for edit page operation, continuing to process next permission'
      ) and return false
    end

    true
  end

  def self.find_links(username)
    if @user_links_cache[username]
      debug("Cache hit for #{username}")
      return @user_links_cache[username]
    end

    permission_name = @permission == 'AWB' ? 'AutoWikiBrowser/CheckPage' : @permission

    current_date = Date.today
    target_date = current_date - @config['fetchdeclined_offset']
    links = []
    dates_to_fetch = (target_date..current_date).select { |d| d.day == target_date.day || d.day == current_date.day }.uniq(&:month)

    dates_to_fetch.each do |date|
      key = "#{Date::MONTHNAMES[date.month]} #{date.year}"
      if @denied_cache[key]
        debug("    Cache hit for #{key}")
        page = @denied_cache[key]
      else
        page = @mw.get("Wikipedia:Requests for permissions/Denied/#{key}")
        @denied_cache[key] = page
      end

      next unless page

      decline_days = page.split(/==\s*\w+\s+/i)
      decline_days.each do |declineDay|
        day_number = declineDay.scan(/^(\d+)\s*==/).flatten[0].to_i
        next if day_number == 0
        decline_day_date = Date.parse("#{date.year}-#{date.month}-#{day_number}")
        if decline_day_date >= target_date && match = declineDay.scan(/{{Usercheck.*\|#{username.gsub('_', ' ')}}}.*#{permission_name}\]\].*(https?:\/\/.*)\s+link\]/i)[0]
          links << match.flatten[0]
        end
      end
    end

    @user_links_cache[username] = links
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

    # don't start any queries gone wild
    unless @user_info_cache[username][:editCount] > 50_000
      data_attrs.each do |dataAttr|
        count =
          case dataAttr.downcase
          when 'articlecount'
            @repl_client.count_articles_created(username)
          when 'modulespacecount'
            @repl_client.count_namespace_edits(username, 828)
          when 'mainspacecount'
            @repl_client.count_namespace_edits(username, 0)
          when 'manualmainspacecount'
            @repl_client.count_nonautomated_namespace_edits(username, 0)
          when 'templatespacecount'
            @repl_client.count_namespace_edits(username, 10)
          when 'templateandmodulespacecount'
            @repl_client.count_namespace_edits(username, [10, 828])
        end

        if count
          @user_info_cache[username].store(dataAttr.to_sym, count)
          sleep 1
        end
      end
    end

    return @user_info_cache[username]
  rescue
    error("  Unable to fetch user info for #{username}") and return false
  end

  def self.api_user_info(username, throttle = 0)
    sleep throttle * 5
    @mw.custom_query(
      list: 'users',
      ususers: username,
      usprop: 'groups|editcount|registration',
      continue: ''
    )
  rescue MediaWiki::APIError => e
    raise e and return nil if throttle > 5
    api_user_info(username, throttle + 1)
  end

  def self.get_message(type, params = {})
    permission_name = @permission == 'AWB' ? 'AWB access' : @permission.downcase

    case type
    when :accountAge
      "has had an account for <!-- mb-accountAge -->#{params[:accountAge]}<!-- mb-accountAge-end --> days"
    when :articleCount
      "has created roughly <!-- mb-articleCount -->#{params[:articleCount]}<!-- mb-articleCount-end --> [[WP:ARTICLE|article#{'s' if params[:articleCount] != 1}]]"
    when :autoformat
      'An extraneous header or other inappropriate text was removed from this request'
    when :autorespond
      "already has the \"#{params[:permission]}\" user right"
    when :editCount
      "has <!-- mb-editCount -->#{params[:editCount]}<!-- mb-editCount-end --> total edits"
    when :fetchdeclined
      "has had #{params[:numDeclined]} request#{'s' if params[:numDeclined].to_i > 1} for #{permission_name} declined in the past #{@config['fetchdeclined_offset']} days (#{params[:declinedLinks]})"
    when :mainSpaceCount
      "has <!-- mb-mainSpaceCount -->#{params[:mainSpaceCount]}<!-- mb-mainSpaceCount-end --> edit#{'s' if params[:mainSpaceCount] != 1} in the [[WP:MAINSPACE|mainspace]]"
    when :manualMainSpaceCount
      "has approximately <!-- mb-manualMainSpaceCount -->#{params[:manualMainSpaceCount]}<!-- mb-manualMainSpaceCount-end --> [//tools.wmflabs.org/musikanimal/nonautomated_edits?username=#{URI.escape(params[:username])}&offset=0&namespace=0&contribs=on&tools=on non-automated edit#{'s' if params[:manualMainSpaceCount] != 1}] in the [[WP:MAINSPACE|mainspace]]"
    when :moduleSpaceCount
      "has <!-- mb-moduleSpaceCount -->#{params[:moduleSpaceCount]}<!-- mb-moduleSpaceCount-end --> edit#{'s' if params[:moduleSpaceCount] != 1} in the [[WP:LUA|module namespace]]"
    when :noSaidPermission
      "does not appear to have the permission <tt>#{params[:permission]}</tt><!-- mbNoPerm -->"
    when :templateSpaceCount
      "has <!-- mb-templateSpaceCount -->#{params[:templateSpaceCount]}<!-- mb-templateSpaceCount-end --> edit#{'s' if params[:templateSpaceCount] != 1} in the [[WP:TMP|template namespace]]"
    when :templateAndModuleSpaceCount
      "has <!-- mb-templateAndModuleSpaceCount -->#{params[:templateAndModuleSpaceCount]}<!-- mb-templateAndModuleSpaceCount-end --> edit#{'s' if params[:templateAndModuleSpaceCount] != 1} in the [[WP:TMP|template]] and [[WP:LUA|module]] namespaces"
    end
  end

  def self.message_compiler(requestData)
    str = ''

    comment_indent = @permission == 'AWB' ? AWB_COMMENT_INDENT : COMMENT_INDENT

    if index = requestData.index { |obj| obj[:type] == :autoformat }
      requestData.delete_at(index)
      str = "#{comment_indent}<small>#{COMMENT_PREFIX}#{get_message(:autoformat)} ~~~~</small>\n"
      return str if requestData.length == 0
    end

    if index = requestData.index { |obj| obj[:type] == :autorespond }
      str += "\n::#{requestData[index][:resolution]} (automated response): This user "
    else
      str += comment_indent + COMMENT_PREFIX + 'This user '
    end

    requestData.each_with_index do |data, i|
      type = data.delete(:type).to_sym
      str = str.chomp(', ') + ' and ' if i == requestData.length - 1 && requestData.length > 1
      str += get_message(type, data) + ', '
    end

    str.chomp(', ') + ". ~~~~\n"
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
    return false unless old_wikitext

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

  def self.headers_removed?
    @headers_removed.length > 0
  end

  def self.set_page_props
    if @fetch_throtte < 3
      sleep @fetch_throtte
      @fetch_throtte += 1
      info("Fetching page properties of [[#{@page_name}]]")
      begin
        @start_timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')

        opts = {
          prop: 'info|revisions',
          rvprop: 'timestamp|content',
          titles: @page_name
        }

        page_obj = @mw.custom_query(opts)[0][0]
        @base_timestamp = page_obj.elements['revisions'][0].attributes['timestamp']
        @revision_id = page_obj.attributes['lastrevid']

        return page_obj.elements['revisions'][0][0].to_s
      rescue => e
        warn("Unable to fetch page properties, reattmpt ##{@fetch_throtte}. Error: #{e.message}")
        return set_page_props
      end
    else
      record_error(
        group: 'Internal error',
        message: 'Unable to fetch page properties.',
        log_message: 'Unable to fetch page properties, continuing to process next permission'
      ) and return false
    end
  end

  def self.record_error(opts)
    error_set = opts[:error_set] || @permission
    @errors[error_set] = @errors[error_set].to_a << {
      group: opts[:group],
      message: opts[:message]
    }
    error(opts[:log_message])
  end

  def self.debug(msg); @logger.debug("#{@permission.upcase} : #{msg}"); end
  def self.info(msg); @logger.info("#{@permission.upcase} : #{msg}"); end
  def self.warn(msg); @logger.warn("#{@permission.upcase} : #{msg}"); end
  def self.error(msg); @logger.error("#{@permission.upcase} : #{msg}"); end
  def self.parse_date_time(str); DateTime.parse(str).new_offset(0); end
  def self.current_time; DateTime.now.new_offset(0); end
end
