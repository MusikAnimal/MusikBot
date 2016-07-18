$LOAD_PATH << '..'
require 'musikbot'
require 'mysql2'

REPORT_PAGE = 'User:MusikBot/ECPMonitor/Report'.freeze
TOTAL_PAGE = 'User:MusikBot/ECPMonitor/Total'.freeze
OFFSET_PAGE = 'User:MusikBot/ECPMonitor/Offset'.freeze

module ECPMonitor
  def self.run
    @mb = MusikBot::Session.new(inspect)

    last_run = @mb.parse_date(@mb.local_storage('ECPMonitor_lastrun', 'r').read)

    un, pw, host, db, port = Auth.db_credentials(@mb.lang)
    @client = Mysql2::Client.new(
      host: host,
      username: un,
      password: pw,
      database: db,
      port: port
    )

    changes = ecp_changes

    if changes.any? { |page| @mb.parse_date(page['log_timestamp']) > last_run }
      generate_report(changes)
      run_file = @mb.local_storage('ECPMonitor_lastrun', 'r+')
      run_file.write(@mb.now.to_s)
      run_file.close
    end

    @mb.edit(TOTAL_PAGE,
      summary: "Updating number of pages under [[WP:30/500|extended confirmed protection]] (#{ecp_total})",
      content: ecp_total
    )
  rescue => e
    @mb.report_error(t('Fatal error'), e)
  end

  def self.ecp_changes
    offset_date = (@mb.now - offset).strftime('%Y%m%d%H%M%S')
    query('SELECT log_timestamp, log_user_text, log_title, log_comment, pr_expiry FROM logging ' \
      'INNER JOIN page_restrictions WHERE log_page = pr_page ' \
      "AND (log_action = 'protect' OR log_action = 'modify') AND pr_type = 'edit' " \
      "AND pr_level = 'extendedconfirmed' AND log_timestamp > '#{offset_date}'" \
      'ORDER BY log_timestamp DESC').to_a
  end

  def self.ecp_total
    @ecp_total ||= query(
      "SELECT COUNT(*) AS count FROM page_restrictions WHERE pr_type = 'edit' AND pr_level = 'extendedconfirmed'"
    ).to_a[0]['count']
  end

  def self.generate_report(pages)
    protect_pages_link = 'https://en.wikipedia.org/w/index.php?title=Special:ProtectedPages&type=edit&level=extendedconfirmed'

    markup = "{| class='wikitable sortable' style='position:relative'" \
      "\n!colspan='5' | Pages recently put under [[WP:30/500|extended confirmed protection]] " \
        "(#{pages.length} out of [#{protect_pages_link} #{ecp_total} total]) <sup>({{purge}})</sup>" \
        "<div style='position:absolute; left:5px; top:3px; font-size:9px'>{{plainlink|url=//en.wikipedia.org/w/" \
        'index.php?title=User:MusikBot/ECPMonitor/Report&action=watch|name=WATCH}}</div>' \
      "\n|-" \
      "\n!Page" \
      "\n!Protected" \
      "\n!Expiry" \
      "\n!Summary" \
      "\n!Admin"

    pages.each do |page|
      markup += "\n|-" \
        "\n|[[#{page['log_title'].tr('_', ' ')}]]" \
        "\n|style='white-space:nowrap' |#{parse_date(page['log_timestamp'])}" \
        "\n|style='white-space:nowrap' |#{parse_date(page['pr_expiry'])}" \
        "\n|style='max-width:400px' |#{page['log_comment']}" \
        "\n|{{noping|#{page['log_user_text']}}}"
    end

    markup += "\n|}"

    summary = "Reporting #{pages.length} pages recently put under [[WP:30/500|extended confirmed protection]] " \
      "(#{ecp_total} total pages)"
    opts = {
      summary: summary,
      content: markup,
      bot: false
    }
    @mb.edit(REPORT_PAGE, opts)
  end

  def self.parse_date(date)
    date == 'infinity' ? 'indefinite' : @mb.parse_date(date).strftime('%Y-%m-%d %H:%M')
  end

  def self.offset
    @offset ||= @mb.get(OFFSET_PAGE).to_i
  end

  def self.query(sql)
    puts sql
    @client.query(sql)
  end
end

ECPMonitor.run
