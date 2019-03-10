$LOAD_PATH << '..'
require 'musikbot'

module TemplateProtector
  PROTECTION_WEIGHT = {
    :sysop => 40,
    :templateeditor => 30,
    :extendedconfirmed => 20,
    :autoconfirmed => 10
  }

  def self.run
    @mb = MusikBot::Session.new(inspect)

    @thresholds = @mb.config[:thresholds]
      .select {|_k, v| v.present?}  # Non-nil.
      .sort_by(&:last)              # Sort by transclusion count.
      .reverse
      .to_h

    # Exclusions as strings with underscores instead of spaces.
    exclusions = @mb.config[:exclusions].keys.map(&:to_s).map(&:score)

    # Minimum transclusion count to check for.
    lowest_threshold = @thresholds.values.min

    @mb.config[:namespaces].each do |ns_id|
      # Mainspace is not supported (nor should it be).
      next if ns_id == 0

      ns_name = namespace_map[ns_id]

      fetch_templates(ns_id, lowest_threshold).each do |row|
        row['title'] = row['title'].force_encoding('utf-8')
        title = "#{ns_name}:#{row['title']}"
        edit_level = prot_level(row['count'])

        # Skip if excluded.
        if exclusions.include?(title)
          puts ">> #{title} excluded"
          next
        end

        # Skip if matches regex exclusions.
        if regex_excluded?(title)
          puts ">> #{title} regex-excluded"
          next
        end

        # Skip if recently protected.
        if recently_protected?(ns_id, row['title'])
          puts ">> #{title} recently protected"
          next
        end

        # Skip if title is blacklisted.
        if title_blacklisted?(title, edit_level)
          puts ">> #{title} already blacklisted"
          next
        end

        old_move_level = get_move_level(row['id'])

        # Use the same as edit_level for move, unless it is higher than the edit_level.
        move_level = PROTECTION_WEIGHT[old_move_level].to_i > PROTECTION_WEIGHT[edit_level] ? old_move_level : edit_level

        puts "PROTECT: #{edit_level}/#{move_level} ~ #{title} ~ #{row['count']}"

        # Protect!
        unless @mb.opts[:dry]
          protections = [{action: 'edit', group: edit_level}]

          if move_level != :autoconfirmed
            protections << {
                action: 'move',
                group: move_level
            }
          end

          @mb.gateway.protect(title, protections, { reason: @mb.config[:summary] })
        end
      end
    end
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.fetch_templates(ns, threshold)
    sql = %{
      SELECT page_title AS title, page_id AS id, COUNT(*) AS count
      FROM page
      JOIN templatelinks ON page_title = tl_title
        AND page_namespace = tl_namespace
      LEFT JOIN page_restrictions ON pr_page = page_id
        AND pr_level IN ('autoconfirmed', 'templateeditor', 'extendedconfirmed', 'sysop')
        AND pr_type = 'edit'
      WHERE tl_namespace = ?
        AND pr_page IS NULL
      GROUP BY page_title
      HAVING COUNT(*) >= ?
    }
    @mb.repl_query(sql, ns, threshold).to_a
  end

  def self.recently_protected?(ns, title)
    sql = %{
      SELECT 1
      FROM logging_logindex
      WHERE log_namespace = ?
      AND log_title = ?
      AND log_action IN ('protect', 'unprotect')
      AND log_timestamp > DATE_SUB(NOW(), INTERVAL ? DAY)
      LIMIT 1
    }
    @mb.repl_query(sql, ns, title, @mb.config[:ignore_offset]).any?
  end

  def self.title_blacklisted?(title, level)
    # Needs to be done while logged out.
    ret = @mb.http_get(
      "https://#{@mb.opts[:project]}.org/w/api.php?action=titleblacklist&tbtitle=#{URI.escape(title)}&tbaction=edit&format=json"
    )

    # A page is considered blacklisted only if the noedit level matches the one we want to apply.
    ret['titleblacklist']['result'] == 'blacklisted' && ret['titleblacklist']['line'] =~ /noedit.*?#{level}/
  end

  def self.regex_excluded?(title)
    unless @title_regex
      regexes = []
      @mb.config[:regex_exclusions].keys.each do |regex|
        regexes << Regexp.new(regex.to_s)
      end
      @title_regex = Regexp.union(regexes)
    end

    !!@title_regex.match(title.descore)
  rescue => e
    @mb.report_error('Regex error', e)
  end

  def self.prot_level(count)
    @thresholds.each do |level, threshold|
      return level if count >= threshold
    end
  end

  def self.get_move_level(page_id)
    sql = %{
      SELECT pr_level
      FROM page_restrictions
      WHERE pr_page = ?
      AND pr_type = 'move'
    }
    ret = @mb.repl_query(sql, page_id).to_a
    ret.any? ? ret[0]['pr_level'].to_sym : nil
  end

  def self.namespace_map
    return @namespace_map if @namespace_map

    api_obj = @mb.gateway.custom_query(
      meta: 'siteinfo',
      siprop: 'namespaces'
    )

    ns_map = {}

    api_obj.elements['namespaces'].each do |element|
      ns_map[element.attributes['id'].to_i] = element[0]
    end

    @namespace_map = ns_map
  end
end

TemplateProtector.run
