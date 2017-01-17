$LOAD_PATH << '..'
require 'musikbot'

module PermClerk
  COMMENT_INDENT = "\n::".freeze
  COMMENT_PREFIX = '{{comment|Automated comment}} '.freeze
  SPLIT_KEY = '====[[User:'.freeze
  AWB_CHECKPAGE = 'Wikipedia:AutoWikiBrowser/CheckPage'.freeze

  def self.run
    @mb = MusikBot::Session.new(inspect)

    @denied_cache = {}
    @user_info_cache = {}
    @user_links_cache = {}
    @archive_changes = {}
    @errors = {}
    @total_user_count = 0

    @mb.config[:pages].keys.each do |permission|
      @permission = permission.to_s
      @edit_summaries = []
      @headers_removed = {}
      @users_count = 0

      begin
        @flag_as_ran = false
        process_permission

        if @flag_as_ran
          @total_user_count += @users_count
          run_status[@permission] = @mb.now.to_s
        end
      rescue => e
        @mb.report_error("Failed to process #{permission}", e)
        @errors[@permission] = @errors[@permission].to_a << {
          group: 'fatal',
          message: 'Failed for unknown reasons. Check the [[User:MusikBot/PermClerk/Error log|error log]] ' \
            'and contact the [[User talk:MusikAnimal|bot operator]] if you are unable to resolve the issue.'
        }
      end
    end

    archive_requests if @archive_changes.any?

    generate_report

    @mb.local_storage(run_status)

    info("#{'~' * 25} Task complete #{'~' * 25}")
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.process_permission(throttle = 0)
    info("Processing #{@permission}...")
    page_name = "Wikipedia:Requests for permissions/#{@permission}"

    old_wikitext = page_props(page_name)
    return unless old_wikitext.present? && formatting_check(old_wikitext)

    last_run = @mb.parse_date(run_status[@permission])

    if prereqs # if prereqs enabled for this permission
      has_prereq_data = old_wikitext.match(/\<!-- mb-\w*(?:Count|Age) --\>/)
      should_check_prereq_data = has_prereq_data.present?
    else
      should_check_prereq_data = false
    end

    # only process if there's data to update, the page has changed since the last run, or 90 minutes has passed
    if @mb.env == :production && !should_check_prereq_data && last_run > @last_edit && last_run + Rational(90, 1440) > @mb.now
      return info('  Less than 90 minutes since last run without changes, and no prerequisites to update')
    else
      @flag_as_ran = true
    end

    if @mb.config[:run][:autoformat]
      info('Checking for extraneous headers')
      old_wikitext = remove_headers(old_wikitext)
    end

    # first make fixes to confirm to what SPLIT_KEY looks for
    old_wikitext.gsub!(/\=\=\=\=\s+\[\[User:/, '====[[User:')

    @new_wikitext = []
    sections = old_wikitext.split(SPLIT_KEY)
    @new_wikitext << sections.shift

    @num_open_requests = 0
    @open_timestamps = []

    sections.each do |section|
      process_section(section)
    end

    @new_wikitext = @new_wikitext.map { |aa| aa.chomp('') }.join("\n\n")

    admin_backlog

    if @edit_summaries.any?
      @mb.edit(page_name,
        content: @new_wikitext,
        summary: perm_edit_summary,
        conflicts: true
      )
    else
      info('Nothing to do this time around')
    end
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      process_permission(throttle + 1)
    else
      raise
    end
  end

  def self.process_section(section)
    @section = section
    @request_changes = []

    username = @section.scan(/{{(?:template\:)?rfplinks\|1=(.*?)}}/i).flatten[0]
    return SPLIT_KEY + @section unless username
    username[0] = username[0].capitalize
    username.strip!
    @username = username.descore

    info("Checking section for User:#{@username}...")

    timestamps = @section.scan(/(?<!\<!-- mbdate --\> )\b\d\d:\d\d, \d+ \w+ \d{4} \(UTC\)/)
    @newest_timestamp = @mb.parse_date(timestamps.min { |a, b| @mb.parse_date(b) <=> @mb.parse_date(a) })
    @request_timestamp = @mb.parse_date(timestamps.min { |a, b| @mb.parse_date(a) <=> @mb.parse_date(b) })

    overriden_resolution = if @section =~ %r{\{\{User:MusikBot/override\|d\}\}}
                             'done'
                           elsif @section =~ /\{\{User:MusikBot\/override\|nd\}\}/i
                             'notdone'
                           else
                             false
                           end

    info('  Resolution override found') if overriden_resolution

    done_regex = @mb.config[:archive_config][:done]
    notdone_regex = @mb.config[:archive_config][:notdone]
    revoked_regex = @mb.config[:archive_config][:revoked]

    resolution = if overriden_resolution
                   overriden_resolution
                 elsif @section =~ /(?:#{revoked_regex})/i
                   'revoked'
                 elsif @section =~ /(?:#{done_regex})/i
                   'done'
                 elsif @section =~ /(?:#{notdone_regex})/i
                   'notdone'
                 else
                   false
                 end

    resolution_timestamp = @mb.parse_date(
      @section.scan(/(?:#{@mb.config[:archive_config][resolution.to_sym]}).*(\d\d:\d\d, \d+ \w+ \d{4} \(UTC\))/i).flatten.drop(1).last
    ) if resolution

    # use newest timestamp when forcing resolution and no resolution template exists
    if resolution_timestamp.nil? && overriden_resolution
      resolution_timestamp = @newest_timestamp
    end

    @num_open_requests += 1 unless resolution

    # archiving has precedence; e.g. if we are archiving, we don't do anything else for this section
    return if archiving(resolution, overriden_resolution, resolution_timestamp)

    # determine if there's any else to be done
    if resolution
      info("  #{@username}'s request already responded to")
      @new_wikitext << SPLIT_KEY + @section
      return
    end

    @open_timestamps << timestamps.min { |a, b| @mb.parse_date(a) <=> @mb.parse_date(b) }
    @should_update_prereq_data = should_update_prereq_data

    if @section.match(/{{comment\|Automated comment}}.*MusikBot/) && !@should_update_prereq_data
      info("  MusikBot has already commented on #{username}'s request and no prerequisite data to update")
      @new_wikitext << SPLIT_KEY + @section
      return
    end

    # these tasks have already been ran if we're just updating prereq data
    unless @should_update_prereq_data
      # autoformat first, especially the case for Confirmed where they have a malformed report and are already autoconfirmed
      autoformat
      if autorespond
        @num_open_requests -= 1
        return queue_changes
      end
      fetch_declined
      check_revoked
    end
    prerequisites
    queue_changes
  end

  # Core tasks
  def self.fetch_declined
    return if !@mb.config[:run][:fetch_declined] || @permission == 'Confirmed'
    info("  Searching for declined #{@permission} requests by #{@username}...")

    # cache for a day
    links = @mb.cache("mb-#{@username}-#{@permission}-declined", 86_400) do
      find_links
    end
    links = JSON.parse(links) if links.is_a?(String)

    if links.any?
      info('    Found previously declined requests')
      links_message = links.map { |l| "[#{l}]" }.join

      @request_changes << {
        type: :fetchdeclined,
        numDeclined: links.length,
        declinedLinks: links_message
      }
      @edit_summaries << :fetchdeclined
    end
  end

  def self.find_links
    target_date = @mb.today - @mb.config[:fetchdeclined_config][:offset]
    links = []
    dates_to_fetch = (target_date..@mb.today).select { |d| d.day == target_date.day || d.day == @mb.today.day }.uniq(&:month)

    dates_to_fetch.each do |date|
      key = "#{Date::MONTHNAMES[date.month]} #{date.year}"
      if @denied_cache[key]
        info("    Cache hit for #{key}")
        page = @denied_cache[key]
      else
        page = @mb.get("Wikipedia:Requests for permissions/Denied/#{key}")
        @denied_cache[key] = page
      end

      next unless page

      decline_days = page.split(/==\s*\w+\s+/i)
      decline_days.each do |decline_day|
        day_number = decline_day.scan(/^(\d+)\s*==/).flatten[0].to_i
        next if day_number == 0
        decline_day_date = @mb.parse_date("#{date.year}-#{date.month}-#{day_number}")
        match = decline_day.scan(/\{\{Usercheck.*\|#{Regexp.escape(@username).descore}}}.*#{@permission}\]\].*(https?:\/\/.*)\s+link\]/i)[0]
        links << match.flatten[0] if decline_day_date >= target_date && match
      end
    end

    links
  end

  def self.autorespond
    return false unless @mb.config[:run][:autorespond] && api_relevant_permission
    info("    User has permission #{@permission}")

    if sysop? || @permission == 'AutoWikiBrowser'
      # if sysop, no need to do other checks
      # for AWB just say "already done" as it's too expensive to figure out when they were added
      time_granted = @request_timestamp
    elsif api_relevant_permission == 'autoconfirmed'
      # make time_granted earlier than request_timestamp to force marking as done
      time_granted = @request_timestamp - 1
    else
      event = fetch_last_granted
      time_granted = @mb.parse_date(event.attributes['timestamp'])
    end

    if time_granted <= @request_timestamp
      request_change = {
        type: :autorespond,
        resolution: '{{already done}}'
      }
    elsif @mb.now > time_granted + Rational(@mb.config[:autorespond_config][:offset].to_i, 24)
      info('      Admin apparently forgot to respond to the request')
      request_change = {
        type: :autorespond_admin_forgot,
        resolution: '{{already done}}',
        admin: event.attributes['user']
      }
    else
      info('      Admin has not responded to request yet')
      # return true to skip other checks, as they've already got the right
      return true
    end

    @request_changes << {
      permission: api_relevant_permission,
      sysop: sysop?
    }.merge(request_change)

    @num_open_requests -= 1
    @edit_summaries << :autorespond
    true
  end

  def self.autoformat
    return unless @mb.config[:run][:autoformat]

    # FIXME: make this work for AutoWikiBrowser (might work with |access) or rather it is auto-removed by the template
    fragmented_regex = /\{\{rfplinks.*\}\}\n:(Reason for requesting (?:#{@permission.downcase}) (?:rights|access)) .*\(UTC\)(?m:(.*?)(?:\n\=\=|\z))/
    fragmented_match = @section.scan(fragmented_regex)

    unless fragmented_match.present?
      if @headers_removed[@username] && @headers_removed[@username].present?
        @request_changes << { type: :autoformat }
        @edit_summaries << :autoformat
      end
      return
    end

    info("    Found improperly formatted request for #{@username}, repairing")

    actual_reason = fragmented_match.flatten[1]
    if actual_reason.empty? && @headers_removed[@username]
      actual_reason = @headers_removed[@username]
    else
      @section.gsub!(actual_reason, '')

      loop do
        frag_match = @section.match(fragmented_regex)
        if frag_match && frag_match[2] != '' && !(frag_match[2].include?('UTC') && !frag_match[2].include?(@username))
          reason_part = frag_match[2]
          actual_reason += "\n:#{reason_part}"
          @section.gsub!(reason_part, '')
        else
          break
        end
      end
    end

    actual_reason = actual_reason.gsub(/^\s*\n+/, '').chomp('')

    if @headers_removed[@username]
      actual_reason = "#{@headers_removed[@username].strip}: #{actual_reason.strip}"
    end

    @section.gsub!(fragmented_match.flatten[0], actual_reason)

    duplicate_sig = @section.scan(/.*\(UTC\)(.*\(UTC\))/)
    if duplicate_sig.any?
      info('    Duplicate signature found, repairing')
      sig = duplicate_sig.flatten[0]
      @section = @section.sub(sig, '')
    end

    @request_changes << { type: :autoformat }
    @edit_summaries << :autoformat
  end

  def self.prerequisites
    return unless @mb.config[:run][:prerequisites] && prereqs.present? && @permission != 'Confirmed' # && !@username.downcase.match(/bot$/)
    info("  Checking if #{@username} meets configured prerequisites...")

    if @mb.redis_client.get("mb-#{@username}-#{@permission}-qualified")
      return info('    Cache hit, user meets criteria')
    end

    updating_prereq = @section.match(/\<!-- mb-\w*(?:Count|Age) --\>/)

    user_info = get_user_info(@username, prereqs.keys)

    prereqs.each do |key, value|
      pass = user_info[key] >= value rescue nil
      next if pass.nil? && user_info && user_info[:editCount] > 50_000

      if pass.nil?
        record_error(
          group: 'prerequisites',
          message: "Failed to fetch data <tt>#{key}</tt> for User:#{@username}",
          log_message: "      failed to fetch prerequisite data: #{key}"
        )
      elsif pass
        info('      User meets criteria')
        @mb.redis_client.set("mb-#{@username}-#{@permission}-qualified", true)
      elsif updating_prereq
        prereq_count_regex = @section.scan(/(\<!-- mb-#{key} --\>(.*)\<!-- mb-#{key}-end --\>)/)
        prereq_text = prereq_count_regex.flatten[0]
        prereq_count = prereq_text.nil? ? 0 : prereq_count_regex.flatten[1].to_i

        if !user_info[key.to_sym].nil? && user_info[key.to_sym].to_i > prereq_count && prereq_count > 0
          @section.gsub!(prereq_text, "<!-- mb-#{key} -->#{user_info[key.to_sym].to_i}<!-- mb-#{key}-end -->")
          @section.gsub!(@prereq_signature, '~~~~')

          info('    Prerequisite data updated')
          @request_changes << { type: :prerequisitesUpdated }
          @edit_summaries << :prerequisitesUpdated
        else
          info('      Update not needed')
        end
      elsif !pass
        info("      Found unmet prerequisite: #{key}")
        @request_changes << { type: key }.merge(user_info)
        @edit_summaries << :prerequisites
      end
    end
  end

  def self.archiving(resolution, overriden_resolution, resolution_timestamp)
    return false unless @mb.config[:run][:archive] && resolution.present?
    should_archive_now = @section.match(/\{\{User:MusikBot\/archivenow\}\}/)

    if resolution_timestamp.nil?
      record_error(
        group: 'archive',
        message: "User:#{@username} - Resolution template not dated",
        log_message: "    User:#{@username}: Resolution template not dated"
      )
      return true
    end

    # not time to archive
    unless should_archive_now || @newest_timestamp + Rational(@mb.config[:archive_config][:offset].to_i, 24) < @mb.now
      return false
    end

    if should_archive_now
      info('  Found request for immediate archiving')
    else
      info('  Time to archive!')
    end

    # if we're archiving as done, check if they have the said permission and act accordingly (skip if overriding resolution)
    if resolution == 'done' && !overriden_resolution && !api_relevant_permission
      if @section.include?('<!-- mbNoPerm -->')
        warn("    MusikBot already reported that #{@username} does not have the permission #{@permission}")
        @new_wikitext << SPLIT_KEY + @section
      else
        @request_changes << {
          type: :noSaidPermission,
          permission: @permission.downcase
        }
        @edit_summaries << :noSaidPermission

        queue_changes

        message = if @permission == 'AutoWikiBrowser'
                    "has not been added to the [[#{AWB_CHECKPAGE}|check page]]"
                  else
                    "does not have the permission #{@permission}"
                  end

        record_error(
          group: 'archive',
          message: "User:#{@username} #{message}. " \
            'Use <code><nowiki>{{subst:User:MusikBot/override|d}}</nowiki></code> to archive as approved or ' \
            '<code><nowiki>{{subst:User:MusikBot/override|nd}}</nowiki></code> to archive as declined',
          log_message: "    #{@username} #{message}"
        )
      end

      return true
    elsif resolution == 'revoked' && !overriden_resolution && api_relevant_permission
      if @section.include?('<!-- mbHasPerm -->')
        warn("    MusikBot already reported that #{@username} still has the permission #{@permission}")
        @new_wikitext << SPLIT_KEY + @section
      else
        @request_changes << {
          type: :saidPermission,
          permission: @permission.downcase
        }
        @edit_summaries << :saidPermission

        queue_changes

        message = if @permission == 'AutoWikiBrowser'
                    "has not been added to the [[#{AWB_CHECKPAGE}|check page]]"
                  else
                    "does not have the permission #{@permission}"
                  end

        record_error(
          group: 'archive',
          message: "User:#{@username} #{message}. " \
            'Use <code><nowiki>{{subst:User:MusikBot/override|d}}</nowiki></code> to archive as approved or ' \
            '<code><nowiki>{{subst:User:MusikBot/override|nd}}</nowiki></code> to archive as declined',
          log_message: "    #{@username} #{message}"
        )
      end

      return true
    end

    resolution_page_name = resolution == 'done' || resolution == 'revoked' ? 'Approved' : 'Denied'
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

    true
  end

  # Extensions to tasks
  def self.queue_changes
    if @request_changes.any?
      info('***** Commentable data found *****')
      @users_count += 1

      @new_section = SPLIT_KEY + @section.chomp('')

      @new_section += if @request_changes.index { |obj| obj[:type] == :prerequisitesUpdated }
                        "\n"
                      else
                        message_compiler(@request_changes)
                      end

      @new_wikitext << @new_section
    else
      info('  ~~ No commentable data found ~~')
      @new_wikitext << SPLIT_KEY + @section
    end
  end

  def self.archive_requests
    num_requests = @archive_changes.values.flatten.length

    info("***** Archiving #{num_requests} requests *****")

    @archive_changes.keys.each do |key|
      page_to_edit = "Wikipedia:Requests for permissions/#{key}"
      month_name = key.scan(/\/(\w+)/).flatten[0]
      year = key.scan(/\d{4}/).flatten[0]

      page_wikitext = @mb.get(page_to_edit) || ''
      new_page = page_wikitext.blank?

      edit_summary = "Archiving #{@archive_changes[key].length} request#{'s' if @archive_changes[key].length > 1}:"

      # ensure there's a newline at the end
      page_wikitext = page_wikitext.chomp('') + "\n"

      # convert sections as a hash of format {"Month day" => "content"}
      sections = Hash[*page_wikitext.split(/\=\=\s*(\w+ \d+)\s*\=\=/).drop(1).flatten(1)]

      @archive_changes[key].each do |request|
        edit_summary += " #{request[:username]} (#{request[:permission].downcase});"
        archive_page_name = "Wikipedia:Requests for permissions/#{request[:permission]}"
        link_markup = "*{{Usercheck-short|#{request[:username]}}} [[#{archive_page_name}]] " \
          "<sup>[http://en.wikipedia.org/wiki/Special:PermaLink/#{request[:revision_id]}#User:#{request[:username].score} link]</sup>"

        # add link_markup to section
        section_key = "#{month_name} #{request[:date].day}"
        sections[section_key] = sections[section_key].to_s.gsub(/^\n|\n$/, '') + "\n" + link_markup + "\n"
      end
      edit_summary.chomp!(';')

      # construct back to single wikitext string, sorted by day
      new_wikitext = ''
      sorted_keys = sections.keys.sort_by { |k| k.scan(/\d+/)[0].to_i }
      sorted_keys.each do |sort_key|
        new_wikitext += "\n== " + sort_key + " ==\n" + sections[sort_key].gsub(/^\n/, '')
      end

      # we're done archiving for this month

      # first see if it's a new page and if so add it to the log page
      if new_page
        log_page_name = "Wikipedia:Requests for permissions/#{key.scan(/(.*)\//).flatten[0]}"
        info("  Adding new page [[#{page_to_edit}]] to log [[#{log_page_name}]]")

        log_page = @mb.get(log_page_name)

        # convert to {"year" => "requests"}
        year_sections = Hash[*log_page.split(/\=\=\=\s*(\d{4})\s*\=\=\=/).drop(1)]
        year_sections[year] = "\n*[[#{page_to_edit}]]" + year_sections[year].to_s

        log_page_wikitext = ''
        year_sections.sort { |a, b| b <=> a }.to_h.keys.each do |year_section_key|
          log_page_wikitext += "\n=== " + year_section_key + " ===\n" + year_sections[year_section_key].gsub(/^\n/, '')
        end

        info("    Attempting to write to page [[#{log_page_name}]]")
        log_page_wikitext = log_page.split('===')[0] + log_page_wikitext

        @mb.edit(log_page_name,
          content: log_page_wikitext,
          summary: "Adding entry for [[#{page_to_edit}]]"
        )
      end

      info("  Attempting to write to page [[#{page_to_edit}]]")
      @mb.edit(page_to_edit,
        content: new_wikitext,
        summary: edit_summary
      )
    end
  end

  def self.check_revoked
    return unless @mb.config[:run][:checkrevoked]

    info("  Checking revocations of #{@permission} for #{@username}...")

    revoke_type = :checkrevoked

    if @permission == 'AutoWikiBrowser'
      awb_report_page = 'User:MusikBot_II/AWBListMan/Report/User'
      auto_revoke_report = @mb.get_page_props(awb_report_page, full_response: true, no_conflict: true)
      if auto_revoke_report.elements['revisions/rev'].text =~ /\{\{no ping\|#{Regexp.escape(@username)}\}\}/
        revision_id = auto_revoke_report.attributes['lastrevid']
        revoke_type = :awb_autorevoked
        revocations = ["#{@mb.gateway.wiki_url.chomp('api.php')}index.php?title=#{awb_report_page}&oldid=#{revision_id}"]
      else
        revocations = check_revoked_awb || []
      end
    else
      revocations = check_revoked_perm.flatten
    end

    return unless revocations.any?

    @request_changes << {
      type: revoke_type,
      permission: @permission.downcase,
      revokedLinks: revocations.map { |l| "[#{l}]" }.join
    }
    @edit_summaries << :checkrevoked
  end

  def self.check_revoked_perm
    revocations = []

    logevents = @mb.gateway.custom_query(
      list: 'logevents',
      letype: 'rights',
      letitle: "User:#{@username}",
      leprop: 'timestamp|details'
    ).elements['logevents'].to_a

    normalized_perm = @mb.config[:pages][@permission.to_sym]

    logevents.each do |event|
      old_events = event.elements['params/oldgroups']
      new_events = event.elements['params/newgroups']
      in_old = old_events && old_events.collect(&:text).grep(normalized_perm).any?
      in_new = new_events && new_events.collect(&:text).grep(normalized_perm).any?
      timestamp = @mb.parse_date(event.attributes['timestamp'])

      next unless in_old && !in_new && timestamp > @mb.today - @mb.config[:checkrevoked_config][:offset]

      # offset by 1 second since it will show everything _before_ the given timestamp
      log_timestamp = timestamp.strftime('%Y%m%d%H%M') + (timestamp.second + 1).to_s

      revocations << "#{@mb.gateway.wiki_url.chomp('api.php')}index.php?title=Special:Log&" \
        "page=User:#{@username.score}&type=rights&offset=#{log_timestamp}&limit=1"
    end

    revocations
  end

  def self.check_revoked_awb
    old_awb_content = @mb.get_revision_at_date(
      AWB_CHECKPAGE,
      @mb.today - @mb.config[:checkrevoked_config][:offset]
    ) rescue nil

    if old_awb_content && old_awb_content =~ /\n\*\s*#{Regexp.escape(@username)}\s*\n/ && !(awb_checkpage_content =~ /\n\*\s*#{Regexp.escape(@username)}\s*\n/)
      return ["#{@mb.gateway.wiki_url.chomp('api.php')}index.php?title=#{AWB_CHECKPAGE}&action=history"]
    else
      return []
    end
  end

  def self.admin_backlog
    # always update for Account creator
    is_account_creator = @permission == 'Account creator'
    return unless @mb.config[:run][:admin_backlog]

    oldest_timestamp = @open_timestamps.min { |a, b| @mb.parse_date(a) <=> @mb.parse_date(b) }
    min_num_requests = is_account_creator ? 0 : @mb.config[:adminbacklog_config][:requests]
    has_old_requests = oldest_timestamp ? @mb.parse_date(oldest_timestamp) <= @mb.today - @mb.config[:adminbacklog_config][:offset] : false

    backlogged = @new_wikitext.include?('{{WP:PERM/Backlog}}')

    if @num_open_requests > 0 && (@num_open_requests >= min_num_requests || has_old_requests)
      return if backlogged # no change
      @edit_summaries << :backlog
      info('{{WP:PERM/Backlog}}')
      @new_wikitext.sub!('{{WP:PERM/Backlog|none}}', '{{WP:PERM/Backlog}}')
    elsif backlogged
      @edit_summaries << :no_backlog
      info('{{WP:PERM/Backlog|none}}')
      @new_wikitext.sub!('{{WP:PERM/Backlog}}', '{{WP:PERM/Backlog|none}}')
    end
  end

  def self.generate_report
    errors_digest = Digest::MD5.hexdigest(@errors.values.join)
    expired = @total_user_count > 0 && @mb.parse_date(run_status['report']) < @mb.now - Rational(6, 24)
    return unless run_status['report_errors'] != errors_digest || expired

    if @errors.keys.any?
      num_errors = @errors.values.flatten.length
      content = '{{hidden|style=display:inline-block;background:transparent|headerstyle=padding-right:3.5em|header=' \
        "<span style='color:red;font-weight:bold'>#{num_errors} error#{'s' if num_errors > 1} as of ~~~~~</span>|content="
      @errors.keys.each do |permission_group|
        content += "\n;[[Wikipedia:Requests for permissions/#{permission_group}|#{permission_group}]]\n"
        @errors[permission_group].each do |error|
          group = error[:group] == 'fatal' ? 'FATAL' : error[:group].capitalize
          content += "* '''#{group}''': #{error[:message]}\n"
        end
      end
      content += '}}'
    else
      content = "<span style='color:green; font-weight:bold'>No errors!</span> Report generated at ~~~~~"
    end

    run_status['report'] = @mb.now.to_s
    run_status['report_errors'] = errors_digest

    info('Updating report...')
    @mb.edit('User:MusikBot/PermClerk/Report',
      content: content,
      summary: 'Updating [[User:MusikBot/PermClerk|PermClerk]] report'
    )
  end

  # Helpers
  def self.sysop?
    get_user_info(@username)[:userGroups].include?('sysop')
  end

  def self.should_update_prereq_data
    if @section =~ /\<!-- mb-/
      prereq_sig_regex = @section.scan(/(\<!-- mbsig --\>.*\<!-- mbdate --\> (\d\d:\d\d.*\d{4} \(UTC\)))/)
      @prereq_signature = prereq_sig_regex.flatten[0]
      @prereq_timestamp = prereq_sig_regex.flatten[1]
      if @mb.now > @mb.parse_date(@prereq_timestamp) + Rational(@mb.config[:prerequisites_config][:offset], 1440)
        info('  Found expired prerequisite data')
        return true
      else
        info("  Prerequisite data under #{@mb.config[:prerequisites_config][:offset]} minutes old")
      end
    end
    false
  end

  def self.formatting_check(old_wikitext)
    ret = true

    split_key_match = old_wikitext.scan(/\n(.*)[^\n]#{Regexp.escape(SPLIT_KEY)}(.*)\n/).flatten
    if split_key_match.any?
      error("A request heading is not on its own line: #{split_key_match[0]}")
      @errors[@permission] = @errors[@permission].to_a << {
        group: 'formatting',
        message: "Unable to process page! A request heading is not on its own line:\n*:" \
          "<code style='color:red'><nowiki>#{split_key_match[0]}</nowiki></code><code><nowiki>#{SPLIT_KEY}#{split_key_match[1]}</nowiki></code>"
      }
      ret = false
    end

    if old_wikitext.scan(/REVISIONUSER|\{\{subst:/).any?
      error('Possible unsubstituted or improperly substituted request')
      @errors[@permission] = @errors[@permission].to_a << {
        group: 'formatting',
        message: 'Possible unsubstituted or improperly substituted request. Bot may be unable to parse the page.'
      }
      ret = false
    end

    ret
  end

  def self.remove_headers(old_wikitext)
    headers_match = old_wikitext.scan(/(^\=\=[^\=]*\=\=([^\=]*)(\=\=\=\=[^\=]*\=\=\=\=\n\*.*rfplinks\|1=(.*)\}\}\n))/)

    if headers_match.any?
      info('Extraneous headers detected')

      headers_match.each do |match|
        name = match[3]
        next unless name

        original_markup = match[0]
        level_two_text = match[1].delete("\n")
        rfp_links_part = match[2]

        old_wikitext.sub!(original_markup, rfp_links_part)
        header_text = original_markup.scan(/\=\=\s*([^\=]*)\s*\=\=/)[0][0]

        @headers_removed[name] = if level_two_text.length > header_text.length
                                   level_two_text.gsub(/^\n*/, '').gsub(/\n$/, '')
                                 else
                                   header_text
                                 end
      end
    end

    old_wikitext
  end

  def self.headers_removed?
    @headers_removed.any?
  end

  def self.get_message(type, params = {})
    case type
    when :accountAge
      "has had an account for <!-- mb-accountAge -->#{params[:accountAge]}<!-- mb-accountAge-end --> days"
    when :articleCount
      "has created roughly <!-- mb-articleCount -->#{params[:articleCount]}<!-- mb-articleCount-end --> [[WP:ARTICLE|article#{'s' if params[:articleCount] != 1}]]"
    when :autoformat
      'An extraneous header or other inappropriate text was removed from this request'
    when :autorespond
      "#{'is a sysop and' if params[:sysop]} already has #{params[:permission] == 'AutoWikiBrowser' ? 'AutoWikiBrowser access' : "the \"#{params[:permission]}\" user right"}"
    when :autorespond_admin_forgot
      "by {{no ping|#{params[:admin]}}}"
    when :checkrevoked
      "has had this permission revoked in the past #{@mb.config[:checkrevoked_config][:offset]} days (#{params[:revokedLinks]})"
    when :awb_autorevoked
      "has had their access to AutoWikiBrowser automatically revoked (#{params[:revokedLinks]})"
    when :editCount
      "has <!-- mb-editCount -->#{params[:editCount]}<!-- mb-editCount-end --> total edits"
    when :fetchdeclined
      "has had #{params[:numDeclined]} request#{'s' if params[:numDeclined].to_i > 1} for #{@permission.downcase} " \
        "declined in the past #{@mb.config[:fetchdeclined_config][:offset]} days (#{params[:declinedLinks]})"
    when :mainSpaceCount
      "has <!-- mb-mainSpaceCount -->#{params[:mainSpaceCount]}<!-- mb-mainSpaceCount-end --> " \
        "edit#{'s' if params[:mainSpaceCount] != 1} in the [[WP:MAINSPACE|mainspace]]"
    when :manualMainSpaceCount
      "has approximately <!-- mb-manualMainSpaceCount -->#{params[:manualMainSpaceCount]}<!-- mb-manualMainSpaceCount-end --> " \
        "[//tools.wmflabs.org/musikanimal/nonautomated_edits?username=#{URI.escape(params[:username])}&offset=0&" \
        "namespace=0&contribs=on&tools=on non-automated edit#{'s' if params[:manualMainSpaceCount] != 1}] in the [[WP:MAINSPACE|mainspace]]"
    when :moduleSpaceCount
      "has <!-- mb-moduleSpaceCount -->#{params[:moduleSpaceCount]}<!-- mb-moduleSpaceCount-end --> " \
        "edit#{'s' if params[:moduleSpaceCount] != 1} in the [[WP:LUA|module namespace]]"
    when :noSaidPermission
      if params[:permission] == 'autowikibrowser'
        "does not appear to have been added to the [[#{AWB_CHECKPAGE}|CheckPage]]<!-- mbNoPerm -->"
      else
        "does not appear to have the permission <tt>#{params[:permission]}</tt><!-- mbNoPerm -->"
      end
    when :saidPermission
      if params[:permission] == 'autowikibrowser'
        "is still one the [[#{AWB_CHECKPAGE}|CheckPage]]<!-- mbHasPerm -->"
      else
        "still holds the <tt>#{params[:permission]} right</tt><!-- mbHasPerm -->"
      end
    when :templateSpaceCount
      "has <!-- mb-templateSpaceCount -->#{params[:templateSpaceCount]}<!-- mb-templateSpaceCount-end --> " \
        "edit#{'s' if params[:templateSpaceCount] != 1} in the [[WP:TMP|template namespace]]"
    when :templateAndModuleSpaceCount
      "has <!-- mb-templateAndModuleSpaceCount -->#{params[:templateAndModuleSpaceCount]}<!-- mb-templateAndModuleSpaceCount-end --> " \
        "edit#{'s' if params[:templateAndModuleSpaceCount] != 1} in the [[WP:TMP|template]] and [[WP:LUA|module]] namespaces"
    end
  end

  def self.message_compiler(request_data)
    str = ''

    if index = request_data.index { |obj| obj[:type] == :autoformat }
      request_data.delete_at(index)
      str = "#{COMMENT_INDENT}<small>#{COMMENT_PREFIX}#{get_message(:autoformat)} ~~~~</small>\n"
      return str if request_data.empty?
    end

    str += if index = request_data.index { |obj| obj[:type] == :autorespond }
             "#{COMMENT_INDENT}#{request_data[index][:resolution]} (automated response): This user "
           elsif index = request_data.index { |obj| obj[:type] == :autorespond_admin_forgot }
             "#{COMMENT_INDENT}#{request_data[index][:resolution]} (automated response) "
           else
             COMMENT_INDENT + COMMENT_PREFIX + 'This user '
           end

    request_data.each_with_index do |data, i|
      type = data.delete(:type).to_sym
      str = str.chomp(', ') + ' and ' if i == request_data.length - 1 && request_data.length > 1
      str += get_message(type, data) + ', '
    end

    str.chomp(', ') + ". ~~~~\n"
  end

  def self.perm_edit_summary
    summaries = []

    # get approved/denied counts
    approved = @edit_summaries.count(:archiveApproved)
    denied = @edit_summaries.count(:archiveDenied)
    if approved + denied > 0
      archive_msg = []
      archive_msg << "#{approved} approved" if approved > 0
      archive_msg << "#{denied} denied" if denied > 0
      archive_msg = archive_msg.join(', ')
      summaries << "archiving (#{archive_msg})"
    end

    plural = @users_count > 1

    summaries << "marked request#{'s' if plural} as already done" if @edit_summaries.include?(:autorespond)
    summaries << "repaired malformed request#{'s' if plural}" if @edit_summaries.include?(:autoformat)
    summaries << 'prerequisite data updated' if @edit_summaries.include?(:prerequisitesUpdated)
    summaries << 'unmet prerequisites' if @edit_summaries.include?(:prerequisites)
    summaries << 'found previously declined requests' if @edit_summaries.include?(:fetchdeclined)
    summaries << 'found previous revocations' if @edit_summaries.include?(:checkrevoked)
    summaries << 'unable to archive one or more requests' if @edit_summaries.include?(:noSaidPermission) || @edit_summaries.include?(:saidPermission)
    summaries << '{{WP:PERM/Backlog}}' if @edit_summaries.include?(:backlog)
    summaries << '{{WP:PERM/Backlog|none}}' if @edit_summaries.include?(:no_backlog)

    request_count_msg = if @num_open_requests > 0
                          "#{@num_open_requests} open request#{'s' if @num_open_requests > 1} remaining"
                        else
                          '0 open requests remaining'
                        end

    "Bot clerking#{" on #{@users_count} requests" if plural}: #{summaries.join(', ')} (#{request_count_msg})"
  end

  # Config-related
  def self.run_status
    @run_status ||= @mb.local_storage
  end

  def self.prereqs
    @mb.config[:run][:prerequisites] ? @mb.config[:prerequisites_config][@permission.to_sym] : nil
  end

  # API-related
  def self.api_relevant_permission
    info("  checking if #{@username} has permission #{@permission}")
    return @permission if sysop?

    if @permission == 'AutoWikiBrowser'
      awb_checkpage_content =~ /\n\*\s*#{Regexp.escape(@username)}\s*\n/ ? 'AutoWikiBrowser' : nil
    else
      get_user_info(@username)[:userGroups].grep(/#{@mb.config[:pages][@permission.to_sym]}/).first
    end
  end

  def self.awb_checkpage_content
    @awb_checkpage_content ||= @mb.get(AWB_CHECKPAGE)
  end

  def self.get_user_info(username, *data_attrs)
    data_attrs = data_attrs.flatten

    # return cache if there's nothing new to fetch
    if @user_info_cache[username] && data_attrs.all? { |da| @user_info_cache[username].keys.include?(da) }
      info("  cache hit for #{username}")
      return @user_info_cache[username]
    end

    data_fetch_str = data_attrs.join(', ')
    info("    Fetching data for: #{data_fetch_str.present? ? data_fetch_str : 'basic info'}")

    # get basic info if we haven't already and query the repl database as needed for other info
    unless @user_info_cache[username] && @user_info_cache[username][:editCount]
      api_obj = @mb.gateway.custom_query(
        list: 'users',
        ususers: username,
        usprop: 'groups|editcount|registration'
      ).elements['users'][0]

      user_info = api_obj.attributes
      registration_date = user_info['registration'] ? @mb.parse_date(user_info['registration']) : nil

      @user_info_cache[username] = {
        # use 1,000,000 for account age if it is nil, since that usually means a really old account
        accountAge: registration_date ? (@mb.today - registration_date).to_i : 1_000_000,
        editCount: user_info['editcount'].to_i,
        registration: registration_date,
        userGroups: api_obj.elements['groups'].to_a.collect { |g| g[0].to_s },
        username: username
      }
    end

    if data_attrs.include?(:rights_log)
      @user_info_cache[username][:rights_log] = @mb.gateway.custom_query(
        list: 'logevents',
        letype: 'rights',
        letitle: "User:#{username}",
        leprop: 'user|timestamp|details'
      ).elements['logevents'].to_a
      return @user_info_cache[username]
    end

    # don't start any queries gone wild
    unless @user_info_cache[username][:editCount] > 50_000
      data_attrs.each do |data_attr|
        count =
          case data_attr.downcase
          when :articlecount
            @mb.repl_client.count_articles_created(username)
          when :modulespacecount
            @mb.repl_client.count_namespace_edits(username, 828)
          when :mainspacecount
            @mb.repl_client.count_namespace_edits(username, 0)
          when :manualmainspacecount
            @mb.repl_client.count_nonautomated_namespace_edits(username, 0)
          when :templatespacecount
            @mb.repl_client.count_namespace_edits(username, 10)
          when :templateandmodulespacecount
            @mb.repl_client.count_namespace_edits(username, [10, 828])
          end

        @user_info_cache[username].store(data_attr, count) if count
      end
    end

    @user_info_cache[username]
  end

  def self.fetch_last_granted
    logevents = get_user_info(@username, :rights_log)[:rights_log]
    normalized_perm = /#{@mb.config[:pages][@permission.to_sym]}/

    # should fetch the latest as the API returns it by date in ascending order
    logevents.each do |event|
      in_old = event.elements['params/oldgroups'].collect(&:text).grep(normalized_perm).any?
      in_new = event.elements['params/newgroups'].collect(&:text).grep(normalized_perm).any?

      return event if !in_old && in_new
    end
  end

  def self.page_props(page)
    page_obj = @mb.get_page_props(page, full_response: true)
    @revision_id = page_obj.attributes['lastrevid']
    @last_edit = @mb.parse_date(page_obj.elements['revisions'][0].attributes['timestamp'])
    page_obj.elements['revisions/rev'].text
  rescue
    record_error(
      group: 'fatal',
      message: "The page [[#{page}]] does not exist!"
    )
    nil
  end

  def self.record_error(opts)
    error_set = opts[:error_set] || @permission
    @errors[error_set] = @errors[error_set].to_a << {
      group: opts[:group],
      message: opts[:message]
    }
    error(opts[:log_message])
  end

  def self.info(msg); log("#{@permission.upcase} : #{msg}"); end
  def self.warn(msg); log("#{@permission.upcase} | WARN : #{msg}"); end
  def self.error(msg); log("#{@permission.upcase} | ERROR : #{msg}"); end
  def self.log(message); puts(@mb.now.strftime("%e %b %H:%M:%S | #{message}")); end
end

PermClerk.run
