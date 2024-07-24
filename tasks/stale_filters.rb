$LOAD_PATH << '..'
require 'musikbot'

module StaleFilters
  def self.run
    @mb = MusikBot::Session.new(inspect)

    run_status = @mb.local_storage
    local_status = run_status[@mb.database] || {
      hash: '',
      time: (@mb.now - 1).to_s
    }

    @report_page = "#{t('User')}:MusikBot/StaleFilters/Report"
    @total_page = "#{t('User')}:MusikBot/StaleFilters/Total"
    @offset_page = "#{t('User')}:MusikBot/StaleFilters/Offset"
    @links_page = "#{t('User')}:MusikBot/StaleFilters/Report/Links"

    new_hash = Digest::MD5.hexdigest(stale_filters.join)

    touched = @mb.parse_date(@mb.gateway.custom_query(
      titles: @report_page,
      prop: 'info'
    ).elements['pages'][0].attributes['touched'])

    # abort unless we have new data to report or the page was touched
    return unless new_hash != local_status['hash'] || (touched.present? && touched > @mb.parse_date(local_status['time']))

    generate_report

    run_status[@mb.database] = {
      'hash' => new_hash,
      'time' => @mb.now.to_s
    }

    @mb.local_storage(run_status)
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.generate_report
    links_page = @mb.get(@links_page)

    headings = [
      t('Filter'),
      t('Description'),
      t('Last hit'),
      t('Last filter author'),
      t('Last filter edit'),
      t('Private'),
      t('Actions')
    ]

    headings << t('Links') if links_page.present?

    extended_content = "<div style='font-size:24px'>#{t(:title, date: I18n.l(@mb.today, format: :heading))} <sup>(#{I18n.t(:purge_link)})</sup></div>\n\n" \
      "<small>#{I18n.t(:purging)}</small>\n\n" +
      t(:summary, num: stale_filters.length, days: offset) +
      "\n\n{| class='wikitable sortable'\n! " +
      headings.join("\n! ") + "\n|-\n"

    stale_filters.each do |filter|
      puts "#{index} of #{stale_filters.length}: #{title}" if @env == :test

      fields = [
        "[[#{t('Special:AbuseFilter')}/#{filter['af_id']}|#{filter['af_id']}]]",
        filter['af_public_comments'].force_encoding('utf-8'),
        "data-sort-value=\"#{@mb.api_date(filter['afl_timestamp'])}\" | " + t(:plain_link, url: log(filter['af_id']), name: fdate(filter['afl_timestamp'])),
        t(:user_link, name: filter['actor_name'].force_encoding('utf-8')),
        "data-sort-value=\"#{@mb.api_date(filter['af_timestamp'])}\" | [[#{history(filter['af_id'])}|#{fdate(filter['af_timestamp'])}]]",
        filter['af_hidden'] == 1 ? t('yes') : t('no'),
        translate(filter['af_actions'])
      ]

      fields << links_page.gsub('$1', filter['af_id'].to_s) if links_page.present?

      extended_content += '| ' + fields.join("\n| ") + "\n|-\n"
    end

    extended_content = extended_content.chomp("|-\n") + "|}\n\n"

    summary = t(:edit_summary, num: stale_filters.length)

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

  def self.stale_filters
    return @stale_filters if @stale_filters

    db = @mb.database.present? ? "#{@mb.database}_p" : "#{@mb.lang}wiki_p"

    sql = %{
      SELECT af_id, actor_name, afl.afl_timestamp, af_timestamp, af_public_comments, af_hidden, af_actions
      FROM #{db}.abuse_filter af
      JOIN actor ON actor_id = af_actor
      INNER JOIN (
        SELECT afl_id, afl_filter_id, MAX(afl_timestamp) afl_timestamp
        FROM #{db}.abuse_filter_log
        GROUP BY afl_filter_id
      ) afl ON afl.afl_filter_id = af_id
      WHERE af_enabled = 1
      AND af_deleted = 0
      AND afl.afl_timestamp < ?
    }

    @stale_filters = @mb.repl_query(sql, offset_date).to_a
  end

  def self.offset
    @offset ||= @mb.get(@offset_page).to_i
  end

  # Helpers
  def self.translate(str)
    str.split(',').map { |s| t(s) }.join(', ')
  end

  def self.offset_date
    @mb.db_date(@mb.today - offset)
  end

  def self.fdate(date)
    I18n.l(@mb.parse_date(date), format: :reporting)
  end

  def self.log_entry(id)
    "#{t('Special:AbuseLog')}/#{id}"
  end

  def self.history(id)
    "#{t('Special:AbuseFilter')}/history/#{id}"
  end

  def self.log(id)
    "//#{@mb.opts[:project]}.org/w/index.php?title=#{t('Special:AbuseLog')}&wpSearchFilter=#{id}"
  end
end

StaleFilters.run
