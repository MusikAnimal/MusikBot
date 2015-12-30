$LOAD_PATH << '.'
require 'musikbot'

module StaleFilters
  def self.run
    @mb = MusikBot::Session.new(inspect)

    @template_name = "#{i18n('User')}:MusikBot/FilterMonitor/#{i18n('Stale filters')}"

    process_filters
  rescue => e
    @mb.report_error(i18n('Fatal error'), e)
  end

  def self.process_filters
    content = "<div style='font-size:24px'>Stale [[WP:FILTER|edit filters]] as of #{@mb.today.strftime('%-d %B %Y')}</div>\n" \
      "#{stale_filters.length} enabled filters with no hits in #{@mb.config['offset']} days\n\n" \
      "{| class='wikitable sortable'\n! Filter\n! Description\n! Last hit\n! Actions\n! Last filter author\n! Last filter edit\n! Private\n! Actions|-\n"

    stale_filters.each do |filter|
      puts "#{index} of #{stale_filters.length}: #{title}" if @env == :test

      content += "| [[Special:AbuseFilter/#{filter['af_id']}|#{filter['af_id']}]] \n| #{page['af_public_comments']}\n" \
        "| [[#{log_entry(filter['afl_id'])}|#{@mb.wiki_date(filter['afl_timestamp'])}]]\n| #{filter['af_actions']}\n" \
        "| [[User:#{filter['af_user_text']}|#{filter['af_user_text']}]]\n| [[#{history(filter['af_id'])}|#{@mb.wiki_date(filter['af_timestamp'])}\n" \
        "| #{filter['af_hidden'] == '1' ? 'yes' : 'no'}\n| #{filter['af_actions']}\n|-\n"
    end

    content = content.chomp("|-\n") + "|}\n\n"

    @mb.edit(@template_name,
      content: content,
      summary: "Reporting #{stale_filters.length} stale filters",
      bot: false
    )
  end

  # FIXME: use https://github.com/michaelfairley/method_decorators !!!!
  def self.stale_filters
    return @stale_filters if @stale_filters

    # FIXME: DISTINCT doesn't work?
    query = 'SELECT DISTINCT af_id, afl_id, af_user_text, afl_timestamp, af_timestamp, af_public_comments, af_hidden, af_actions' \
      'FROM enwiki_p.abuse_filter JOIN enwiki_p.abuse_filter_log ON afl_filter = af_id ' \
      "WHERE af_enabled = 1 AND af_deleted = 0 AND afl_timestamp > #{offset_date};"

    @stale_filters = @mb.repl_client.query(query).to_a
  end

  # Helpers
  def self.offset_date
    @mb.db_date(@mb.today - @mb.config['offset'])
  end

  def self.log_entry(id)
    "Special:AbuseLog/#{id}"
  end

  def self.history(id)
    "Special:AbuseLog/history/#{id}"
  end

  def self.log(id)
    "//en.wikipedia.org/w/index.php?title=Special:AbuseLog&wpSearchFilter=#{id}"
  end
end

StaleFilters.run
