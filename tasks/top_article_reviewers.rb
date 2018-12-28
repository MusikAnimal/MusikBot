$LOAD_PATH << '..'
require 'musikbot'

REPORT_PAGE = 'Wikipedia:Database reports/Top new article reviewers'

module TopArticleReviewers
  def self.run
    @mb = MusikBot::Session.new(inspect)

    markup = <<~END
      {{TOC right}}
      <div style='font-size:24px'>Top new article reviewers as of ~~~~~</div>

      Only reviews of mainspace pages are counted. Limited to the top 100 reviewers for each time period.

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
      ! Num reviews
      ! Log
      |-
    END

    top_reviewers(offset).each_with_index do |data, i|
      patrol_log_link = "https://en.wikipedia.org/w/index.php?title=Special:Log" \
        "&type=patrol&subtype=patrol&user=#{data['reviewer'].score}"
      pagetriage_log_link = "https://en.wikipedia.org/w/index.php?title=Special:Log" \
        "&type=pagetriage-curation&user=#{data['reviewer'].score}"

      markup += <<~END
        | #{i + 1}
        | {{User0|#{data['reviewer']}}}
        | data-sort-value=#{data['reviewer']} | {{FORMATNUM:#{data['reviews']}}}
        | [#{patrol_log_link} Patrol] [#{pagetriage_log_link} Page Curation]
        |-
      END
    end

    markup.chomp("\n|-") + "|}\n"
  end

  # Get the top reviewers in the past N days (specified by offset)
  def self.top_reviewers(offset = 1)
    # Cache so this can be re-called without repeating the query
    return @top_reviewers[offset] if @top_reviewers && @top_reviewers[offset]

    start_time = (@mb.now - offset).strftime('%Y%m%d%H%M%S')
    end_time = @mb.now.strftime('%Y%m%d%H%M%S')

    sql = %{
      SELECT logtemp.log_user_text AS `reviewer`,
      COUNT(DISTINCT(logtemp.log_page)) AS `reviews`
      FROM (
        SELECT log_user_text, log_page
        FROM logging_userindex
        WHERE log_timestamp BETWEEN #{start_time} AND #{end_time}
        AND log_type = 'patrol'
        AND log_action = 'patrol'
        AND log_namespace = 0
        UNION
        SELECT log_user_text, log_page
        FROM logging_userindex
        WHERE log_timestamp BETWEEN #{start_time} AND #{end_time}
        AND log_type = 'pagetriage-curation'
        AND log_action = 'reviewed'
        AND log_namespace = 0
      ) logtemp
      GROUP BY reviewer
      ORDER BY reviews DESC
      LIMIT 100;
    }
    @top_reviewers ||= {}
    @top_reviewers[offset] = @mb.repl.query(sql).to_a
  end
end

TopArticleReviewers.run
