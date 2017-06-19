$LOAD_PATH << '..'
require 'musikbot'

REPORT_PAGE = 'User:MusikBot/TopPageReviewers/Report'

module TopPageReviewers
  def self.run
    @mb = MusikBot::Session.new(inspect, true)

    markup = <<~END
      {{TOC right}}
      <div style='font-size:24px'>Top new page reviewers as of ~~~~~</div>

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

    @mb.edit(REPORT_PAGE,
      content: markup,
      summary: "Reporting top new page reviewers"
    )
  end

  def self.report_block(offset)
    markup = <<~END
      {| class='wikitable sortable'
      ! Username
      ! Num reviews
      |-
    END

    top_reviewers(offset).each do |data|
      markup += <<~END
        | {{User0|#{data['reviewer']}}}
        | {{FORMATNUM:#{data['reviews']}}}
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
      SELECT log_user_text AS `reviewer`,
             COUNT(log_id) AS `reviews`
      FROM logging
      WHERE log_timestamp BETWEEN #{start_time} AND #{end_time}
      AND log_namespace = 0
      AND (
        (
          log_type = 'patrol'
          AND log_params NOT LIKE '%::auto";i:1%'
        ) OR (
          log_type = 'pagetriage-curation'
          AND log_action = 'reviewed'
        )
      )
      GROUP BY reviewer
      ORDER BY reviews DESC;
    }
    @top_reviewers ||= {}
    @top_reviewers[offset] = @mb.repl.query(sql).to_a
  end
end

TopPageReviewers.run
