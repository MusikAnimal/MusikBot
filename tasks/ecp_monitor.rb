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

    @mb.edit(TOTAL_PAGE,
      summary: "Updating number of pages under [[WP:30/500|extended confirmed protection]] (#{ecp_total})",
      content: ecp_total
    )

    changes = ecp_changes
    titles = ecp_titles
    titles.map { |title| title['type'] = 'create' }

    new_pages = (changes + titles)
      .select { |page| @mb.parse_date(page['timestamp']) > last_run }
      .map { |page| page['title'].tr('_', ' ') }
      .uniq

    if new_pages.any?
      changes = group_changes(changes)
      generate_report(changes + titles, new_pages)
      run_file = @mb.local_storage('ECPMonitor_lastrun', 'r+')
      run_file.write(@mb.now.to_s)
      run_file.close
    end
  rescue => e
    @mb.report_error(t('Fatal error'), e)
  end

  def self.ecp_changes
    query('SELECT log_namespace AS namespace, log_title AS title, log_timestamp AS timestamp, pr_expiry AS expiry, ' \
      'pr_type AS type, log_comment AS summary, log_user_text AS admin FROM logging ' \
      'INNER JOIN page_restrictions ON log_page = pr_page ' \
      "WHERE (log_action = 'protect' OR log_action = 'modify') " \
      "AND pr_level = 'extendedconfirmed' AND log_timestamp > '#{offset_date}' " \
      'ORDER BY log_timestamp DESC').to_a
  end

  def self.ecp_titles
    query('SELECT pt_namespace AS namesapce, pt_title AS title, pt_timestamp AS timestamp, pt_expiry AS expiry, ' \
      'pt_reason AS summary, user_name AS admin FROM protected_titles ' \
      "INNER JOIN user ON pt_user = user_id WHERE pt_create_perm = 'extendedconfirmed'").to_a
  end

  def self.ecp_total
    @ecp_total ||= query(
      "SELECT COUNT(*) AS count FROM page_restrictions WHERE pr_type = 'edit' AND pr_level = 'extendedconfirmed'"
    ).to_a[0]['count']
  end

  def self.group_changes(changes)
    grouped_changes = []

    changes.each do |change|
      # different type protected on the same page at the same time (would have to be by same admin)
      existing_all = grouped_changes.find_index do |gc|
        gc['title'] == change['title'] && gc['timestamp'] == change['timestamp'] && gc['namespace'] == change['namespace']
      end

      # same page, protection and type, but older timestamp
      existing_page_admin = grouped_changes.find_index do |gc|
        gc['title'] == change['title'] && gc['type'].include?(change['type']) && gc['namespace'] == change['namespace']
      end

      if existing_all
        grouped_changes[existing_all]['type'] += ',' + change['type']
      elsif !existing_page_admin
        grouped_changes << change
      end
    end

    grouped_changes
  end

  def self.generate_report(changes, new_pages)
    protect_pages_link = 'https://en.wikipedia.org/w/index.php?title=Special:ProtectedPages&type=edit&level=extendedconfirmed'

    # changes includes protected titles, so re-sort by log timestamp
    changes.sort! do |a, b|
      b['timestamp'] <=> a['timestamp']
    end

    markup = "{| class='wikitable sortable' style='position:relative'" \
      "\n!colspan='6' | Pages recently put under [[WP:30/500|extended confirmed protection]] " \
        "(#{changes.length} out of [#{protect_pages_link} {{User:MusikBot/ECPMonitor/Total}} total]) <sup>({{purge}})</sup>" \
        "<div style='position:absolute; left:5px; top:3px; font-size:9px'>{{plainlink|url=//en.wikipedia.org/w/" \
        'index.php?title=User:MusikBot/ECPMonitor/Report&action=watch|name=WATCH}}</div>' \
      "\n|-" \
      "\n!Page" \
      "\n!Protected" \
      "\n!Expiry" \
      "\n!Type" \
      "\n!Summary" \
      "\n!Admin"

    changes.each do |change|
      page_title = "#{namespace(change['namespace'])}#{change['title'].tr('_', ' ')}"
      markup += "\n|-" \
        "\n|[[#{page_title}]]" \
        "\n|style='white-space:nowrap' |#{parse_date(change['timestamp'])}" \
        "\n|style='white-space:nowrap' |#{parse_date(change['expiry'])}" \
        "\n|#{change['type']}" \
        "\n|style='max-width:400px' |#{change['summary']}" \
        "\n|{{noping|#{change['admin']}}}"
    end

    markup += "\n|}"

    plural = new_pages.length > 1 ? 's' : ''
    linked_new_pages = new_pages.map { |page| "[[#{page}]]" }.join(' / ')

    summary = "Reporting #{new_pages.length} new page#{plural} put under [[WP:30/500|extended confirmed protection]] " \
      "(#{ecp_total} total): #{linked_new_pages}"
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

  def self.offset_date
    (@mb.now - offset).strftime('%Y%m%d%H%M%S')
  end

  def self.query(sql)
    puts sql
    @client.query(sql)
  end

  def self.namespace(value)
    {
      0 => '',
      1 => 'Talk:',
      2 => 'User:',
      3 => 'User talk:',
      4 => 'Wikipedia:',
      5 => 'Wikipedia talk:',
      6 => 'File:',
      7 => 'File talk:',
      8 => 'MediaWiki:',
      9 => 'MediaWiki talk:',
      10 => 'Template:',
      11 => 'Template talk:',
      12 => 'Help:',
      13 => 'Help talk:',
      14 => 'Category:',
      15 => 'Category talk:',
      100 => 'Portal:',
      101 => 'Portal talk:',
      108 => 'Book:',
      109 => 'Book talk:',
      118 => 'Draft:',
      119 => 'Draft talk:',
      446 => 'Education:',
      447 => 'Program Education Program talk:',
      710 => 'TimedText:',
      711 => 'TimedText talk:',
      828 => 'Module:',
      829 => 'Module talk:',
      2300 => 'Gadget:',
      2301 => 'Gadget talk:',
      2302 => 'Gadget:',
      2303 => 'definition Gadget definition talk:',
      2600 => 'Topic:'
    }[value]
  end
end

ECPMonitor.run
