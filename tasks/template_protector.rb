$LOAD_PATH << '..'
require 'musikbot'

module TemplateProtector
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
        title = "#{ns_name}:#{row['title']}"

        # Skip if excluded.
        if exclusions.include?(title)
          puts ">> #{title} excluded"
          next
        end

        # Skip if title is blacklisted.
        if title_blacklisted?(title)
          puts ">> #{title} already blacklisted"
          next
        end

        # Skip if recently protected.
        if recently_protected?(ns_id, row['title'])
          puts ">> #{title} recently protected"
          next
        end

        puts "#{prot_level(row['count'])} ~ #{title} ~ #{row['count']}"
        # Protect!
        # @mb.gateway.protect(
        #   title,
        #   {
        #     action: 'edit',
        #     protections: prot_level(row['count'])
        #   }, {
        #     reason: @mb.config[:summary]
        #   }
        # )
      end
    end
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.fetch_templates(ns, threshold)
    sql = %{
      SELECT DISTINCT(page_title) AS title, COUNT(*) AS count
      FROM page
      JOIN templatelinks ON page_title = tl_title
        AND page_namespace = tl_namespace
      LEFT JOIN page_restrictions ON pr_page = page_id
        AND pr_level IN ('autoconfirmed', 'templateeditor', 'extendedconfirmed', 'sysop')
        AND pr_type = 'edit'
      WHERE tl_namespace = #{ns}
        AND pr_page IS NULL
      GROUP BY tl_title
      HAVING COUNT(*) >= #{threshold}
      ORDER BY COUNT(*) DESC
    }
    @mb.repl.query(sql).to_a
  end

  def self.recently_protected?(ns, title)
    sql = %{
      SELECT 1
      FROM logging_logindex
      WHERE log_namespace = #{ns}
      AND log_title = ?
      AND log_action = 'protect'
      AND log_timestamp > DATE_SUB(NOW(), INTERVAL #{@mb.config[:ignore_offset]} DAY)
    }
    @mb.repl_query(sql, title).any?
  end

  def self.title_blacklisted?(title)
    # Needs to be done while logged out.
    ret = @mb.http_get(
      "https://#{@mb.opts[:project]}.org/w/api.php?action=titleblacklist&tbtitle=#{title}&tbaction=edit&format=json"
    )

    ret['titleblacklist']['result'] == 'blacklisted'
  end

  def self.prot_level(count)
    @thresholds.each do |level, threshold|
      return level if count > threshold
    end
  end

  def self.namespace_map
    return @namespace_map if @namespace_map

    api_obj = @mb.gateway.custom_query(
      meta: 'siteinfo',
      siprop: 'namespaces',
      formatversion: 2
    )

    ns_map = {}

    api_obj.elements['namespaces'].each do |element|
      ns_map[element['id'].to_i] = element[0]
    end

    @namespace_map = ns_map
  end
end

TemplateProtector.run
