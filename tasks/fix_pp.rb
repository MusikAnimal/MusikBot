$LOAD_PATH << '..'
require 'musikbot'

CATEGORY = 'Category:Wikipedia pages with incorrect protection templates'.freeze

module FixPP
  def self.run
    @mb = MusikBot::Session.new(inspect)

    add_pp
    fix_pp
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.add_pp
    templates = (pp_hash.keys + pp_hash.values).uniq
      .map { |t| "'#{t.to_s.dup.ucfirst}'" }
      .join(',')

    offset = @mb.parse_date(
      @mb.local_storage['last_run'] || (@mb.now - 1).to_s
    ).strftime('%Y%m%d%H%M%S')

    sql = %{
      SELECT page_title, actor_name
      FROM page
      JOIN logging_logindex ON log_page = page_id
      JOIN actor_logging ON log_actor = actor_id
      WHERE log_type IN ('protect', 'stable')
      AND log_action IN ('protect', 'config')
      AND log_timestamp BETWEEN #{offset} AND SUBTIME(NOW(), '00:05')
      AND log_page > 0
      AND log_namespace = 0
      AND NOT EXISTS (
        SELECT 1
        FROM templatelinks
        WHERE tl_from = page_id
        AND tl_title IN (#{templates})
      )
      GROUP BY page_title
    }

    rows = @mb.repl_query(sql).to_a

    rows.each do |row|
      title = row['page_title'].force_encoding('utf-8')
      page_obj = get_protect_info(title)[0]

      # To guard against replication lag
      next unless get_protections(page_obj) || get_flags(page_obj)

      # Leave TFAs alone
      next if row['actor_name'] == 'TFA Protector Bot'

      edit_data = get_protection_by_type(page_obj, 'edit')
      move_data = get_protection_by_type(page_obj, 'move')
      pc_data = get_protection_by_type(page_obj, 'flagged')

      if edit_data
        if edit_data['expiry'] == 'infinity' && edit_data['level'] == 'autoconfirmed'
          template = 'pp-semi-indef'
        else
          template = 'pp'
        end
      elsif pc_data
        template = 'pp-pc'
      elsif move_data
        if move_data['expiry'] == 'infinity'
          template = 'pp-move-indef'
        else
          template = 'pp-move'
        end
      end

      content = @mb.get(title)

      next if has_redir_template?(page_obj, content)
      if page_obj.attributes['redirect']
        content = content.chomp('') + "\n\n{{#{template}|small=yes}}"
      else
        content = "{{#{template}|small=yes}}\n" + content
      end

      @mb.edit(title,
        content: content,
        summary: 'Adding missing protection template ([[User:MusikBot II/FixPP/FAQ|more info]])',
        minor: true
      )
    end

    @mb.local_storage('last_run' => (@mb.now - (5.0 / (24 * 60))).to_s)
  end

  def self.has_redir_template?(page_obj, content)
    if page_obj.attributes['redirect']
      redir_templates = (redir_hash.keys + redir_hash.values).uniq
        .map { |t| t.downcase }

      has_redir_template = false

      redir_templates.each do |redir_template|
        return true if content.downcase.include?(redir_template)
      end
    end

    false
  end

  def self.fix_pp
    get_category_members.each do |page|
      next if page =~ /\.(js|css|json)$/
      page_obj = get_protect_info(page).first

      if page_obj.elements['revisions'][0].attributes['user'] == 'MusikBot'
        log('MusikBot was last to edit page')
      else
        process_page(page_obj)
      end
    end
  end

  def self.process_page(page_obj, throttle = 0)
    @page_obj = page_obj
    @title = @page_obj.attributes['title']
    @content = @mb.get_page_props(@title)
    @edit_summaries = []
    @is_template = @page_obj.attributes['ns'].to_i == 10
    @is_talk_page = @page_obj.attributes['ns'].to_i.odd?

    # skip anything that may appear to automate usage of protection templates
    return if @content =~ /\{\{\s*PROTECTIONLEVEL/

    remove_pps_as_necessary

    # if nothing changed, cache page title and touched time into redis to prevent redundant processing
    return cache_touched(@page_obj, :set) unless @edit_summaries.present?

    if !protected?(@page_obj) && @mb.config[:run][:remove_all_if_expired]
      @edit_summaries = ['Removing protection templates from unprotected page']
    end

    @mb.edit(@title,
      content: @content,
      conflicts: true,
      summary: @edit_summaries.uniq.join(', ') + ' ([[User:MusikBot II/FixPP/FAQ|more info]])',
      minor: true
    )
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      process_page(@page_obj, throttle + 1)
    else
      raise e
    end
  end

  def self.remove_pps_as_necessary
    pp_hash.keys.each do |old_pp_type|
      raw_code = @content.scan(/\n?\{\{\s*(?:Template\:)?#{old_pp_type}\s*(?:\|.*?\}\}|\}\})\n?/i).first
      next unless raw_code.present?

      pp_type = pp_hash[old_pp_type]
      type = pp_protect_type[pp_type]
      expiry = get_expiry(@page_obj, type)

      # generic pp template is handled differently
      if pp_type.to_s == 'pp' && type.blank?
        # try  to figure out usage of generic {{pp}}
        type = raw_code.scan(/\{\{\s*pp\s*(?:\|.*?action\s*\=\s*(.*?)(?:\||\}\}))/i).flatten.first

        # if a type couldn't be parsed, assume it means edit-protection if it's pp-protected
        if type.blank?
          if old_pp_type == 'pp-protected' || !protected?(@page_obj) || get_protection_by_type(@page_obj, 'edit').nil?
            type = 'edit'
          else
            # auto generate template task is disabled, just skip and try to repair subsequent ones accordingly
            next
          end
        end

        expiry = get_expiry(@page_obj, type)
      end

      next unless expiry.nil? || (expiry != 'indefinite' && @mb.parse_date(expiry) < @mb.now)

      # check if there's corresponding protection for the pp template on page
      # API response could be cached (protect info still there but it's expired)
      human_type = type == 'flagged' ? 'pending changes' : type

      if @mb.config[:run][:remove_individual_if_expired]
        @edit_summaries << "removing {{#{old_pp_type}}} as page is not #{human_type}-protected"
        remove_pp(raw_code)
      end
    end
  end

  def self.remove_pp(code)
    if code =~ /^\n/
      code.sub!(/^\n/, '')
    elsif code.count("\n") > 1
      code.sub!(/\n$/, '')
    end
    if @content =~ /(?:\<noinclude\>\s*)#{Regexp.escape(code)}(?:\s*\<\/noinclude\>)/
      @content.sub!(/(?:\<noinclude\>\s*)#{Regexp.escape(code)}(?:\s*\<\/noinclude\>)/, '')
    else
      @content.sub!(code, '')
    end
  end

  def self.noinclude_pp(pps)
    has_doc = @content =~ /\{\{\s*(?:Template\:)?(?:#{doc_templates.join('|')})\s*\}\}/
    has_collapsible_option = @content =~ /\{\{\s*(?:Template\:)?(?:#{collapsible_option_templates.join('|')})\}\}/

    if (has_doc || has_collapsible_option) && @mb.config[:run][:remove_from_template_space_if_doc_present]
      @edit_summaries << 'Removing protection templates that are automatically generated by ' +
        (has_doc ? '{{documentation}}' : '{{collapsible option}}')
      return @content
    end

    return @content unless @mb.config[:run][:noinclude_in_template_space]

    @edit_summaries << 'Wrapping protection templates in <noinclude>'

    # FIXME: check to make sure it's not already in a noinclude and the bot just isn't able to figure out what to fix
    if @content.scan(/\A\<noinclude\>.*?\<\/noinclude\>/).any?
      @content.sub!(/\A\<noinclude\>/, "<noinclude>#{pps}")
    else
      "<noinclude>#{pps}</noinclude>\n" + @content
    end
  end

  def self.repair_pps
    new_pps = []
    needs_pp_added = false
    small_values = @mb.config[:config][:small_values].join('|')

    # find which templates they used and normalize them
    pp_hash.keys.each do |old_pp_type|
      raw_code = @content.scan(/\{\{\s*#{old_pp_type}\s*(?:\|.*?\}\}|\}\})/i).first
      next unless raw_code.present?

      opts = {
        raw_code: raw_code,
        pp_type: pp_type = pp_hash[old_pp_type],
        type: type = pp_protect_type[pp_type],
        expiry: get_expiry(@page_obj, type),
        small: raw_code =~ /\|\s*small\s*=\s*(?:#{small_values})\s*(?:\||}})/ ? true : false
      }

      # generic pp template is handled differently
      if opts[:pp_type] == 'pp' && opts[:type].blank?
        # try to figure out usage of generic {{pp}}
        opts[:type] = opts[:raw_code].scan(/\{\{\s*pp\s*(?:\|.*?action\s*\=\s*(.*?)(?:\||\}\}))/i).flatten.first

        # if a type couldn't be parsed, assume it means edit-protection if it's pp-protected,
        #   otherwise mark it as needing all templates to be added since they apparently have not done it incorrectly
        if opts[:type].blank?
          if old_pp_type == 'pp-protected'
            opts[:type] = 'edit'
          elsif @mb.config[:run][:auto_generate]
            @edit_summaries << 'repairing protection templates'
            needs_pp_added = true
            break
          else
            # auto generate template task is disabled, just skip and try to repair subsequent ones accordingly
            next
          end
        end

        # re-compute expiry
        opts[:expiry] = get_expiry(@page_obj, opts[:type])

        # reason (the 1= parameter) will be blp, dispute, sock, etc.
        reason = opts[:raw_code].scan(/\{\{pp\s*\|(?:(?:1\=)?(\w+(?=\||\}\}))|.*?\|1\=(\w+))/).flatten.compact.first

        if @mb.config[:run][:normalize_pp_template]
          # normalize to pp-reason if we're able to, otherwise use pp-protected
          opts[:pp_type] = normalize_pp(opts[:type], reason)
          @edit_summaries << 'normalizing {{pp}} template'
        end
      end

      # check if there's corresponding protection for the pp template on page
      # API response could be cached (protect info still there but it's expired)
      if opts[:expiry].nil? || (opts[:expiry] != 'indefinite' && @mb.parse_date(opts[:expiry]) < @mb.now)
        human_type = opts[:type] == 'flagged' ? 'pending changes' : opts[:type]

        if @mb.config[:run][:remove_individual_if_expired]
          @edit_summaries << "removing {{#{old_pp_type}}} as page is not #{human_type}-protected"
        end

        next
      end

      new_pps << build_pp_template(opts)
    end

    # check for auto_generate is in the loop above, duplicate as a safeguard
    if needs_pp_added && @mb.config[:run][:auto_generate]
      auto_pps
    else
      new_pps.join(@is_template ? '' : "\n")
    end
  end

  def self.normalize_pp(type, reason)
    # FIXME: add another conig represeting valid reasons
    if type == 'move'
      if %w(dispute vandalism).include?(reason)
        "pp-move-#{reason}"
      else
        'pp-move'
      end
    elsif type == 'autoreview'
      "pp-pc#{get_flags(@page_obj)['level'].to_i + 1}"
    elsif @mb.config[:config][:pp_reasons].include?(reason)
      "pp-#{reason}"
    else
      'pp'
    end
  end

  def self.get_expiry(page, type)
    protection_obj = get_protection_by_type(page, type)
    expiry_key = type == 'flagged' ? 'protection_expiry' : 'expiry'

    return nil unless protection_obj

    expiry = protection_obj[expiry_key]
    expiry == 'infinity' ? 'indefinite' : expiry
  end

  def self.auto_pps(existing_types = [])
    new_pps = ''
    (%w(edit move flagged) - existing_types).each do |type|
      settings = get_protection_by_type(@page_obj, type)
      next unless settings

      pp_type = if type == 'flagged'
                  "pp-pc#{settings['level'].to_i + 1}"
                elsif type == 'move'
                  'pp-move'
                elsif @is_template
                  'pp-template'
                else
                  'pp'
                end

      expiry_key = type == 'flagged' ? 'protection_expiry' : 'expiry'
      new_pps += build_pp_template(
        type: type,
        pp_type: pp_type,
        expiry: settings[expiry_key],
        small: true # just assume small=yes
      )
    end

    new_pps
  end

  def self.build_pp_template(opts)
    new_pp = '{{'

    if opts[:expiry] == 'indefinite' && opts[:type] != 'flagged'
      if opts[:type] == 'edit'
        opts[:pp_type] = 'pp-semi-indef'
      elsif opts[:type] == 'move'
        opts[:pp_type] = 'pp-move-indef'
      end
      new_pp += opts[:pp_type]
    else
      unless opts[:expiry] == 'indefinite'
        opts[:expiry] = DateTime.parse(opts[:expiry]).strftime('%H:%M, %-d %B %Y')
      end

      new_pp += "#{opts[:pp_type]}|expiry=#{opts[:expiry]}"
      new_pp += "|action=#{opts[:type]}" if opts[:pp_type] == 'pp'
    end

    "#{new_pp}#{'|small=yes' if opts[:small]}}}"
  end

  def self.doc_templates
    %w(documentation doc docs)
  end

  def self.collapsible_option_templates
    ['cop', 'collapsible', 'collapsible option', 'collapsible_option']
  end

  def self.remove_pps
    @content.gsub!(/(?:\<noinclude\>\s*)?\{\{\s*(?:Template\:)?(?:#{pp_hash.keys.flatten.join('|')}).*?\}\}(?:\s*\<\/noinclude\>)?/i, '')
    @content.gsub!(/\A\n*/, '')
  end

  def self.get_protections(page)
    page.elements['protection'].present? && page.elements['protection'][0].present? ? page.elements['protection'] : nil
  end

  def self.get_flags(page)
    page.elements['flagged'].present? ? page.elements['flagged'] : nil
  end

  def self.get_protection_by_type(page, type)
    if type == 'flagged'
      get_flags(page).attributes rescue nil
    else
      get_protections(page).select { |p| p.attributes['type'] == type }.first.attributes rescue nil
    end
  end

  def self.protected?(page)
    (get_protections(page) || get_flags(page)).present?
  end

  # protection types
  def self.pp_hash
    return @pp_hash if @pp_hash

    # cache on disk for one week
    @mb.disk_cache('pp_hash', 604_800) do
      @pp_hash = {}

      pp_types.each do |pp_type|
        redirects("Template:#{pp_type}").each do |r|
          @pp_hash[r.sub(/^Template:/, '').downcase] = pp_type
        end
      end

      @pp_hash
    end
  end

  # redirect shell types
  def self.redir_hash
    return @redir_hash if @redir_hash

    # cache on disk for one week
    @mb.disk_cache('redir_hash', 604_800) do
      @redir_hash = {}

      redirects("Template:Redirect category shell").each do |r|
        @redir_hash[r.sub(/^Template:/, '').downcase] = 'Redirect category shell'
      end

      @redir_hash
    end
  end

  def self.pp_protect_type
    @mb.config[:base_protection_templates]
  end

  def self.pp_types
    pp_protect_type.keys
  end

  # Redis
  def self.cache_touched(page, action)
    key = "mb-fixpp-#{page.attributes['pageid']}"

    if action == :set
      # FIXME: consider caching expiries, and check if current time is after them and reprocess page
      @mb.redis_client.set(key, page.attributes['touched'])
      @mb.redis_client.expire(key, 1800) # 30 minutes, was 3 hours = 10_800
    else
      ret = @mb.redis_client.get(key)
      # ret.nil? ? @mb.now - 9999 : @mb.parse_date(ret)
      @mb.parse_date(ret)
    end
  end

  # API-related
  def self.get_protect_info(page)
    @mb.gateway.custom_query(
      prop: 'info|flagged|revisions',
      inprop: 'protection',
      rvprop: 'user',
      rvlimit: 1,
      titles: page
    ).elements['pages']
  end

  def self.get_category_members
    return @category_members if @category_members
    @mb.gateway.purge(CATEGORY)
    @category_members = @mb.gateway.custom_query(
      list: 'categorymembers',
      cmtitle: CATEGORY,
      cmlimit: 5000,
      cmprop: 'title',
      cmtype: 'page'
    ).elements['categorymembers'].map { |cm| cm.attributes['title'] }
  end

  def self.redirects(title)
    ret = @mb.gateway.custom_query(
      prop: 'redirects',
      titles: title
    ).elements['pages'][0].elements['redirects']
    [title] + (ret ? ret.map { |r| r.attributes['title'] } : [])
  end

  def self.log(message)
    puts(@mb.now.strftime("%e %b %H:%M:%S | #{message}"))
  end
end

FixPP.run
