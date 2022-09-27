$LOAD_PATH << '..'
require 'musikbot'

REPORT_PAGE = 'Wikipedia:Database reports/Top new article reviewers'

module TopArticleReviewers
  def self.run
    @mb = MusikBot::Session.new(inspect)

    markup = <<~END
      {{TOC right}}
      <div style='font-size:24px'>Top new article reviewers as of ~~~~~</div>

      Please note the following:
      * Only reviews of mainspace pages are counted.
      * The report is limited to the top 100 reviewers for each time period.
      * The '''Totals''' row refers to totals across all users, not just the top 100 shown in this report.
      * Due to technical restrictions, '''Redirects''' refer to the ''current'' redirect status of the page, not the status of when the review was made.

      Prepared by ~~~ <onlyinclude>~~~~~</onlyinclude>

      == Last 24 hours ==
    END

    # Last day
    markup += report_block(1)

    # Last week
    markup += "\n== Last 7 days ==\n"
    markup += report_block(7)

    # Last month
    markup += "\n== Last 30 days ==\n"
    markup += report_block(30)

    # Last 3 months
    markup += "\n== Last 90 days ==\n"
    markup += report_block(90)

    # Last year
    markup += "\n== Last 365 days ==\n"
    markup += report_block(365)

    @mb.edit(REPORT_PAGE,
      content: markup,
      summary: "Reporting top new article reviewers"
    )
  end

  def self.report_block(offset)
    puts "Getting top reviewers for the past #{offset} days..."
    markup = <<~END
      {| class='wikitable sortable'
      ! Rank
      ! Username
      ! Articles
      ! Redirects
      ! Total
      ! Log
      |-
    END

    # Keep track of subtotals
    subtotals = {
      reviewers: 0,
      articles: 0,
      redirects: 0,
      total: 0
    }

    get_top_reviewers(offset).each_with_index do |data, i|
      patrol_log_link = "https://en.wikipedia.org/w/index.php?title=Special:Log" \
        "&type=patrol&subtype=patrol&user=#{data['reviewer'].score}"
      pagetriage_log_link = "https://en.wikipedia.org/w/index.php?title=Special:Log" \
        "&type=pagetriage-curation&user=#{data['reviewer'].score}"

      subtotals[:reviewers] += 1
      subtotals[:total] += data['total']
      subtotals[:articles] += data['articles']
      subtotals[:redirects] += data['redirects']

      markup += <<~END
        | #{i + 1}
        | {{User0|#{data['reviewer']}}}
        | {{FORMATNUM:#{data['articles']}}}
        | {{FORMATNUM:#{data['redirects']}}}
        | {{FORMATNUM:#{data['total']}}}
        | [#{patrol_log_link} Patrol] [#{pagetriage_log_link} Page Curation]
        |-
      END
    end

    # Add subtotals
    markup += <<~END
      ! Subtotals
      ! style="text-align:left" | {{FORMATNUM:#{subtotals[:reviewers]}}} reviewers
      ! style="text-align:left" | {{FORMATNUM:#{subtotals[:articles]}}}
      ! style="text-align:left" | {{FORMATNUM:#{subtotals[:redirects]}}}
      ! style="text-align:left" | {{FORMATNUM:#{subtotals[:total]}}}
      !
      |-
    END

    unless subtotals[:reviewers] < 100
      # Add remainders
      markup += <<~END
        ! Remaining
        ! style="text-align:left" | {{FORMATNUM:#{@totals[offset]['reviewers'] - subtotals[:reviewers]}}} reviewers
        ! style="text-align:left" | {{FORMATNUM:#{@totals[offset]['articles'] - subtotals[:articles]}}}
        ! style="text-align:left" | {{FORMATNUM:#{@totals[offset]['redirects'] - subtotals[:redirects]}}}
        ! style="text-align:left" | {{FORMATNUM:#{@totals[offset]['total'] - subtotals[:total]}}}
        !
        |-
      END
    end

    # Add totals
    markup += <<~END
      ! Totals
      ! style="text-align:left" | {{FORMATNUM:#{@totals[offset]['reviewers']}}} reviewers
      ! style="text-align:left" | {{FORMATNUM:#{@totals[offset]['articles']}}}
      ! style="text-align:left" | {{FORMATNUM:#{@totals[offset]['redirects']}}}
      ! style="text-align:left" | {{FORMATNUM:#{@totals[offset]['total']}}}
      !
    END

    markup + "|}\n"
  end

  # Get the top reviewers in the past N days (specified by offset)
  def self.get_top_reviewers(offset = 1)
    # Cache so this can be re-called without repeating the query
    return @top_reviewers[offset] if @top_reviewers && @top_reviewers[offset]

    start_time = get_start_time(offset)
    end_time = get_end_time(offset)

    # First fetch and cache the totals
    @totals ||= {}
    @totals[offset] = fetch_totals(start_time, end_time)

    # Cache and return the list of top users
    @top_reviewers ||= {}
    @top_reviewers[offset] = fetch_top_reviewers(start_time, end_time)
  end

  # Run the actual query, summing the number of reviews that are redirects.
  def self.fetch_top_reviewers(start_time, end_time)
    sql = %{
      SELECT actor_name AS `reviewer`,
        COUNT(DISTINCT(logtemp.log_page)) AS `total`,
        COUNT(IF(logtemp.page_is_redirect = 1, 1, NULL)) as `redirects`,
        COUNT(IF(logtemp.page_is_redirect = 0, 1, NULL)) as `articles`
      FROM (
        SELECT log_actor, log_page, page_is_redirect
        FROM logging_userindex
        JOIN page ON page_title = log_title AND page_namespace = log_namespace
        WHERE log_timestamp BETWEEN ? AND ?
        AND log_type = 'patrol'
        AND log_action = 'patrol'
        AND log_namespace = 0
        UNION
        SELECT log_actor, log_page, page_is_redirect
        FROM logging_userindex
        JOIN page ON page_title = log_title AND page_namespace = log_namespace
        WHERE log_timestamp BETWEEN ? AND ?
        AND log_type = 'pagetriage-curation'
        AND log_action = 'reviewed'
        AND log_namespace = 0
      ) logtemp
      JOIN actor ON actor_id = log_actor
      GROUP BY reviewer
      ORDER BY articles DESC
      LIMIT 100;
    }
    @mb.repl_query(sql, start_time, end_time, start_time, end_time).to_a
  end

  def self.fetch_totals(start_time, end_time)
    sql = %{
      SELECT COUNT(DISTINCT log_actor) AS `reviewers`,
        COUNT(*) AS `total`,
        COUNT(IF(logtemp.page_is_redirect = 1, 1, NULL)) as `redirects`,
        COUNT(IF(logtemp.page_is_redirect = 0, 1, NULL)) as `articles`
      FROM (
        SELECT DISTINCT log_actor, log_page, page_is_redirect
        FROM logging_userindex
          JOIN page ON page_title = log_title AND page_namespace = log_namespace
        WHERE log_timestamp BETWEEN ? AND ?
          AND 
          ((log_type = 'patrol'  AND log_action = 'patrol') OR
           (log_type = 'pagetriage-curation' AND log_action = 'reviewed'))
          AND log_namespace = 0
      ) logtemp
    }
    @mb.repl_query(sql, start_time, end_time).to_a.first
  end

  def self.get_start_time(offset)
    # Return cached start time if it exists, to ensure all queries have the exact same date
    return @start_time[offset] if @start_time && @start_time[offset]
    @start_time ||= {}
    @start_time[offset] = (@mb.now - offset).strftime('%Y%m%d%H%M%S')
  end

  def self.get_end_time(offset)
    return @end_time[offset] if @end_time && @end_time[offset]
    @end_time ||= {}
    @end_time[offset] = @mb.now.strftime('%Y%m%d%H%M%S')
  end
end

TopArticleReviewers.run
