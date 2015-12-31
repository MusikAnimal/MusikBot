$LOAD_PATH << '.'
require 'musikbot'

module StaleFilters
  def self.run
    @mb = MusikBot::Session.new(inspect, true)

    @report_page = 'User:MusikBot/StaleFilters/Report'
    @total_page = 'User:MusikBot/StaleFilters/Total'
    @offset_page = 'User:MusikBot/StaleFilters/Offset'

    generate_report
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.generate_report
    extended_content = "<div style='font-size:24px'>Stale [[WP:FILTER|edit filters]] as of #{@mb.today.strftime('%-d %B %Y')}</div>\n" \
      "#{stale_filters.length} enabled filters with no hits in #{offset} days\n\n" \
      "{| class='wikitable sortable'\n! Filter\n! Description\n! Last hit\n! Last filter author\n! Last filter edit\n! Private\n! Actions\n|-\n"

    stale_filters.each do |filter|
      puts "#{index} of #{stale_filters.length}: #{title}" if @env == :test

      extended_content += "| [[Special:AbuseFilter/#{filter['af_id']}|#{filter['af_id']}]] \n| #{filter['af_public_comments']}\n" \
        "| {{plain link|url=#{log(filter['af_id'])}|name=#{fdate(filter['afl_timestamp'])}}}\n" \
        "| [[User:#{filter['af_user_text']}|#{filter['af_user_text']}]]\n| [[#{history(filter['af_id'])}|#{fdate(filter['af_timestamp'])}]]\n" \
        "| #{filter['af_hidden'] == 1 ? 'yes' : 'no'}\n| #{filter['af_actions']}\n|-\n"
    end

    extended_content = extended_content.chomp("|-\n") + "|}\n\n"

    summary = "Reporting #{stale_filters.length} stale filters"

    @mb.edit(@report_page,
      content: extended_content,
      summary: summary,
      bot: false
    )

    @mb.edit(@total_page,
      content: stale_filters.length,
      summary: summary
    )
  end

  # FIXME: use https://github.com/michaelfairley/method_decorators !!!!
  def self.stale_filters
    return @stale_filters if @stale_filters

    query = 'SELECT af_id, af_user_text, afl.afl_timestamp, af_timestamp, af_public_comments, af_hidden, af_actions ' \
      'FROM enwiki_p.abuse_filter af INNER JOIN (SELECT afl_id, afl_filter, MAX(afl_timestamp) afl_timestamp ' \
      'FROM enwiki_p.abuse_filter_log GROUP BY afl_filter) afl ON afl.afl_filter = af_id ' \
      "WHERE af_enabled = 1 AND af_deleted = 0 AND afl.afl_timestamp < #{offset_date};"

    @stale_filters = @mb.repl_client.query(query).to_a
  end

  def self.offset
    @offset ||= @mb.get(@offset_page).to_i
  end

  # Helpers
  def self.offset_date
    @mb.db_date(@mb.today - offset)
  end

  def self.fdate(date)
    @mb.parse_date(date).strftime('%Y-%m-%d %H:%M')
  end

  def self.log_entry(id)
    "Special:AbuseLog/#{id}"
  end

  def self.history(id)
    "Special:AbuseFilter/history/#{id}"
  end

  def self.log(id)
    "//en.wikipedia.org/w/index.php?title=Special:AbuseLog&wpSearchFilter=#{id}"
  end
end

StaleFilters.run
