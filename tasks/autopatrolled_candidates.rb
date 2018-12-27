$LOAD_PATH << '..'
require 'musikbot'

MIN_ARTICLE_COUNT = 25
MAINTENANCE_CATEGORIES = [
  'All_articles_lacking_sources',
  'All_articles_needing_additional_references',
  'All_unreferenced_BLPs',
  'All_BLP_articles_lacking_sources',
  'All_articles_lacking_reliable_references',
  'All_articles_with_a_promotional_tone',
  'All_articles_with_topics_of_unclear_notability'
]
REPORT_PAGE = 'Wikipedia:Database reports/Editors eligible for Autopatrol privilege'

module AutopatrolledCandidates
  def self.run
    @mb = MusikBot::Session.new(inspect)

    users = {}

    page_creators.each_with_index do |user, i|
      username = user['user_name']

      # not sure how this happens
      next if username.nil?

      articles = articles_created(username)

      # Skip if they don't meet article count prerequisite or recently had a PERM request declined
      next if articles.length < MIN_ARTICLE_COUNT || perm_request_declined?(username)

      user_data = {
        created: articles.length,
        edits: user['user_editcount'],
        deleted: deleted_counts(username),
        blocks: block_count(username),
        tagged: maintenance_count(articles),
        perm_revoked: autopatrolled_revoked?(username),
        copyvios: scan_talk_page(username)
      }

      users[username] = user_data

      puts "#{i} of #{page_creators.length}: #{username} = #{articles.length}"
    end

    generate_report(users)
  end

  # Generate markup for the report and write it to REPORT_PAGE
  def self.generate_report(users)
    cat_str = MAINTENANCE_CATEGORIES.collect { |c| "[[:Category:#{c}|#{c.descore}]]" }.join(', ')

    markup = <<~END
      <div style='font-size:24px'>Users eligible to be autopatrolled as of #{I18n.l(@mb.today, format: :heading)}</div>
      {{FORMATNUM:#{users.length}}} users who have created an article in the past month, and may be eligible for the autopatrolled privilege but don't have it yet.

      Users who had a [[WP:PERM/A|request for autopatrolled]] declined in the past 90 days are not listed.

      Prepared by ~~~ <onlyinclude>~~~~~</onlyinclude>

      == Key ==
      * '''Articles''': Number of live, non-redirect articles
      * '''Tagged''': Number of articles with maintenance tags<ref name=tags />
      * '''Deleted''': Number of deleted articles in the past year (may include redirects)<ref name='deleted' />
      * '''Edit count''': Raw edit count of the user
      * '''Blocks''': Number of blocks in the past year
      * '''Copyvios''': Number of ''possible'' user talk notifications about copyright concerns in the past year<ref name='copyvios' />
      * '''Revoked?''': Whether or not the autopatrolled permission was previously revoked
      {{pb}}
      ;Notes
      {{reflist|refs="
      <ref name='tags'>Supported maintenance categories include: #{cat_str}</ref>
      <ref name='deleted'>[[WP:G6|G6]] (technical) and [[WP:G7|G7]] (user-requested) speedy deletions are not included. The number of speedy, (BLP)PROD and AfD deletions are shown if detected via the deletion summary.</ref>
      <ref name='copyvios'>This works by scanning the edit summaries for "copyvios" or "copyright". Links are provided to the diffs, which may include removal of notices.</ref>
      }}

      == Report ==
      {| class='wikitable sortable'
      ! Username
      ! Articles
      ! Tagged
      ! Deleted
      ! Edit count
      ! Blocks
      ! Copyvios
      ! Revoked?
      ! class="unsortable" | Links
      |-
    END

    # Sort by number of articles created
    users = users.sort_by { |username, data| -data[:created] }.to_h

    users.each do |username, data|
      user_rights_log = "https://en.wikipedia.org/w/index.php?title=Special:Log&page=User:#{username.score}&type=rights"
      block_log = "https://en.wikipedia.org/w/index.php?title=Special:Log&action=view&page=#{username.score}&type=block"
      xtools_link = "[https://tools.wmflabs.org/xtools/pages/?user=#{URI.escape(username)}" \
        "&project=en.wikipedia.org&namespace=0&redirects=noredirects {{FORMATNUM:#{data[:created]}}}]"

      deleted_str = '0'

      # Generate string that lists the different types of deletions that were detected
      if data[:deleted][:total] > 0
        deleted_str = "#{data[:deleted][:total]} total"
        deletion_stats = []

        [:Speedy, :PROD, :AfD].each do |type|
          if data[:deleted][type] > 0
            deletion_stats << "#{type}: {{FORMATNUM:#{data[:deleted][type]}}}"
          end
        end
        deleted_str += " (#{deletion_stats.join(', ')})".chomp('()')
      end

      block_str = data[:blocks] > 0 ? "[#{block_log} {{FORMATNUM:#{data[:blocks]}}}]" : '0'

      copyvios_str = 0
      if data[:copyvios].any?
        copyvios_str = "#{data[:copyvios].length}<ref>"
        data[:copyvios].each do |rev_id|
          copyvios_str += "[https://en.wikipedia.org/wiki/Special:Diff/#{rev_id}]"
        end
        copyvios_str += "</ref>"
      end

      revoked_str = data[:perm_revoked] ? "[#{user_rights_log} Yes]" : 'No'

      links = [
        "[[Special:UserRights/#{username}|User rights]]",
        "[https://tools.wmflabs.org/xtools-ec/?user=#{URI.encode(username)}&project=en.wikipedia.org EC]",
        "[https://tools.wmflabs.org/musikanimal/blp_edits?username=#{URI.encode(username)}&offset=0&contribs=on BLP edits]"
      ].join(' &middot; ')

      markup += <<~END
        | {{User0|#{username}}}
        | #{xtools_link}
        | {{FORMATNUM:#{data[:tagged]}}}
        | data-sort-value=#{data[:deleted][:total]} | #{deleted_str}
        | [[Special:Contributions/#{username}|{{FORMATNUM:#{data[:edits]}}}]]
        | #{block_str}
        | data-sort-value=#{data[:copyvios].length} | #{copyvios_str}
        | #{revoked_str}
        | #{links}
        |-
      END
    end

    markup = markup.chomp("\n|-") + <<~END
      |}

      ;Links
      {{reflist}}
    END

    @mb.edit(REPORT_PAGE,
      content: markup,
      summary: "Reporting #{users.length} users eligible for autopatrolled"
    )
  end

  # Scan talk page history for messages that are potentially about copyvios
  def self.scan_talk_page(username)
    sql = %{
      SELECT rev_id
      FROM revision_userindex
      WHERE rev_page = (
        SELECT page_id
        FROM page
        WHERE page_title = ?
        AND page_namespace = 3
      )
      AND rev_timestamp > #{@mb.db_date(@mb.today - 365)}
      AND rev_comment REGEXP "[Cc]opy(right|vio)"
    }
    @mb.repl_query(sql, username.score).to_a.collect { |r| r['rev_id'] }
  end

  # Get data about pages the user created that were deleted
  # Returns:
  # {
  #   total: total number of articles deleted
  #   Speedy: total number of articles deleted under [[WP:CSD]]
  #   PROD: total number of articles deleted under [[WP:PROD]] or [[WP:BLPPROD]]
  #   AfD: total number of articles deleted under [[WP:AfD]]
  # }
  def self.deleted_counts(username)
    sql = %{
      SELECT log_comment
      FROM logging_logindex
      LEFT JOIN archive_userindex ON ar_page_id = log_page
      WHERE log_type = 'delete'
      AND ar_user_text = ?
      AND ar_namespace = 0
      AND ar_parent_id = 0
      AND ar_timestamp > #{@mb.db_date(@mb.now - 365)}
    }

    counts = {
      total: 0,
      Speedy: 0,
      PROD: 0,
      AfD: 0
    }

    @mb.repl_query(sql, username.score).to_a.each do |data|
      # don't count technical or user-requested deletions
      next if data['log_comment'] =~ /\[\[WP:CSD#G(6|7)\|/

      counts[:total] += 1

      case data['log_comment']
      when /\[\[WP:CSD#/
        counts[:Speedy] += 1
      when /\[\[WP:(BLP)?PROD/
        counts[:PROD] += 1
      when /\[\[(Wikipedia|WP):Articles for deletion\//
        counts[:AfD] += 1
      end
    end

    counts
  end

  # Get the number of blocks the user had in the past year
  def self.block_count(username)
    sql = %{
      SELECT COUNT(*) AS count
      FROM logging_logindex
      WHERE log_type = 'block'
      AND log_title = ?
      AND log_timestamp > #{@mb.db_date(@mb.now - 365)}
    }
    @mb.repl_query(sql, username.score).to_a.first['count']
  end

  # Check if the user has had the autopatrolled permission revoked in the past
  def self.autopatrolled_revoked?(username)
    sql = %{
      SELECT COUNT(*) AS count
      FROM logging_logindex
      WHERE log_type = 'rights'
      AND log_title = ?
      AND log_params REGEXP "oldgroups.*?autoreviewer.*?newgroups(?!.*?autoreviewer)"
    }
    @mb.repl_query(sql, username.score).to_a.first['count'] > 0
  end

  # Get the page title, ID and creation date of articles created by the given user
  def self.articles_created(username)
    sql = %{
      SELECT page_title, page_id, rev_timestamp
      FROM revision_userindex
      LEFT JOIN page ON page_id = rev_page
      WHERE page_namespace = 0
      AND rev_parent_id = 0
      AND rev_user_text = ?
      AND rev_deleted = 0
      AND page_is_redirect = 0
    }
    @mb.repl_query(sql, username.score).to_a
  end

  # Get the number of articles created by the user that are in maintenance categories
  def self.maintenance_count(articles)
    # Create list of categories to be used in the `cl_to IN ()` clause
    categories_sql = MAINTENANCE_CATEGORIES.collect { |c| "'#{c}'" }.join(',')

    # Create list of article IDs to be used in the `cl_from IN ()` clause
    article_ids = articles
      .select { |a| @mb.parse_date(a['rev_timestamp']) > @mb.now - 365 }
      .collect { |a| a['page_id'] }

    sql = %{
      SELECT COUNT(DISTINCT(cl_from)) AS count
      FROM categorylinks
      WHERE cl_from IN (#{article_ids.join(',')})
      AND cl_to IN (#{categories_sql})
      AND cl_type = 'page'
    }
    @mb.repl.query(sql).to_a.first['count']
  end

  def self.perm_request_declined?(username)
    target_date = @mb.today - 90
    links = []
    dates_to_fetch = (target_date..@mb.today).select { |d| d.day == target_date.day || d.day == @mb.today.day }.uniq(&:month)

    dates_to_fetch.each do |date|
      key = "#{Date::MONTHNAMES[date.month]} #{date.year}"
      page = @mb.get("Wikipedia:Requests for permissions/Denied/#{key}")

      next unless page

      # Regexp.escape may break with other encodings
      username = username.force_encoding('utf-8')

      decline_days = page.split(/==\s*\w+\s+/i)
      decline_days.each do |decline_day|
        day_number = decline_day.scan(/^(\d+)\s*==/).flatten[0].to_i
        next if day_number == 0
        decline_day_date = @mb.parse_date("#{date.year}-#{date.month}-#{day_number}")
        matches = decline_day.scan(/\{\{Usercheck.*\|#{Regexp.escape(username).descore}}}.*Autopatrolled\]\]/i)[0]

        return true if matches && decline_day_date >= target_date
      end
    end

    false
  end

  # Get the usernames and edit counts of users who have created a page in the past month
  def self.page_creators
    # Cache so this can be re-called without repeating the query
    return @page_creators if @page_creators

    sql = %{
      SELECT DISTINCT(user_name), user_editcount
      FROM recentchanges
      LEFT JOIN user
      ON rc_user = user_id
      LEFT JOIN page
      ON rc_cur_id = page_id
      WHERE
          rc_timestamp > #{@mb.db_date(@mb.now - 3)} AND
          rc_namespace = 0 AND
          rc_bot = 0 AND
          rc_new = 1 AND
          page_is_redirect = 0 AND
          NOT EXISTS
          (
            SELECT 1
            FROM user_groups
            WHERE ug_user = user_id
            AND ( ug_group = 'autoreviewer' OR ug_group = 'sysop' )
          )
    }
    @page_creators = @mb.repl_query(sql).to_a
  end
end

AutopatrolledCandidates.run
